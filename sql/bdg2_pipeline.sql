-- NOTE: This is the original, hand-run version of the analysis (October 2026).
-- The pipeline in ingest/, transform/ (dbt), and export/ replaces it; the
-- logic is the same. Kept as a record of how the analysis was first built.

-- ============================================================================
-- Building energy analytics pipeline: Building Data Genome Project 2 (BDG2)
-- Platform: BigQuery (sandbox), project bdg2-energy, dataset bdg2
-- Source: github.com/buds-lab/building-data-genome-project-2 (open data)
--
-- THE BIG PICTURE
--   Raw meter data (one column per building) -> reshaped to one row per
--   building-hour -> joined to building details and local weather -> used to
--   build a "what should this building be using?" baseline from 2016 ->
--   compared against 2017 to find buildings running above expectation.
--
-- Run order: 0 (load, done in console) -> 1 -> 2 -> 3 -> 4 -> 5 -> 6
-- Notes:
--   * Raw weather temperatures are in Celsius; the baseline bins temperature
--     in Fahrenheit (converted in SQL, source values untouched).
--   * Timestamps are local to each site in the source data.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 0. LOAD (console upload, not SQL)
--
-- WHAT: Three CSV files were uploaded as BigQuery tables.
--   buildings        <- metadata.csv           (one row per building)
--   weather          <- weather.csv            (hourly weather per site)
--   raw_electricity  <- electricity_cleaned.csv (one row per hour, one COLUMN
--                       per building: "wide" format)
--
-- GOTCHAS WORTH REMEMBERING:
--   * GitHub's "Download ZIP" gives tiny Git LFS pointer files instead of the
--     real data. The real files had to be downloaded one at a time.
--   * The electricity file (~175 MB) exceeded the console upload limit, so it
--     was split in two with a PowerShell script (header row kept in each).
--   * Auto-detect guessed different column types for part 2 and the append
--     failed. Fix: append with Auto detect OFF so the existing schema is used.
-- ----------------------------------------------------------------------------


-- ----------------------------------------------------------------------------
-- 1. CHECK THE LOAD
--
-- WHAT: Confirms the data arrived complete and shows what types BigQuery chose.
-- WHY:  Never build on data you have not sanity-checked. Two years of hourly
--       data should be 17,544 rows (2016 was a leap year: 8,784 + 8,760).
-- ----------------------------------------------------------------------------
SELECT COUNT(*) AS row_count FROM bdg2.raw_electricity;   -- expect 17544

-- Counts columns by data type using BigQuery's built-in metadata view.
SELECT data_type, COUNT(*) AS columns
FROM bdg2.INFORMATION_SCHEMA.COLUMNS
WHERE table_name = 'raw_electricity'
GROUP BY data_type;
-- Result: 1 TIMESTAMP, 1553 FLOAT64, 25 STRING.
-- Why STRING? Auto-detect only samples the top of the file. A building whose
-- sampled rows were empty got typed as text. Fixed in step 2.

-- Checks the weather units. Values like -30..45 mean Celsius; Fahrenheit would
-- run roughly -20..115.
SELECT MIN(airTemperature) AS min_temp, MAX(airTemperature) AS max_temp
FROM bdg2.weather;


