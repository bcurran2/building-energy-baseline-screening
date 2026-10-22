"""Export the dashboard tables from BigQuery to CSV files.

The Tableau Public dashboard reads CSV files, not a live BigQuery connection,
because BigQuery sandbox tables expire after 60 days. This script writes the
three files the dashboard uses, with the same names and columns as the
original hand exports:

    <marts dataset>.building_summary     -> dashboard_data/building_summary.csv
    <marts dataset>.monthly_by_building  -> dashboard_data/monthly_by_building.csv
    <marts dataset>.screening_funnel     -> dashboard_data/funnel.csv

The CSVs are committed to the repo, so the dashboard's data survives even after
the BigQuery tables expire.

Usage
-----
    python -m export.export_csv --project YOUR_GCP_PROJECT
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import logging
import os
import sys
from pathlib import Path

log = logging.getLogger("export")

# table name -> (output file, ORDER BY clause so reruns produce stable diffs)
EXPORTS: dict[str, tuple[str, str]] = {
    "building_summary": ("building_summary.csv", "building_id"),
    "monthly_by_building": ("monthly_by_building.csv", "building_id, month"),
    "screening_funnel": ("funnel.csv", "step"),
}


def format_value(value) -> str:
    """Render a BigQuery value the way a CSV reader (Tableau) expects."""
    if value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (dt.date, dt.datetime)):
        return value.isoformat()
    return str(value)


def write_csv(path: Path, columns: list[str], rows) -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    count = 0
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(columns)
        for row in rows:
            writer.writerow([format_value(v) for v in row])
            count += 1
    return count


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--project", default=os.environ.get("GCP_PROJECT"))
    parser.add_argument(
        "--dataset",
        default=os.environ.get("BQ_MARTS_DATASET", "bdg2_marts"),
        help="dataset dbt writes the marts to (default: bdg2_marts)",
    )
    parser.add_argument("--location", default=os.environ.get("BQ_LOCATION", "US"))
    parser.add_argument("--out-dir", type=Path, default=Path("dashboard_data"))
    args = parser.parse_args(argv)
    if not args.project:
        parser.error("--project is required (or set GCP_PROJECT)")
    return args


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    args = parse_args(argv)

    from google.cloud import bigquery

    client = bigquery.Client(project=args.project, location=args.location)
    for table, (filename, order_by) in EXPORTS.items():
        table_id = f"{args.project}.{args.dataset}.{table}"
        result = client.query(f"SELECT * FROM `{table_id}` ORDER BY {order_by}").result()
        columns = [field.name for field in result.schema]
        rows = write_csv(args.out_dir / filename, columns, (row.values() for row in result))
        log.info("%s -> %s (%s rows)", table_id, args.out_dir / filename, f"{rows:,}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
