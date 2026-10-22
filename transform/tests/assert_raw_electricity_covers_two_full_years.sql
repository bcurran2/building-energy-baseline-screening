-- The raw electricity file should have exactly one row per hour for 2016-2017:
-- 8,784 (2016 was a leap year) + 8,760 = 17,544 rows, no duplicate hours.
-- Returns a row (= test fails) if the load is incomplete or duplicated.

with stats as (
    select
        count(*)                    as row_count,
        count(distinct `timestamp`) as distinct_hours
    from {{ source("bdg2", "electricity") }}
)

select *
from stats
where row_count != {{ var("expected_hours") }}
    or distinct_hours != row_count