-- ----------------------------------------------------------------------------
-- 2. UNPIVOT: wide -> long
--
-- WHAT: Turns "one column per building" into "one row per building per hour":
--
--     timestamp | BldgA | BldgB          timestamp | building_id | kwh
--     ----------+-------+------    ->    ----------+-------------+-----
--     1am       |  10   |  20            1am       | BldgA       |  10
--     2am       |  12   |  22            1am       | BldgB       |  20
--                                        2am       | BldgA       |  12
--
-- WHY:  Long format is what SQL, joins, and Tableau work with. You cannot
--       group or filter by "building" when each building is its own column.
--
-- HOW:  There are ~1,578 building columns, too many to type. So the script:
--   a) DECLARE/SET builds two text strings from the table's metadata:
--        cast_list: "SAFE_CAST(`col` AS FLOAT64) AS `col`, ..." for every col
--        col_list:  "`col`, ..." for every building column
--   b) SAFE_CAST converts text to numbers and returns NULL instead of an error
--      if a value cannot convert. This fixes the 25 STRING columns.
--   c) EXECUTE IMMEDIATE runs the assembled text as a real SQL statement
--      (dynamic SQL), with FORMAT dropping the two lists into the %s spots.
--   d) UNPIVOT does the actual reshape. It also drops NULL readings, so the
--      result contains only real measurements.
-- ----------------------------------------------------------------------------
DECLARE cast_list STRING;
DECLARE col_list STRING;

SET cast_list = (
  SELECT STRING_AGG(FORMAT('SAFE_CAST(`%s` AS FLOAT64) AS `%s`', column_name, column_name))
  FROM bdg2.INFORMATION_SCHEMA.COLUMNS
  WHERE table_name = 'raw_electricity' AND column_name != 'timestamp'
);

SET col_list = (
  SELECT STRING_AGG(FORMAT('`%s`', column_name))
  FROM bdg2.INFORMATION_SCHEMA.COLUMNS
  WHERE table_name = 'raw_electricity' AND column_name != 'timestamp'
);

EXECUTE IMMEDIATE FORMAT("""
  CREATE OR REPLACE TABLE bdg2.electricity_long AS
  SELECT `timestamp`, building_id, kwh
  FROM (SELECT `timestamp`, %s FROM bdg2.raw_electricity)
  UNPIVOT (kwh FOR building_id IN (%s))
""", cast_list, col_list);


-- ----------------------------------------------------------------------------
-- 3. VERIFY THE UNPIVOT
--
-- WHAT/WHY: Three checks that the reshape did not lose or invent anything.
-- ----------------------------------------------------------------------------

-- Row count, building count, and date range.
SELECT COUNT(*) AS row_count,
       COUNT(DISTINCT building_id) AS buildings,
       MIN(`timestamp`) AS first_reading,
       MAX(`timestamp`) AS last_reading
FROM bdg2.electricity_long;
-- Result: 25,212,579 rows; 1,572 buildings; 2016-01-01 to 2017-12-31 23:00.
-- Max possible was ~27.7M (17,544 hours x 1,578 buildings), so ~91% of
-- building-hours had a reading. That is normal for real meter data.
-- 6 of the 1,578 columns were entirely empty in the raw data (checked: zero
-- non-empty values), so they produce no rows. Nothing was lost.

-- Every building in the readings should exist in the metadata (expect 0).
-- LEFT JOIN keeps all readings; the WHERE keeps only those with no match.
SELECT COUNT(DISTINCT e.building_id) AS unmatched
FROM bdg2.electricity_long e
LEFT JOIN bdg2.buildings b ON e.building_id = b.building_id
WHERE b.building_id IS NULL;

-- Weather should have exactly one row per site per hour (expect equal numbers).
-- If there were duplicates, joining would silently multiply meter rows.
SELECT COUNT(*) AS total_rows,
       COUNT(DISTINCT CONCAT(site_id, '|', `timestamp`)) AS distinct_site_hours
FROM bdg2.weather;
-- Result: 331,166 = 331,166


