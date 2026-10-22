-- "What does each building normally use?"
--
-- For each building, the median baseline-year kWh under each combination of
-- hour of day, weekday/weekend, and 10 F outdoor temperature band.
-- Example row: Bldg X, 2pm, weekday, 80-90 F -> median 140 kWh.
--
-- * Median, not average: spikes and meter glitches barely move a median.
--   APPROX_QUANTILES(kwh, 2)[OFFSET(1)] is BigQuery's approximate median.
-- * Conditions seen fewer than `min_condition_hours` times are dropped; a
--   median of one or two readings is not a trustworthy baseline.

select
    building_id,
    hour_of_day,
    is_weekend,
    temp_bin_10f,
    approx_quantiles(kwh, 2)[offset(1)] as baseline_kwh,
    count(*)                            as n_hours
from {{ ref("int_electricity_hourly") }}
where is_baseline_period
    and air_temp_c is not null
    and kwh is not null
group by building_id, hour_of_day, is_weekend, temp_bin_10f
having count(*) >= {{ var("min_condition_hours") }}
