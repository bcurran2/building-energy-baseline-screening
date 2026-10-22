-- Method sanity check. Most buildings do not change much from one year to the
-- next, so a working baseline should put the median building near 0% over.
-- (The original run: -2.2%.) If the median drifts outside +/-10%, something in
-- the baseline logic is off, and no individual "outlier" should be trusted.

with medians as (
    select approx_quantiles(pct_over, 100)[offset(50)] as median_pct_over
    from {{ ref("building_summary") }}
    where baseline_status = "ok"
)

select *
from medians
where median_pct_over not between -0.10 and 0.10
    or median_pct_over is null