-- ----------------------------------------------------------------------------
-- 4. ANALYSIS TABLE: readings + building attributes + site weather
--
-- WHAT: One table where each row is a building-hour with its kWh, what kind
--       of building it is, and the outdoor temperature at its site.
-- WHY:  Energy use depends heavily on outdoor temperature (heating/cooling),
--       so a fair "expected use" needs temperature alongside the reading.
--
-- HOW:
--   * The WITH block (a CTE) is a temporary named query. Here it converts the
--     weather timestamp from text to a real TIMESTAMP, and AVG/GROUP BY
--     guarantees one temperature per site-hour (a safety net; step 3 showed
--     there are no duplicates).
--   * Buildings are matched to weather through their site_id, because weather
--     is recorded per site, not per building.
--   * The weather join is a LEFT JOIN so a missing weather hour keeps the meter
--     reading (with a NULL temperature) instead of deleting it.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE bdg2.electricity_analysis AS
WITH w AS (
  SELECT site_id,
         SAFE_CAST(`timestamp` AS TIMESTAMP) AS ts,
         AVG(airTemperature) AS air_temp_c
  FROM bdg2.weather
  GROUP BY site_id, ts
)
SELECT e.`timestamp`,
       e.building_id,
       e.kwh,
       b.site_id,
       b.primaryspaceusage,
       b.sqft,
       w.air_temp_c
FROM bdg2.electricity_long e
JOIN bdg2.buildings b ON e.building_id = b.building_id
LEFT JOIN w ON w.site_id = b.site_id AND w.ts = e.`timestamp`;

-- Check: row count must still equal electricity_long (no duplication).
SELECT COUNT(*) AS total_rows,
       COUNTIF(air_temp_c IS NULL) AS missing_temp
FROM bdg2.electricity_analysis;
-- Result: 25,212,579 rows; 93,329 missing temperature (~0.4%).


-- ----------------------------------------------------------------------------
-- 5. BASELINE: "what does each building normally use?"
--
-- WHAT: For each building, the typical (median) kWh in 2016 under each
--       combination of:
--         hr         - hour of day (0-23): offices use more at 2pm than 2am
--         is_weekend - Saturday/Sunday vs. weekday
--         temp_bin   - outdoor temperature in 10-degree-F bands
--       Example row: "Bldg X, 2pm, weekday, 80-90F: median 140 kWh".
--
-- WHY:  A building uses more power when it is hot or when people are in it.
--       Comparing against a baseline built under the SAME conditions keeps the
--       comparison fair, like comparing a July afternoon to other July
--       afternoons rather than to a January night.
--
-- HOW:
--   * Temperature is converted from Celsius: F = C * 9/5 + 32.
--   * FLOOR(F / 10) turns a temperature into a band number (83F -> 8).
--   * Median, not average: a few spikes or meter glitches would drag an
--     average up, but barely move a median. APPROX_QUANTILES(kwh, 2)[OFFSET(1)]
--     is BigQuery's way to get the (approximate) median.
--   * Only 2016 data is used (the "training" year).
--   * HAVING n >= 3 drops conditions seen fewer than 3 times; a median of one
--     or two readings is not a trustworthy baseline.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE bdg2.baseline AS
SELECT building_id,
       EXTRACT(HOUR FROM `timestamp`) AS hr,
       EXTRACT(DAYOFWEEK FROM `timestamp`) IN (1, 7) AS is_weekend,
       CAST(FLOOR((air_temp_c * 9 / 5 + 32) / 10) AS INT64) AS temp_bin,
       APPROX_QUANTILES(kwh, 2)[OFFSET(1)] AS baseline_kwh,
       COUNT(*) AS n
FROM bdg2.electricity_analysis
WHERE `timestamp` < TIMESTAMP '2017-01-01'
  AND air_temp_c IS NOT NULL
  AND kwh IS NOT NULL
GROUP BY building_id, hr, is_weekend, temp_bin
HAVING n >= 3;


