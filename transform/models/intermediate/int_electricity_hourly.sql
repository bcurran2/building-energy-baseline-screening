{{ config(cluster_by=["building_id"]) }}

-- One row per building-hour: the reading, what kind of building it is, the
-- outdoor temperature at its site, and the conditions the baseline groups by.
--
-- * Buildings join to weather through site_id, because weather is per site.
-- * The weather join is a LEFT JOIN, so a missing weather hour keeps the
--   reading (with a NULL temperature) instead of deleting it.
-- * The baseline conditions (hour of day, weekend, 10 F temperature band) are
--   computed once here, so the baseline and the comparison can never disagree
--   about how a bin is defined.

with electricity as (
    select * from {{ ref("stg_bdg2__electricity") }}
),

buildings as (
    select * from {{ ref("stg_bdg2__buildings") }}
),

weather as (
    select * from {{ ref("stg_bdg2__weather") }}
)

select
    e.reading_ts,
    e.building_id,
    e.kwh,
    b.site_id,
    b.primary_space_usage,
    b.sqft,
    w.air_temp_c,
    w.air_temp_c * 9 / 5 + 32                                     as air_temp_f,
    extract(hour from e.reading_ts)                               as hour_of_day,
    extract(dayofweek from e.reading_ts) in (1, 7)                as is_weekend,
    cast(floor((w.air_temp_c * 9 / 5 + 32) / 10) as int64)        as temp_bin_10f,
    e.reading_ts < timestamp("{{ var('comparison_start') }}")     as is_baseline_period
from electricity as e
inner join buildings as b
    on e.building_id = b.building_id
left join weather as w
    on w.site_id = b.site_id
    and w.weather_ts = e.reading_ts
