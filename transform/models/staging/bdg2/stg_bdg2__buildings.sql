-- One row per building. The raw table is all text; this is where it gets typed.
-- SAFE_CAST returns NULL instead of failing on a value that will not convert.

select
    building_id,
    site_id,
    primaryspaceusage                                   as primary_space_usage,
    sub_primaryspaceusage                               as sub_primary_space_usage,
    safe_cast(sqft as float64)                          as sqft,
    safe_cast(sqm as float64)                           as sqm,
    safe_cast(lat as float64)                           as latitude,
    safe_cast(lng as float64)                           as longitude,
    timezone,
    cast(safe_cast(yearbuilt as float64) as int64)      as year_built,
    cast(safe_cast(numberoffloors as float64) as int64) as number_of_floors
from {{ source("bdg2", "buildings") }}