-- ----------------------------------------------------------------------------
-- 6. PERFORMANCE: how did each building do in 2017 vs. its 2016 baseline?
--
-- WHAT: For each building, adds up actual 2017 kWh and the baseline kWh for
--       the same hours and conditions, then computes how far above (or below)
--       expectation it ran:
--           pct_over = (actual - expected) / expected
--
-- HOW:
--   * Each 2017 hour is joined to the baseline row with the same building,
--     hour of day, weekday/weekend flag, and temperature band.
--   * Only hours that find a matching baseline are counted, and the same hours
--     feed both sums, so it is a like-for-like comparison.
--   * ANY_VALUE just carries along building details that are the same for
--     every row of a building, since GROUP BY needs them aggregated.
--   * HAVING matched_hours >= 4000 drops buildings with too little overlapping
--     data to trust (a full year is ~8,760 hours).
--   * SAFE_DIVIDE returns NULL instead of an error if expected is zero.
--
-- HOW TO READ IT: +20% means the building used 20% more than it normally does
-- in the same conditions. That flags a building to investigate; it does NOT
-- prove a fault. It could be new equipment, longer occupancy, a renovation, or
-- a meter change. Median across buildings should land near 0%.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE bdg2.building_performance AS
SELECT a.building_id,
       ANY_VALUE(a.site_id) AS site_id,
       ANY_VALUE(a.primaryspaceusage) AS primaryspaceusage,
       ANY_VALUE(a.sqft) AS sqft,
       COUNT(*) AS matched_hours,
       SUM(a.kwh) AS actual_kwh,
       SUM(b.baseline_kwh) AS expected_kwh,
       SAFE_DIVIDE(SUM(a.kwh) - SUM(b.baseline_kwh), SUM(b.baseline_kwh)) AS pct_over
FROM bdg2.electricity_analysis a
JOIN bdg2.baseline b
  ON a.building_id = b.building_id
 AND EXTRACT(HOUR FROM a.`timestamp`) = b.hr
 AND (EXTRACT(DAYOFWEEK FROM a.`timestamp`) IN (1, 7)) = b.is_weekend
 AND CAST(FLOOR((a.air_temp_c * 9 / 5 + 32) / 10) AS INT64) = b.temp_bin
WHERE a.`timestamp` >= TIMESTAMP '2017-01-01'
  AND a.air_temp_c IS NOT NULL
  AND a.kwh IS NOT NULL
GROUP BY a.building_id
HAVING matched_hours >= 4000;

-- Top 15 buildings running above their 2016 baseline.
SELECT building_id, primaryspaceusage,
       ROUND(actual_kwh) AS actual_kwh,
       ROUND(expected_kwh) AS expected_kwh,
       ROUND(pct_over * 100, 1) AS pct_over
FROM bdg2.building_performance
ORDER BY pct_over DESC
LIMIT 15;

-- Population summary: how many buildings, the typical (median) change, and how
-- many ran more than 25% over. If the median is far from 0%, investigate before
-- trusting any "outlier" labels.
SELECT COUNT(*) AS buildings,
       ROUND(APPROX_QUANTILES(pct_over, 100)[OFFSET(50)] * 100, 1) AS median_pct_over,
       COUNTIF(pct_over > 0.25) AS over_25pct
FROM bdg2.building_performance;
-- Result: 1,451 buildings; median -2.2% (baseline is centered near zero, as it
-- should be); 55 buildings more than 25% over.
--
-- PROBLEM FOUND: ranking by pct_over put meter artifacts at the top. Monthly
-- totals showed four of the top five had a change INSIDE 2016 (the training
-- year), so their baseline mixed "before" and "after":
--   Lamb_education_Willetta   zero kWh for 23 months (dead meter)
--   Robin_education_Karyl     ~20k/mo, then ~0 for Jun-Sep 2016, then ~70k/mo
--   Peacock_assembly_Socorro  ~1.9k/mo -> ~14k (Sep 2016) -> ~30k (Mar 2017)
--   Robin_education_Della     ~550/mo -> ~4k (Nov 2016)
-- Fix: steps 7-8 check whether the baseline year is trustworthy and FLAG each
-- building instead of silently dropping it.


