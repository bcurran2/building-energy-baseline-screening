"""Load Building Data Genome Project 2 (BDG2) source files into BigQuery.

This is the raw layer of the pipeline. It downloads three CSV files from the
BDG2 GitHub repository and loads each one, unchanged, into a BigQuery table:

    electricity_cleaned.csv  -> <dataset>.electricity   (wide: one column per building)
    metadata.csv             -> <dataset>.buildings
    weather.csv              -> <dataset>.weather

All transformation happens later, in dbt.

Design notes
------------
* Idempotent. Each loaded table is labeled with the size and row count of the
  file it came from. On a rerun, a table whose labels match the current source
  file is skipped, so running this twice does no extra work. Use --force to
  reload anyway.
* Sandbox-friendly. Loads use batch load jobs with WRITE_TRUNCATE (a full
  replace). The BigQuery sandbox does not allow DML (INSERT/UPDATE/MERGE), but
  load jobs work, and tables that expire after 60 days can be rebuilt by
  rerunning this script.
* Explicit schemas. BigQuery's schema auto-detect only samples the top of a
  file, which is how 25 building columns were typed as STRING the first time
  this project was built by hand. Here the electricity columns are declared
  FLOAT64 up front. The metadata file is loaded as all-STRING and typed in dbt,
  where the casting rules are visible and tested.

Usage
-----
    python -m ingest.load_bdg2 --project YOUR_GCP_PROJECT
    python -m ingest.load_bdg2 --project YOUR_GCP_PROJECT --force
    python -m ingest.load_bdg2 --project YOUR_GCP_PROJECT --only weather

Authentication uses Application Default Credentials: run
`gcloud auth application-default login` once on your machine. In GitHub
Actions, the google-github-actions/auth step provides them.
"""

from __future__ import annotations

import argparse
import csv
import logging
import os
import sys
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING

import requests

if TYPE_CHECKING:  # imported lazily so the helpers can be tested without the client library
    from google.cloud import bigquery

log = logging.getLogger("ingest")

BDG2_BASE_URL = (
    "https://media.githubusercontent.com/media/buds-lab/building-data-genome-project-2/master/data"
)

# Weather columns in the source file, and their BigQuery types.
WEATHER_COLUMNS = {
    "timestamp": "TIMESTAMP",
    "site_id": "STRING",
    "airTemperature": "FLOAT64",
    "cloudCoverage": "FLOAT64",
    "dewTemperature": "FLOAT64",
    "precipDepth1HR": "FLOAT64",
    "precipDepth6HR": "FLOAT64",
    "seaLvlPressure": "FLOAT64",
    "windDirection": "FLOAT64",
    "windSpeed": "FLOAT64",
}

LFS_POINTER_PREFIX = b"version https://git-lfs"
DOWNLOAD_CHUNK_BYTES = 1024 * 1024
LABEL_SOURCE_BYTES = "source_bytes"
LABEL_SOURCE_ROWS = "source_rows"


class IngestError(RuntimeError):
    """Raised when a source file or a load fails a check."""


# --------------------------------------------------------------------------
# Schemas
# --------------------------------------------------------------------------
# Each schema function takes the file's header row and returns a list of
# (column_name, bigquery_type) pairs. They fail loudly if the file is not
# shaped the way the downstream dbt models expect.


def electricity_schema(header: list[str]) -> list[tuple[str, str]]:
    if not header or header[0] != "timestamp":
        raise IngestError("electricity file: first column should be 'timestamp'")
    buildings = header[1:]
    if not buildings:
        raise IngestError("electricity file: no building columns found")
    if len(set(buildings)) != len(buildings):
        raise IngestError("electricity file: duplicate building column names")
    return [("timestamp", "TIMESTAMP")] + [(name, "FLOAT64") for name in buildings]


def buildings_schema(header: list[str]) -> list[tuple[str, str]]:
    required = {"building_id", "site_id", "primaryspaceusage", "sqft"}
    missing = required - set(header)
    if missing:
        raise IngestError(f"metadata file: missing columns {sorted(missing)}")
    # Everything lands as text; dbt staging casts the columns it uses.
    return [(name, "STRING") for name in header]


