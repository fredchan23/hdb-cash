{% macro flat_age_bucket(age_expr) %}
{#
  Buckets flat_age_years into a fixed set of labelled ranges.
  Labels are left-zero-padded so they sort correctly as strings.
#}
case
  when {{ age_expr }} <  10 then '00-09'
  when {{ age_expr }} <  20 then '10-19'
  when {{ age_expr }} <  30 then '20-29'
  when {{ age_expr }} <  40 then '30-39'
  when {{ age_expr }} <  50 then '40-49'
  when {{ age_expr }} <  60 then '50-59'
  else                           '60+'
end
{% endmacro %}
