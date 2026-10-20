# Building Electricity Baseline Screening

Screening ~1,600 commercial buildings for electricity use that runs above its own historical baseline, using BigQuery SQL and a Tableau Public dashboard.

**Live dashboard:** https://public.tableau.com/app/profile/brian.curran/viz/BuildingElectricalBaselineScreening/BuildingElectricityBaselineScreening

![Dashboard screenshot](dashboard.png)

## The question

Given two years of hourly electricity data from many buildings, which ones used noticeably more in 2017 than their own 2016 pattern would predict, after accounting for time of day, weekday vs. weekend, and outdoor temperature? And how do you keep meter problems from showing up as "findings"?

## Results at a glance

| Stage | Buildings |
|---|---|
| Building columns in the raw electricity file | 1,578 |
| With any electricity readings | 1,572 |
| Enough matched hours to compare 2017 to 2016 | 1,451 |
| **Trustworthy 2016 baseline** | **1,089** |

- Among the 1,089 buildings with a trustworthy baseline, the median building used **2.2% less** in 2017 than its baseline predicted. A baseline that centers near zero is what a working method should produce.
- **51** of those buildings ran more than 15% above baseline.
- The other 362 buildings were flagged rather than ranked: 237 had an unstable 2016 (a large change inside the baseline year), 85 were too small to trust, and 40 had a dead or near-zero meter for part of 2016.

## Data

[Building Data Genome Project 2](https://github.com/buds-lab/building-data-genome-project-2) (Miller et al., 2020, *Scientific Data*): hourly whole-building meter data for two years (2016-2017), plus building metadata and hourly site-level weather. This project uses the cleaned electricity meters, the building metadata, and the weather file. See the source repository for license and citation details.

Note: the large data files in that repo are stored with Git LFS. Downloading the repo as a ZIP gives tiny pointer files instead of the real data, so download each file individually from GitHub.

## Pipeline

```
electricity_cleaned.csv ─┐
metadata.csv ────────────┼─> BigQuery tables ─> unpivot to long format ─> join buildings + weather
weather.csv ─────────────┘                                                         │
                                                                                   v
      Tableau Public <─ CSV exports <─ flag baseline quality <─ 2016 baseline vs. 2017 comparison
```

1. **Load** the three CSVs into BigQuery (sandbox). The 175 MB electricity file was split in two to fit the console upload limit.
2. **Reshape** the electricity table from wide (one column per building, 1,578 columns) to long (one row per building per hour) using dynamic SQL built from the table's own metadata, with `SAFE_CAST` to fix columns that auto-detect typed as text. Result: 25.2M rows.
3. **Join** building attributes and hourly site weather (left join, so a missing weather hour doesn't delete a meter reading).
4. **Baseline** each building from 2016.
5. **Compare** 2017 against the baseline.
6. **Flag** buildings whose 2016 data can't support a baseline.
7. **Export** summary tables for the dashboard.

All SQL, in run order and commented, is in [`sql/bdg2_pipeline.sql`](sql/bdg2_pipeline.sql).

## Method

**Baseline.** For each building, the median 2016 kWh for every combination of hour of day, weekday/weekend, and outdoor temperature band (10 °F bands; the source weather is in Celsius and was converted). Medians resist spikes and meter glitches better than averages. Combinations seen fewer than 3 times are dropped.

**Comparison.** Each 2017 hour is matched to the same building's baseline for the same conditions. Actual and expected kWh are summed over the same matched hours, so the comparison is like-for-like. `pct_over = (actual - expected) / expected`. Buildings with fewer than 4,000 matched hours are excluded.

## What went wrong first (and how it was fixed)

The first ranking by percent over put meter artifacts at the top. Monthly profiles showed why: several top buildings had a change inside 2016, the baseline year, so their baseline mixed "before" and "after." Examples: a meter that read zero for 23 months, a building that went from ~20,000 to ~0 to ~70,000 kWh a month during 2016, and two that stepped up by 8x or more.

The fix was a baseline-quality check on each building's 2016 data, which **flags rather than deletes** (every building keeps a status):

| Status | Rule |
|---|---|
| `dead_meter_2016` | more than 5% of 2016 hours read near zero |
| `low_baseline` | under 50,000 kWh in 2016 |
| `unstable_2016` | largest month more than 4x the smallest |
| `ok` | passes all three |

A sensitivity check with a stricter 3x cutoff changed only one building in the top 15, so the ranking isn't sensitive to the exact threshold.

## Example findings

- **Moose_education_Maria:** roughly flat at ~500,000 kWh a month for 16 months, then a sustained step up of about 35% starting May 2017. It has the largest excess among buildings with a clean baseline, about 1.3 million kWh in 2017.
- **Robin_education_Zenia:** stepped up about 40% in Oct 2016 and stayed there. A real shift, but it happened inside the baseline year, so the model's +42.8% overstates a "2017" problem.
- **Eagle_assembly_Josie:** passed the filter (month ratio 3.9x) but was a false positive: its load ramped up through 2016. A monthly profile review caught it.
- **Hog_services_Adrianna:** similar to 2016 most months, with a March spike in both years and a large December 2017 spike. A candidate for an hourly drill-down.

## Limitations

- This is a **screening method**: it flags candidates for investigation and does not diagnose faults. A jump could be new equipment, added load, longer occupancy, a renovation, or a meter change.
- It assumes 2016 is a representative baseline year. The quality filter catches many but not all violations (see Josie above), so featured buildings should get a monthly-profile check.
- No occupancy calendar, holiday, or school-schedule model. Comparing year over year helps, since both years share a calendar, but education buildings (7 of the top 15) may be affected.
- Thresholds (5%, 50,000 kWh, 4x) are judgment calls, not standards.
- Weather is site-level, not building-level. I used the timestamps as provided and did not independently verify time-zone alignment between the meter and weather files.
- Medians use BigQuery's `APPROX_QUANTILES`, so they are approximate.
- Electricity only; the dataset's other meter types weren't analyzed.

## Reproducing this

1. Download `electricity_cleaned.csv`, `metadata.csv`, and `weather.csv` from the source repo (individually, not as a ZIP).
2. Create a BigQuery dataset named `bdg2` and load the files as `raw_electricity`, `buildings`, and `weather` (split the electricity file if it exceeds the upload limit; append the second part with auto-detect off).
3. Run `sql/bdg2_pipeline.sql` from step 1 onward.

BigQuery sandbox tables expire after 60 days, so the dashboard's data was exported to CSV (step 9 in the SQL file).

## Tools

BigQuery (SQL), Tableau Public. I designed the approach and reviewed every result; I used an AI assistant (Claude) to help write and debug the SQL and to talk through methodology.
