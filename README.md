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

## Pipeline status

The full pipeline is operational: 978k rows in staging, 849 rows in `mart_age_price_decade_summary`, 972k rows in `mart_age_price_regression_inputs`. All 31 dbt tests pass.

## Daily dev commands

```bash
cd /home/fredc/codeforfun/hdb-cash
source .venv/bin/activate
cd dbt
dbt run        # incremental by default
dbt test
dbt run --full-refresh   # required after any re-ingestion
```

## Agent skills

AI coding agents can use the following skills and prompts in this project (type `/` in Copilot Chat):

| Slash command | Type | What it does |
|---|---|---|
| `/dbt-hdb` | Skill | Run and validate the dbt pipeline — incremental, full-refresh, single-model, test-only, row-count checks, and failure diagnostics |
| `/ingest-hdb` | Skill | Load a new monthly HDB CSV into GCS + BigQuery raw, then full-refresh dbt and verify row counts end-to-end |
| `/add-mart-model` | Skill | Scaffold a new mart `.sql` + `_mart.yml` entry following project conventions (table materialization, no ORDER BY, INT64 decade, schema tests) |
| `/debug-dbt-test` | Prompt | Diagnose a failing dbt test by name — matches against known pitfalls and inspects compiled SQL |

Skills live in [.github/skills/](.github/skills/) · Prompt lives in [.github/prompts/](.github/prompts/)
