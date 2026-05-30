---
name: dbt-hdb
description: "Run and validate the hdb-cash dbt pipeline. Use when: running dbt models, running dbt tests, checking pipeline health, validating after ingestion, debugging dbt failures, full-refresh rebuild, verifying row counts in staging or mart."
argument-hint: "Optional: 'full-refresh', 'test-only', a model selector (e.g. stg_hdb_resale_transactions), or a mart name"
---

# dbt-hdb — Run & Validate the HDB Pipeline

## When to Use
- After ingesting new CSVs (always run `--full-refresh` post-ingestion)
- To validate all 31 tests pass before dashboard work
- To debug a failing model or test
- To run a single model or layer selectively

---

## Environment Setup

Always activate the project virtualenv first:

```bash
cd /home/fredc/codeforfun/hdb-cash
source .venv/bin/activate
cd dbt
```

Authentication uses ADC — if dbt fails with an auth error, refresh first:
```bash
gcloud auth application-default login
```

---

## Procedure

### 1. Standard incremental run + test (daily dev)

```bash
dbt run
dbt test
```

### 2. Full-refresh rebuild (required after any re-ingestion)

```bash
dbt run --full-refresh
dbt test
```

Use full-refresh when:
- A new CSV was loaded via `load_to_bq.py`
- Ingestion was re-run (duplicates may have entered raw)
- A staging model schema changed (`on_schema_change: sync_all_columns` handles column additions, but full-refresh is safer for type changes)

### 3. Run a single model

```bash
dbt run --select stg_hdb_resale_transactions
dbt run --select mart_age_price_decade_summary
dbt run --select mart_age_price_regression_inputs
```

### 4. Test only (no model run)

```bash
dbt test
dbt test --select stg_hdb_resale_transactions  # staging tests only
dbt test --select mart_age_price_decade_summary
```

### 5. Verify row counts (expected healthy state)

Run after a full pipeline pass to confirm expected scale:

```bash
bq query --use_legacy_sql=false --project_id=hdb-cash \
  'SELECT "staging" as layer, COUNT(*) as rows FROM staging_dev_staging.stg_hdb_resale_transactions
   UNION ALL SELECT "decade_summary", COUNT(*) FROM staging_dev_mart.mart_age_price_decade_summary
   UNION ALL SELECT "regression_inputs", COUNT(*) FROM staging_dev_mart.mart_age_price_regression_inputs'
```

Expected: ~978k staging rows, ~849 decade summary rows, ~972k regression input rows.

---

## Diagnosing Failures

| Symptom | Likely cause | Fix |
|---|---|---|
| Duplicate `transaction_id` unique test failure | Re-ran ingestion without full-refresh | `dbt run --full-refresh` |
| `remaining_lease` cast error | Direct `SAFE_CAST` instead of macro | Use `{{ parse_remaining_lease('remaining_lease') }}` |
| `ORDER BY` error on mart | Added `ORDER BY` to a clustered-table mart | Remove `ORDER BY` from that mart model |
| `accepted_values` test fails for `transaction_decade` | Using built-in test with INT64 | Use `dbt_utils.accepted_range(min_value: 1990, max_value: 2029)` |
| Auth / credential error | ADC token expired | `gcloud auth application-default login` |

---

## BigQuery Targets

| dbt target | BQ dataset | When to use |
|---|---|---|
| `dev` (default) | `staging_dev_staging`, `staging_dev_mart` | All local development |
| `prod` | TBD (Workload Identity Federation) | Future CI/CD |

Profile is read from `~/.dbt/profiles.yml` (copied from [profiles.yml.template](../../profiles.yml.template)).

---

## Key Model References

- [stg_hdb_resale_transactions.sql](../../models/staging/stg_hdb_resale_transactions.sql) — incremental staging model
- [mart_age_price_decade_summary.sql](../../models/mart/mart_age_price_decade_summary.sql) — dashboard summary
- [mart_age_price_regression_inputs.sql](../../models/mart/mart_age_price_regression_inputs.sql) — transaction-level regression mart
- [parse_remaining_lease.sql](../../macros/parse_remaining_lease.sql) — normalises lease string/int to months
- [assert_flat_age_valid.sql](../../tests/assert_flat_age_valid.sql) — singular test: flat_age_years in 0–99
