-- How did each building do in the comparison year against its baseline?
--
-- Each comparison-year hour is matched to the same building's baseline for the
-- same hour of day, weekday/weekend flag, and temperature band. Only matched
-- hours count, and the same hours feed both sums, so it is like-for-like:
--
--     pct_over = (actual - expected) / expected
--
-- +20% means the building used 20% more than it normally does in the same
-- conditions. That flags it for investigation; it does not prove a fault.

with hourly as (
    select * from {{ ref("int_electricity_hourly") }}
    where not is_baseline_period
        and air_temp_c is not null
        and kwh is not null
),

baseline as (
    select * from {{ ref("int_building_baseline") }}
)

select
    h.building_id,
    any_value(h.site_id)             as site_id,
    any_value(h.primary_space_usage) as primary_space_usage,
    any_value(h.sqft)                as sqft,
    count(*)                         as matched_hours,
    sum(h.kwh)                       as actual_kwh,
    sum(b.baseline_kwh)              as expected_kwh,
    safe_divide(sum(h.kwh) - sum(b.baseline_kwh), sum(b.baseline_kwh)) as pct_over
from hourly as h
inner join baseline as b
    on h.building_id = b.building_id
    and h.hour_of_day = b.hour_of_day
    and h.is_weekend = b.is_weekend
    and h.temp_bin_10f = b.temp_bin_10f
group by h.building_id
having count(*) >= {{ var("min_matched_hours") }}
