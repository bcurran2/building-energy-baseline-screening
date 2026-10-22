{{ config(materialized="table", cluster_by=["building_id"]) }}

{#-
  Reshape wide -> long: one row per building per hour.

      timestamp | BldgA | BldgB          reading_ts | building_id | kwh
      ----------+-------+------    ->    -----------+-------------+-----
      1am       |  10   |  20            1am        | BldgA       |  10
                                         1am        | BldgB       |  20

  UNPIVOT drops NULL readings, so only real measurements come through.
  The column types are already FLOAT64 because the ingest step declares them,
  so no SAFE_CAST is needed here.

  Materialized as a table (clustered by building) because everything
  downstream reads it. It is not partitioned by date on purpose: in the
  BigQuery sandbox, partitions expire 60 days after their partition date, so
  2016-2017 partitions would expire as soon as they were written.
-#}

{%- set buildings = building_columns(source("bdg2", "electricity")) %}

select
    `timestamp` as reading_ts,
    building_id,
    kwh
from {{ source("bdg2", "electricity") }}
unpivot (
    kwh for building_id in (
        {%- for b in buildings %}
        `{{ b }}`{{ "," if not loop.last }}
        {%- endfor %}
    )
)
