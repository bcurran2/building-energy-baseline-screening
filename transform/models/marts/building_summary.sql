-- Dashboard table: one row per building that could be compared, with its
-- baseline status. Exported to dashboard_data/building_summary.csv.
--
-- Column names and order match the original building_summary.csv export so
-- the Tableau Public dashboard can take a refreshed file without changes
-- (hence `primaryspaceusage`, not the staging name).
-- Filter on baseline_status = 'ok' for the trustworthy ranking.

with performance as (
    select * from {{ ref("int_building_performance") }}
),

quality as (
    select * from {{ ref("int_building_baseline_quality") }}
)

select
    p.building_id,
    p.site_id,
    p.primary_space_usage           as primaryspaceusage,
    p.sqft,
    p.matched_hours,
    p.actual_kwh,
    p.expected_kwh,
    p.actual_kwh - p.expected_kwh   as excess_kwh,
    p.pct_over,
    q.baseline_status,
    q.month_ratio
from performance as p
inner join quality as q
    using (building_id)
