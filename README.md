# hdb-cash

Analytics project for studying how HDB flat age affects resale price across decades.

## Goal

Build a future-proof pipeline that:
- ingests each authority release idempotently
- standardizes historical schema differences
- computes flat age and lease features consistently
- serves dashboard-ready marts from BigQuery via dbt

## Planned layers

- `raw`: landed source data with lineage metadata
- `staging`: cleaned and standardized transaction grain
- `mart`: aggregated and analysis-ready tables for the dashboard
- `audit`: row counts, freshness, schema drift, and validation outputs

## Current raw inputs

The repository currently contains five CSV exports in `data-raw/` covering 1990-01 through 2026-05.

## Next implementation step

1. Load each release into GCS and BigQuery raw tables.
2. Build dbt staging models that normalize schema differences.
3. Build marts for age-versus-price analysis by decade.
4. Connect the dashboard only to marts.