def weather_schema(header: list[str]) -> list[tuple[str, str]]:
    if header != list(WEATHER_COLUMNS):
        raise IngestError(f"weather file: expected columns {list(WEATHER_COLUMNS)}, got {header}")
    return list(WEATHER_COLUMNS.items())


@dataclass(frozen=True)
class SourceFile:
    table: str
    url: str
    filename: str
    schema_fn: Callable[[list[str]], list[tuple[str, str]]]
    description: str


SOURCES: dict[str, SourceFile] = {
    "electricity": SourceFile(
        table="electricity",
        url=f"{BDG2_BASE_URL}/meters/cleaned/electricity_cleaned.csv",
        filename="electricity_cleaned.csv",
        schema_fn=electricity_schema,
        description="BDG2 cleaned hourly electricity (kWh), one column per building, 2016-2017.",
    ),
    "buildings": SourceFile(
        table="buildings",
        url=f"{BDG2_BASE_URL}/metadata/metadata.csv",
        filename="metadata.csv",
        schema_fn=buildings_schema,
        description="BDG2 building metadata, one row per building, loaded as text.",
    ),
    "weather": SourceFile(
        table="weather",
        url=f"{BDG2_BASE_URL}/weather/weather.csv",
        filename="weather.csv",
        schema_fn=weather_schema,
        description="BDG2 hourly weather per site (temperatures in Celsius).",
    ),
}


# --------------------------------------------------------------------------
# File helpers
# --------------------------------------------------------------------------


def is_lfs_pointer(path: Path) -> bool:
    """True if the file is a Git LFS pointer instead of the real data.

    GitHub's "Download ZIP" (and the raw.githubusercontent.com URLs) return
    these small text stubs for LFS-tracked files.
    """
    with path.open("rb") as f:
        return f.read(len(LFS_POINTER_PREFIX)) == LFS_POINTER_PREFIX


def read_header(path: Path) -> list[str]:
    with path.open(newline="", encoding="utf-8") as f:
        return next(csv.reader(f))


def count_data_rows(path: Path) -> int:
    """Number of CSV records after the header (handles quoted newlines)."""
    with path.open(newline="", encoding="utf-8") as f:
        reader = csv.reader(f)
        next(reader, None)
        return sum(1 for _ in reader)


def remote_size(url: str, timeout: int = 60) -> int | None:
    """Size of the remote file in bytes, or None if the server does not say."""
    resp = requests.head(url, allow_redirects=True, timeout=timeout)
    resp.raise_for_status()
    length = resp.headers.get("Content-Length")
    return int(length) if length else None


def download(url: str, dest: Path, expected_bytes: int | None) -> Path:
    """Download url to dest, reusing a cached copy if it is already complete."""
    if dest.exists() and expected_bytes is not None and dest.stat().st_size == expected_bytes:
        log.info("  using cached %s", dest)
        return dest

    dest.parent.mkdir(parents=True, exist_ok=True)
    partial = dest.with_suffix(dest.suffix + ".part")
    log.info("  downloading %s", url)
    with requests.get(url, stream=True, timeout=300) as resp:
        resp.raise_for_status()
        with partial.open("wb") as f:
            for chunk in resp.iter_content(chunk_size=DOWNLOAD_CHUNK_BYTES):
                f.write(chunk)

    size = partial.stat().st_size
    if expected_bytes is not None and size != expected_bytes:
        partial.unlink()
        raise IngestError(f"incomplete download of {url}: {size} of {expected_bytes} bytes")
    partial.replace(dest)

    if is_lfs_pointer(dest):
        raise IngestError(f"{url} returned a Git LFS pointer, not the data file")
    return dest


# --------------------------------------------------------------------------
# BigQuery helpers
# --------------------------------------------------------------------------


def load_labels(source_bytes: int, source_rows: int) -> dict[str, str]:
    """Labels written on each loaded table (label values must be strings)."""
    return {
        LABEL_SOURCE_BYTES: str(source_bytes),
        LABEL_SOURCE_ROWS: str(source_rows),
        "pipeline": "bdg2",
    }


