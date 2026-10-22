-- Dashboard table: monthly kWh and average temperature (F) for every building
-- in building_summary. Exported to dashboard_data/monthly_by_building.csv,
-- with the same columns as the original export.

with hourly as (
    select * from {{ ref("int_electricity_hourly") }}
),

buildings as (
    select building_id from {{ ref("building_summary") }}
)

select
    h.building_id,
    date_trunc(date(h.reading_ts), month) as month,
    round(sum(h.kwh))                     as kwh,
    count(h.kwh)                          as hours,
    round(avg(h.air_temp_f), 1)           as avg_temp_f
from hourly as h
inner join buildings as b
    using (building_id)
group by h.building_id, month
