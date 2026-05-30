{{
  config(
    materialized  = 'incremental',
    unique_key    = 'transaction_id',
    partition_by  = {
      'field'       : 'transaction_month',
      'data_type'   : 'date',
      'granularity' : 'month'
    },
    cluster_by    = ['town', 'flat_type', 'lease_commence_date'],
    on_schema_change = 'sync_all_columns'
  )
}}

with source_raw as (

    select *
    from {{ source('raw', 'hdb_resale_transactions') }}

    {% if is_incremental() %}
    -- Only process records newer than the latest loaded batch
    where loaded_at > (select max(loaded_at) from {{ this }})
    {% endif %}

),

-- Deduplicate: raw table may have duplicates if ingestion is re-run.
-- Keep the most-recently-loaded copy of each natural key.
source as (

    select *
    from source_raw
    qualify row_number() over (
        partition by month, town, block, street_name,
                     flat_type, floor_area_sqm, lease_commence_date, resale_price
        order by loaded_at desc
    ) = 1

),

cleaned as (

    select
        -- ----------------------------------------------------------------
        -- Surrogate key (stable across reruns)
        -- ----------------------------------------------------------------
        {{ dbt_utils.generate_surrogate_key([
            'month', 'town', 'block', 'street_name',
            'flat_type', 'floor_area_sqm', 'lease_commence_date', 'resale_price'
        ]) }}                                                   as transaction_id,

        -- ----------------------------------------------------------------
        -- Time fields
        -- ----------------------------------------------------------------
        parse_date('%Y-%m', month)                             as transaction_month,
        extract(year  from parse_date('%Y-%m', month))         as transaction_year,
        cast(
          extract(year from parse_date('%Y-%m', month)) / 10 * 10
          as int64
        )                                                      as transaction_decade,

        -- ----------------------------------------------------------------
        -- Location (normalised to UPPER CASE)
        -- ----------------------------------------------------------------
        upper(trim(town))                                      as town,
        upper(trim(block))                                     as block,
        upper(trim(street_name))                               as street_name,

        -- ----------------------------------------------------------------
        -- Property attributes
        -- ----------------------------------------------------------------
        upper(trim(flat_type))                                 as flat_type,
        initcap(lower(trim(flat_model)))                       as flat_model,
        safe_cast(floor_area_sqm as float64)                   as floor_area_sqm,

        -- Storey range parsed to low / high integer
        safe_cast(
          split(storey_range, ' TO ')[safe_offset(0)] as int64
        )                                                      as storey_low,
        safe_cast(
          split(storey_range, ' TO ')[safe_offset(1)] as int64
        )                                                      as storey_high,

        -- ----------------------------------------------------------------
        -- Lease fields
        -- ----------------------------------------------------------------
        safe_cast(lease_commence_date as int64)                as lease_commence_date,

        -- Harmonise remaining_lease → integer months (see macro)
        {{ parse_remaining_lease('remaining_lease') }}         as remaining_lease_months_reported,

        case
          when remaining_lease is not null
           and trim(remaining_lease) != ''
          then 'reported'
          else 'estimated'
        end                                                    as remaining_lease_source,

        -- ----------------------------------------------------------------
        -- Price
        -- ----------------------------------------------------------------
        safe_cast(resale_price as float64)                     as resale_price,
        ln(safe_cast(resale_price as float64))                 as log_resale_price,

        -- ----------------------------------------------------------------
        -- Source lineage
        -- ----------------------------------------------------------------
        source_file,
        source_basis,
        loaded_at

    from source
    where
        month         is not null
        and lease_commence_date is not null
        and safe_cast(resale_price as float64) > 0

),

with_age as (

    select
        *,

        -- Primary age feature
        transaction_year - lease_commence_date                 as flat_age_years,

        -- Estimated remaining lease when not reported
        coalesce(
            remaining_lease_months_reported,
            greatest(0, (lease_commence_date + 99 - transaction_year) * 12)
        )                                                      as remaining_lease_months

    from cleaned

),

final as (

    select
        *,
        -- Age bucket (sorts alphabetically as written)
        {{ flat_age_bucket('flat_age_years') }}                as flat_age_bucket,
        -- Non-linear age term for regression models
        flat_age_years * flat_age_years                        as flat_age_years_sq

    from with_age
    -- Hard quality gate: ages outside 0-99 indicate bad source data
    where flat_age_years between 0 and 99

)

select * from final
