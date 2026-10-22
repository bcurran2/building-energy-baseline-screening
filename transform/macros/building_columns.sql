{% macro building_columns(relation, exclude=["timestamp"]) %}
  {#-
    Returns the building column names of the wide electricity table.

    The raw table has one column per building (1,578 of them), far too many
    to type. Like the original INFORMATION_SCHEMA + EXECUTE IMMEDIATE approach,
    this reads the column list from the warehouse at run time, so a source file
    with more or fewer buildings needs no code change. dbt makes it simpler:
    the list is built here in Jinja and the model stays plain SQL.

    During parsing (execute = false) there is no warehouse connection, so it
    returns an empty list.
  -#}
  {%- if not execute -%}
    {{ return([]) }}
  {%- endif -%}

  {%- set names = [] -%}
  {%- for col in adapter.get_columns_in_relation(relation) -%}
    {%- if col.name not in exclude -%}
      {%- do names.append(col.name) -%}
    {%- endif -%}
  {%- endfor -%}

  {%- if names | length == 0 -%}
    {{ exceptions.raise_compiler_error("No building columns found in " ~ relation ~ ". Has the ingest step run?") }}
  {%- endif -%}

  {{ return(names) }}
{% endmacro %}
