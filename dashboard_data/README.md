# Dashboard data

The CSV files the Tableau Public dashboard uses, written by `make csv` (`export/export_csv.py`):

| File | Source table | Grain |
|---|---|---|
| `building_summary.csv` | `bdg2_marts.building_summary` | one row per compared building |
| `monthly_by_building.csv` | `bdg2_marts.monthly_by_building` | one row per building per month |
| `funnel.csv` | `bdg2_marts.screening_funnel` | one row per screening stage |

They're committed so the dashboard's data outlives the BigQuery sandbox's 60-day table expiration. To refresh the dashboard, rerun the pipeline and replace the data source files in the Tableau workbook with these.
