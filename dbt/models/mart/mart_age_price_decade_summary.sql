{{
  config(
    materialized = 'table',
    cluster_by   = ['transaction_decade', 'flat_age_bucket', 'flat_type']
  )
}}

-- mart_age_price_decade_summary
-- Pre-aggregated summary consumed directly by the analytics dashboard.
-- One row per (decade, flat_age_bucket, flat_type) combination.

select
    cast(transaction_decade as string)                         as transaction_decade,
    flat_age_bucket,
    flat_type,

    count(*)                                                   as transaction_count,

    round(avg(resale_price), 0)                                as avg_resale_price,
    round(approx_quantiles(resale_price, 100)[offset(50)], 0) as median_resale_price,
    round(min(resale_price), 0)                                as min_resale_price,
    round(max(resale_price), 0)                                as max_resale_price,

    round(avg(log_resale_price), 6)                            as avg_log_resale_price,

    round(avg(floor_area_sqm), 1)                              as avg_floor_area_sqm,
    round(avg(flat_age_years), 1)                              as avg_flat_age_years,
    round(avg(remaining_lease_months), 0)                      as avg_remaining_lease_months,

    -- Price per sqm (normalises for size differences across decades)
    round(avg(resale_price / nullif(floor_area_sqm, 0)), 0)    as avg_price_per_sqm,
    round(
        approx_quantiles(resale_price / nullif(floor_area_sqm, 0), 100)[offset(50)], 0
    )                                                          as median_price_per_sqm

from {{ ref('stg_hdb_resale_transactions') }}
group by 1, 2, 3
