-- Each screening stage is a subset of the one before it, so the building count
-- can only stay the same or go down. Fails on any stage that has more
-- buildings than the previous stage.

with stages as (
    select
        step,
        stage,
        buildings,
        lag(buildings) over (order by step) as previous_buildings
    from {{ ref("screening_funnel") }}
)

select *
from stages
where buildings > previous_buildings