def table_is_current(table, source_bytes: int | None) -> bool:
    """True if a loaded table already holds the current version of its source file.

    `table` is a google.cloud.bigquery.Table (or anything with .labels and
    .num_rows). A table is current when it was loaded from a file of the same
    size and still has the row count recorded at load time.
    """
    if table is None or source_bytes is None:
        return False
    labels = table.labels or {}
    if labels.get(LABEL_SOURCE_BYTES) != str(source_bytes):
        return False
    expected_rows = labels.get(LABEL_SOURCE_ROWS)
    return expected_rows is not None and str(table.num_rows) == expected_rows


def get_table_or_none(client: bigquery.Client, table_id: str):
    from google.api_core.exceptions import NotFound

    try:
        return client.get_table(table_id)
    except NotFound:
        return None


def load_csv(
    client: bigquery.Client,
    path: Path,
    table_id: str,
    schema: list[tuple[str, str]],
    description: str,
    labels: dict[str, str],
    expected_rows: int,
) -> None:
    from google.cloud import bigquery

    job_config = bigquery.LoadJobConfig(
        source_format=bigquery.SourceFormat.CSV,
        skip_leading_rows=1,
        schema=[bigquery.SchemaField(name, type_) for name, type_ in schema],
        write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
        allow_quoted_newlines=True,
    )
    log.info("  loading %s rows into %s", f"{expected_rows:,}", table_id)
    with path.open("rb") as f:
        job = client.load_table_from_file(f, table_id, job_config=job_config)
    job.result()  # waits; raises if the load job failed

    table = client.get_table(table_id)
    if table.num_rows != expected_rows:
        raise IngestError(f"{table_id}: loaded {table.num_rows:,} rows, file has {expected_rows:,}")
    table.description = description
    table.labels = labels
    client.update_table(table, ["description", "labels"])


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------


def ingest_source(
    client: bigquery.Client,
    source: SourceFile,
    dataset_id: str,
    data_dir: Path,
    force: bool,
) -> str:
    """Load one source file. Returns 'loaded' or 'skipped'."""
    table_id = f"{dataset_id}.{source.table}"
    log.info("%s", table_id)

    size = remote_size(source.url)
    if not force and table_is_current(get_table_or_none(client, table_id), size):
        log.info("  already loaded from the current source file; skipping (use --force to reload)")
        return "skipped"

    path = download(source.url, data_dir / source.filename, size)
    schema = source.schema_fn(read_header(path))
    rows = count_data_rows(path)
    load_csv(
        client,
        path,
        table_id,
        schema,
        description=f"{source.description} Source: {source.url}",
        labels=load_labels(path.stat().st_size, rows),
        expected_rows=rows,
    )
    log.info("  done: %s rows, %s columns", f"{rows:,}", f"{len(schema):,}")
    return "loaded"


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument(
        "--project",
        default=os.environ.get("GCP_PROJECT"),
        help="GCP project ID (default: $GCP_PROJECT)",
    )
    parser.add_argument(
        "--dataset",
        default=os.environ.get("BQ_RAW_DATASET", "bdg2_raw"),
        help="BigQuery dataset for raw tables (default: bdg2_raw)",
    )
    parser.add_argument(
        "--location",
        default=os.environ.get("BQ_LOCATION", "US"),
        help="BigQuery location (default: US)",
    )
    parser.add_argument(
        "--data-dir",
        type=Path,
        default=Path("data/raw"),
        help="local download cache (default: data/raw, git-ignored)",
    )
    parser.add_argument("--force", action="store_true", help="reload even if tables are current")
    parser.add_argument(
        "--only",
        choices=sorted(SOURCES),
        action="append",
        help="load only this source (can repeat)",
    )
    args = parser.parse_args(argv)
    if not args.project:
        parser.error("--project is required (or set GCP_PROJECT)")
    return args


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    args = parse_args(argv)

    from google.cloud import bigquery

    client = bigquery.Client(project=args.project, location=args.location)
    dataset_id = f"{args.project}.{args.dataset}"
    dataset = bigquery.Dataset(dataset_id)
    dataset.location = args.location
    client.create_dataset(dataset, exists_ok=True)

    results = {}
    for key in args.only or list(SOURCES):
        results[key] = ingest_source(client, SOURCES[key], dataset_id, args.data_dir, args.force)

    log.info("summary: %s", ", ".join(f"{k}={v}" for k, v in results.items()))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except IngestError as exc:
        log.error("ingest failed: %s", exc)
        sys.exit(1)
