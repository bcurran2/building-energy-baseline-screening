-- Joining buildings and weather onto the readings must not drop or duplicate
-- any reading. A duplicate weather row, or a reading whose building is missing
-- from the metadata, would change the count. Fails if the counts differ.

with counts as (
    select
        (select count(*) from {{ ref("stg_bdg2__electricity") }}) as readings,
        (select count(*) from {{ ref("int_electricity_hourly") }}) as enriched
)

select *
from counts
where readings != enriched
