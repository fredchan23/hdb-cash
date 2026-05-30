-- tests/assert_flat_age_valid.sql
-- Singular test: returns rows where flat_age_years is outside the valid 0-99 range.
-- A non-empty result will fail the dbt test run.

select
    transaction_id,
    transaction_month,
    lease_commence_date,
    transaction_year,
    flat_age_years
from {{ ref('stg_hdb_resale_transactions') }}
where flat_age_years < 0
   or flat_age_years > 99
