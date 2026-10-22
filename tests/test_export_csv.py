"""Unit tests for the CSV export helpers."""

import csv
import datetime as dt

from export.export_csv import EXPORTS, format_value, write_csv


def test_format_value():
    assert format_value(None) == ""
    assert format_value(True) == "true"
    assert format_value(dt.date(2017, 5, 1)) == "2017-05-01"
    assert format_value(0.236) == "0.236"
    assert format_value("ok") == "ok"


def test_write_csv_round_trips(tmp_path):
    path = tmp_path / "out" / "funnel.csv"
    rows = [(1, "Building columns in raw file", 1578), (2, "With electricity readings", None)]
    count = write_csv(path, ["step", "stage", "buildings"], rows)
    assert count == 2
    with path.open(newline="", encoding="utf-8") as f:
        assert list(csv.reader(f)) == [
            ["step", "stage", "buildings"],
            ["1", "Building columns in raw file", "1578"],
            ["2", "With electricity readings", ""],
        ]


def test_export_file_names_match_the_dashboard():
    assert {name for name, _ in EXPORTS.values()} == {
        "building_summary.csv",
        "monthly_by_building.csv",
        "funnel.csv",
    }
