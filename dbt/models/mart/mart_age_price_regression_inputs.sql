{{
  config(
    materialized = 'table',
    partition_by = {
      'field'       : 'transaction_month',
      'data_type'   : 'date',
      'granularity' : 'month'
    },
    cluster_by = ['transaction_decade', 'flat_type', 'town']
  )
}}

-- mart_age_price_regression_inputs
-- Transaction-level table prepared for regression / statistical modelling.
-- Includes all engineered features needed for the age-impact analysis.

select
    transaction_id,
    transaction_month,
    transaction_year,
    transaction_decade,

    -- Location
    town,

    -- Property attributes
    flat_type,
    flat_model,
    floor_area_sqm,
    storey_low,
    storey_high,
    round((storey_low + storey_high) / 2.0, 1)   as storey_midpoint,

    -- Lease and age features
    lease_commence_date,
    flat_age_years,
    flat_age_years_sq,                            -- for quadratic age term in OLS
    flat_age_bucket,
    remaining_lease_months,
    remaining_lease_source,

    -- Target variables
    resale_price,
    log_resale_price,                             -- use for log-linear regression
    round(resale_price / nullif(floor_area_sqm, 0), 0) as resale_price_per_sqm,

    -- Metadata for filtering / sensitivity checks
    source_basis,                                 -- 'approval' vs 'registration'
    source_file

from {{ ref('stg_hdb_resale_transactions') }}
