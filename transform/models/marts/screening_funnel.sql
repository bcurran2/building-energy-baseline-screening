-- Dashboard table: how many buildings survive each stage of the screening.
-- Exported to dashboard_data/funnel.csv, same columns as the original export.

{%- set raw_building_count = building_columns(source("bdg2", "electricity")) | length %}

select 1 as step, "Building columns in raw file" as stage, {{ raw_building_count }} as buildings
union all
select 2, "With electricity readings",
    (select count(distinct building_id) from {{ ref("stg_bdg2__electricity") }})
union all
select 3, "Enough matched hours to compare",
    (select count(*) from {{ ref("int_building_performance") }})
union all
select 4, "Trustworthy 2016 baseline",
    (select count(*) from {{ ref("building_summary") }} where baseline_status = "ok")
