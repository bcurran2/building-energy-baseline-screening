# Building Electricity Baseline Screening: pipeline commands.
#
# First time:   cp .env.example .env   (then put your GCP project ID in .env)
#               make setup
# Every run:    make all      (ingest -> dbt build -> export CSVs)
#
# Run `make help` for the full list.

-include .env
export

VENV := .venv
PY   := $(VENV)/bin/python
DBT  := cd transform && ../$(VENV)/bin/dbt
export DBT_PROFILES_DIR := $(CURDIR)/transform

.PHONY: help setup check-env ingest ingest-force build csv all test docs clean

help:
	@echo "make setup        create .venv, install Python packages and dbt packages"
	@echo "make ingest       download BDG2 files and load them to BigQuery (skips current tables)"
	@echo "make ingest-force reload all raw tables even if they are current"
	@echo "make build        dbt build: run every model and every test"
	@echo "make csv          export the dashboard tables to dashboard_data/*.csv"
	@echo "make all          ingest + build + csv"
	@echo "make test         Python unit tests and lint (no BigQuery needed)"
	@echo "make docs         generate and serve the dbt docs site (lineage graph)"
	@echo "make clean        remove dbt build output"

setup:
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install --upgrade pip
	$(VENV)/bin/pip install -r requirements-dev.txt
	$(DBT) deps

check-env:
	@test -n "$(GCP_PROJECT)" || (echo "GCP_PROJECT is not set. Copy .env.example to .env and fill it in."; exit 1)

ingest: check-env
	$(PY) -m ingest.load_bdg2

ingest-force: check-env
	$(PY) -m ingest.load_bdg2 --force

build: check-env
	$(DBT) build

csv: check-env
	$(PY) -m export.export_csv

all: ingest build csv

test:
	$(PY) -m pytest
	$(VENV)/bin/ruff check .

docs: check-env
	$(DBT) docs generate && $(DBT) docs serve

clean:
	$(DBT) clean
