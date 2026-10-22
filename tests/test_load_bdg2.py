"""Unit tests for the ingest helpers. No network or BigQuery access needed."""

from types import SimpleNamespace

import pytest

from ingest.load_bdg2 import (
    WEATHER_COLUMNS,
    IngestError,
    buildings_schema,
    count_data_rows,
    electricity_schema,
    is_lfs_pointer,
    load_labels,
    read_header,
    table_is_current,
    weather_schema,
)


def write(tmp_path, name, text):
    path = tmp_path / name
    path.write_text(text, encoding="utf-8")
    return path


# --- file helpers -----------------------------------------------------------


def test_detects_lfs_pointer(tmp_path):
    pointer = write(
        tmp_path,
        "pointer.csv",
        "version https://git-lfs.github.com/spec/v1\noid sha256:abc\nsize 174977911\n",
    )
    real = write(tmp_path, "real.csv", "timestamp,BldgA\n2016-01-01 00:00:00,1.0\n")
    assert is_lfs_pointer(pointer)
    assert not is_lfs_pointer(real)


def test_counts_rows_excluding_header_and_handles_quoted_newlines(tmp_path):
    path = write(tmp_path, "m.csv", 'building_id,note\nA,"line one\nline two"\nB,plain\n')
    assert count_data_rows(path) == 2


def test_reads_header(tmp_path):
    path = write(tmp_path, "e.csv", "timestamp,BldgA,BldgB\n2016-01-01 00:00:00,1,2\n")
    assert read_header(path) == ["timestamp", "BldgA", "BldgB"]


# --- schemas ----------------------------------------------------------------


def test_electricity_schema_types_every_building_as_float():
    schema = electricity_schema(["timestamp", "BldgA", "BldgB"])
    assert schema == [("timestamp", "TIMESTAMP"), ("BldgA", "FLOAT64"), ("BldgB", "FLOAT64")]


@pytest.mark.parametrize(
    "header",
    [
        ["time", "BldgA"],  # wrong first column
        ["timestamp"],  # no buildings
        ["timestamp", "BldgA", "BldgA"],  # duplicate building
    ],
)
def test_electricity_schema_rejects_bad_headers(header):
    with pytest.raises(IngestError):
        electricity_schema(header)


def test_buildings_schema_is_all_text_and_requires_key_columns():
    header = ["building_id", "site_id", "primaryspaceusage", "sqft", "yearbuilt"]
    assert buildings_schema(header) == [(name, "STRING") for name in header]
    with pytest.raises(IngestError):
        buildings_schema(["building_id", "site_id"])


def test_weather_schema_requires_exact_columns():
    assert weather_schema(list(WEATHER_COLUMNS))[0] == ("timestamp", "TIMESTAMP")
    with pytest.raises(IngestError):
        weather_schema(["timestamp", "site_id", "airTemperature"])


# --- idempotency ------------------------------------------------------------


def fake_table(labels, num_rows):
    return SimpleNamespace(labels=labels, num_rows=num_rows)


def test_table_is_current_when_labels_match_source():
    table = fake_table(load_labels(source_bytes=1000, source_rows=10), num_rows=10)
    assert table_is_current(table, source_bytes=1000)


@pytest.mark.parametrize(
    "table, source_bytes",
    [
        (None, 1000),  # table does not exist
        (fake_table(load_labels(1000, 10), 10), None),  # remote size unknown
        (fake_table(load_labels(999, 10), 10), 1000),  # source file changed
        (fake_table(load_labels(1000, 10), 9), 1000),  # rows lost since load
        (fake_table({}, 10), 1000),  # loaded by something else
    ],
)
def test_table_is_not_current(table, source_bytes):
    assert not table_is_current(table, source_bytes)
