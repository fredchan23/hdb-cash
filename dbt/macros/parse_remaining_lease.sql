{% macro parse_remaining_lease(column_name) %}
{#
  Normalises remaining_lease to INTEGER months across two source formats:
    - Numeric string only  e.g. "70"         → 70 years  → 840 months
    - Text format          e.g. "61 years 04 months" → 61*12 + 4 = 736 months
  Returns NULL when the value is absent or unparseable.
#}
case
  -- "N years M months" format (from Jan-2017 onwards dataset)
  when {{ column_name }} like '%years%'
    then
      safe_cast(regexp_extract({{ column_name }}, r'^(\d+)') as int64) * 12
      + coalesce(
          safe_cast(regexp_extract({{ column_name }}, r'(\d+)\s+months?') as int64),
          0
        )
  -- Plain integer string interpreted as whole years (2015-2016 dataset)
  when regexp_contains(trim(coalesce({{ column_name }}, '')), r'^\d+$')
    then safe_cast(trim({{ column_name }}) as int64) * 12
  else null
end
{% endmacro %}