-- ----------------------------------------------------------------------------
-- 7. BASELINE QUALITY: is each building's 2016 data fit to be a baseline?
--
-- WHAT: Three checks on each building's 2016 data, combined into one status:
--   dead_meter_2016  more than 5% of hours read (almost) zero -> meter was
--                    off or broken for a meaningful stretch
--   low_baseline     under 50,000 kWh for the year -> too small; percentages
--                    on tiny numbers explode and mean little
--   unstable_2016    biggest month is more than 4x the smallest month ->
--                    something changed during the year (step change, outage)
--   ok               passes all three
-- Checks run in that order, so a building gets the first problem that applies.
--
-- WHY:  A baseline is only meaningful if the training period is representative.
--       If the change you are looking for already happened inside the
--       baseline year, the method cannot see it.
--
-- NOTE: The thresholds (5%, 50,000 kWh, 4x) are judgment calls, not standards.
--       Tune them by looking at how many buildings each one flags. Education
--       buildings with summer shutdowns can trip the 4x rule legitimately.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE bdg2.building_quality AS
WITH monthly AS (
  SELECT building_id,
         DATE_TRUNC(DATE(`timestamp`), MONTH) AS month,
         SUM(kwh) AS kwh
  FROM bdg2.electricity_analysis
  WHERE `timestamp` < TIMESTAMP '2017-01-01' AND kwh IS NOT NULL
  GROUP BY building_id, month
),
monthly_stats AS (
  SELECT building_id,
         SUM(kwh) AS annual_kwh_2016,
         SAFE_DIVIDE(MAX(kwh), MIN(kwh)) AS month_ratio
  FROM monthly
  GROUP BY building_id
),
zeros AS (
  SELECT building_id,
         SAFE_DIVIDE(COUNTIF(kwh < 0.5), COUNT(*)) AS near_zero_share
  FROM bdg2.electricity_analysis
  WHERE `timestamp` < TIMESTAMP '2017-01-01' AND kwh IS NOT NULL
  GROUP BY building_id
)
SELECT m.building_id,
       m.annual_kwh_2016,
       m.month_ratio,
       z.near_zero_share,
       CASE
         WHEN z.near_zero_share > 0.05 THEN 'dead_meter_2016'
         WHEN m.annual_kwh_2016 < 50000 THEN 'low_baseline'
         WHEN m.month_ratio > 4 OR m.month_ratio IS NULL THEN 'unstable_2016'
         ELSE 'ok'
       END AS baseline_status
FROM monthly_stats m
JOIN zeros z USING (building_id);


-- ----------------------------------------------------------------------------
-- 8. ATTACH THE STATUS TO THE RESULTS (every building kept)
--
-- WHAT: Same performance table, plus the baseline status and the numbers
--       behind it. Nothing is deleted: filter on baseline_status = 'ok' for
--       trustworthy rankings, and report the others as "needs a different
--       baseline period or a meter check".
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE bdg2.building_performance_flagged AS
SELECT p.*, q.baseline_status, q.annual_kwh_2016, q.month_ratio, q.near_zero_share
FROM bdg2.building_performance p
JOIN bdg2.building_quality q USING (building_id);

-- Status breakdown.
SELECT baseline_status, COUNT(*) AS buildings
FROM bdg2.building_performance_flagged
GROUP BY baseline_status
ORDER BY buildings DESC;
-- Result: ok 1,089 | unstable_2016 237 | low_baseline 85 | dead_meter_2016 40
-- (total 1,451). The earlier top outliers (Lamb, Karyl, Peacock, Della, and
-- Hog_office_Gustavo/Rolando/Terry) are no longer in the 'ok' ranking.

-- Cleaned ranking: biggest absolute excess among trustworthy baselines.
SELECT building_id, primaryspaceusage,
       ROUND(expected_kwh) AS expected_kwh,
       ROUND(actual_kwh - expected_kwh) AS excess_kwh,
       ROUND(pct_over * 100, 1) AS pct_over
