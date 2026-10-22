-- One row per site per hour (enforced by a test, not silently averaged:
-- a duplicate would multiply meter rows in the join downstream).

select
    site_id,
    `timestamp`    as weather_ts,
    airTemperature as air_temp_c,
    dewTemperature as dew_temp_c,
    cloudCoverage  as cloud_coverage,
    precipDepth1HR as precip_depth_1hr,
    precipDepth6HR as precip_depth_6hr,
    seaLvlPressure as sea_level_pressure,
    windDirection  as wind_direction,
    windSpeed      as wind_speed
from {{ source("bdg2", "weather") }}
