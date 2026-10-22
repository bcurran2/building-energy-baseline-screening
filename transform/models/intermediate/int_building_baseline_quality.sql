-- Is each building's baseline-year data fit to be a baseline?
--
-- Added after the first ranking put meter artifacts at the top: several
-- "top" buildings had a change inside 2016, so their baseline mixed "before"
-- and "after". Three checks, combined into one status (first match wins):
--
--   dead_meter_2016  more than dead_meter_share of hours read near zero
--   low_baseline     under low_baseline_kwh for the year (percentages on tiny
--                    numbers explode and mean little)
--   unstable_2016    biggest month more than unstable_month_ratio x the
--                    smallest (a step change or outage inside the year)
--   ok               passes all three
--
-- Buildings are flagged, never deleted. The thresholds are judgment calls;
-- they are dbt vars so a sensitivity run is one command.

with baseline_year as (
    select building_id, reading_ts, kwh
    from {{ ref("int_electricity_hourly") }}
    where is_baseline_period
        and kwh is not null
),

monthly as (
    select
        building_id,
        date_trunc(date(reading_ts), month) as month,
        sum(kwh)                            as kwh
    from baseline_year
    group by building_id, month
),

monthly_stats as (
    select
        building_id,
        sum(kwh)                         as annual_kwh_2016,
        safe_divide(max(kwh), min(kwh))  as month_ratio
    from monthly
    group by building_id
),

zeros as (
    select
        building_id,
        safe_divide(countif(kwh < {{ var("near_zero_kwh") }}), count(*)) as near_zero_share
    from baseline_year
    group by building_id
)

select
    m.building_id,
    m.annual_kwh_2016,
    m.month_ratio,
    z.near_zero_share,
    case
        when z.near_zero_share > {{ var("dead_meter_share") }} then "dead_meter_2016"
        when m.annual_kwh_2016 < {{ var("low_baseline_kwh") }} then "low_baseline"
        when m.month_ratio > {{ var("unstable_month_ratio") }} or m.month_ratio is null then "unstable_2016"
        else "ok"
    end as baseline_status
from monthly_stats as m
inner join zeros as z
    using (building_id)