FROM bdg2.building_performance_flagged
WHERE baseline_status = 'ok'
ORDER BY excess_kwh DESC
LIMIT 15;
-- Result: top excess ~1.29M kWh (Moose_education_Maria, +23.6%); highest
-- percentages in the list: Eagle_assembly_Josie +54.6%, Robin_education_Zenia
-- +42.8%.
--
-- MONTHLY PROFILE REVIEW of the top candidates (manual check):
--   Moose_education_Maria     flat ~500k/mo for 16 months, then ~+35% step from
--                             May 2017 that persists -> best showcase
--   Robin_education_Zenia     ~+40% step in Oct 2016, flat after -> real shift,
--                             but it happened inside the baseline year
--   Eagle_assembly_Josie      ramped ~50k -> ~195k/mo during 2016 (month ratio
--                             3.9x, just under the 4x cutoff) -> false positive
--   Hog_services_Adrianna     similar to 2016 except March and a large Dec 2017
--                             spike -> candidate for an hourly drill-down
-- Lesson: the quality filter removes most artifacts but not all; review the
-- monthly profile of anything featured.
--
-- SENSITIVITY CHECK: stricter cutoff (month_ratio < 3 instead of < 4).
-- Result: only Eagle_assembly_Josie dropped out (replaced at #15 by
-- Fox_assembly_Adrianne, +26%); the other 14 were unchanged, so the ranking is
-- not sensitive to the exact cutoff.
SELECT building_id, primaryspaceusage,
       ROUND(expected_kwh) AS expected_kwh,
       ROUND(actual_kwh - expected_kwh) AS excess_kwh,
       ROUND(pct_over * 100, 1) AS pct_over,
       ROUND(month_ratio, 1) AS month_ratio
FROM bdg2.building_performance_flagged
WHERE baseline_status = 'ok' AND month_ratio < 3
ORDER BY excess_kwh DESC
LIMIT 15;

-- Noise floor: the population median is about -2.2%, so small percentages on
-- very large buildings are not findings. For the dashboard, highlight buildings
-- that are both >= 15% over and >= 100k kWh of excess.


-- ----------------------------------------------------------------------------
-- 9. EXPORT FOR TABLEAU PUBLIC (run each, then Save results > CSV)
-- Tables in the BigQuery sandbox expire after 60 days, so export the results
-- and keep this SQL in the repo.
-- ----------------------------------------------------------------------------

-- building_summary.csv: one row per building with its baseline status.
SELECT building_id, site_id, primaryspaceusage, sqft,
       matched_hours, actual_kwh, expected_kwh,
       actual_kwh - expected_kwh AS excess_kwh,
       pct_over, baseline_status, month_ratio
FROM bdg2.building_performance_flagged;

-- monthly_by_building.csv: monthly kWh and average temperature (F).
SELECT a.building_id,
       DATE_TRUNC(DATE(a.`timestamp`), MONTH) AS month,
       ROUND(SUM(a.kwh)) AS kwh,
       COUNT(a.kwh) AS hours,
       ROUND(AVG(a.air_temp_c * 9 / 5 + 32), 1) AS avg_temp_f
FROM bdg2.electricity_analysis a
JOIN bdg2.building_performance_flagged p USING (building_id)
GROUP BY a.building_id, month;

-- funnel.csv: how many buildings survive each stage.
SELECT 1 AS step, 'Building columns in raw file' AS stage,
       (SELECT COUNT(*) - 1 FROM bdg2.INFORMATION_SCHEMA.COLUMNS
        WHERE table_name = 'raw_electricity') AS buildings
UNION ALL
SELECT 2, 'With electricity readings',
       (SELECT COUNT(DISTINCT building_id) FROM bdg2.electricity_long)
UNION ALL
SELECT 3, 'Enough matched hours to compare',
       (SELECT COUNT(*) FROM bdg2.building_performance)
UNION ALL
SELECT 4, 'Trustworthy 2016 baseline',
       (SELECT COUNT(*) FROM bdg2.building_performance_flagged
        WHERE baseline_status = 'ok')
ORDER BY step;
