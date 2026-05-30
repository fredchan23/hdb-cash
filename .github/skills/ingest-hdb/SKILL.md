---
name: ingest-hdb
description: "Ingest a new HDB resale CSV release into the pipeline. Use when: loading a new monthly HDB data release, uploading CSVs to GCS, appending rows to BigQuery raw table, running full-refresh after ingestion, verifying end-to-end pipeline after new data arrives."
argument-hint: "Path to the new CSV file, or 'bulk' to reload all data-raw/ CSVs"
---

# ingest-hdb — Load a New HDB Release into the Pipeline

## When to Use
- A new monthly CSV has been downloaded from data.gov.sg
- Bulk re-loading all `data-raw/` CSVs from scratch
- Verifying the pipeline is healthy after data lands in BigQuery

---

## Environment Setup

```bash
cd /home/fredc/codeforfun/hdb-cash
source .venv/bin/activate
```

If GCS/BQ auth fails, refresh ADC first:
```bash
gcloud auth application-default login
```

---

## Procedure

### Step 1 — Place the CSV

Save the new file into `data-raw/` with a descriptive filename.  
File naming convention examples:
- `Resale flat prices based on registration date from Jan-2017 onwards.csv`
- `Resale Flat Prices (Based on Registration Date), From Jan 2015 to Dec 2016.csv`

The script auto-detects `source_basis` from the filename (`"approval"` if `"approval"` appears in the name, otherwise `"registration"`).

### Step 2 — Ingest the new file

```bash
# Single new release
python ingestion/load_to_bq.py --source-file data-raw/<new-file>.csv

# Bulk reload all CSVs (first-time setup or full re-ingest)
python ingestion/load_to_bq.py --source-dir data-raw/
```

Options:
- `--skip-gcs` — skip GCS upload, write directly to BigQuery (local dev only)
- `DBT_GOOGLE_KEYFILE` env var — path to SA JSON key; falls back to ADC if unset

### Step 3 — Full-refresh dbt (mandatory after any ingestion)

Ingestion appends rows; re-running creates raw duplicates. Staging deduplicates with `QUALIFY row_number()`, but **always full-refresh** to rebuild cleanly:

```bash
cd dbt
dbt run --full-refresh
```

### Step 4 — Run all tests

```bash
dbt test
```

All 31 tests should pass. If any fail, see the [dbt-hdb skill](./../dbt-hdb/SKILL.md) for diagnostics.

### Step 5 — Verify row counts

```bash
bq query --use_legacy_sql=false --project_id=hdb-cash \
  'SELECT "raw" as layer, COUNT(*) as rows FROM raw.hdb_resale_transactions
   UNION ALL SELECT "staging", COUNT(*) FROM staging_dev_staging.stg_hdb_resale_transactions
   UNION ALL SELECT "decade_summary", COUNT(*) FROM staging_dev_mart.mart_age_price_decade_summary
   UNION ALL SELECT "regression_inputs", COUNT(*) FROM staging_dev_mart.mart_age_price_regression_inputs'
```

Staging row count should increase by the number of new transactions in the file.  
Decade summary and regression inputs will grow proportionally.

---

## Schema Variants — What to Expect per File Era

| File era | `remaining_lease` | `source_basis` detected as |
|---|---|---|
| 1990–1999, 2000–Feb 2012 | absent (NULL) | `approval` |
| Mar 2012–Dec 2014 | absent (NULL) | `registration` |
| Jan 2015 → | present (string) | `registration` |

The staging model handles all variants via the `parse_remaining_lease()` macro — no manual adjustments needed.

---

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `PyArrow TIMESTAMP conversion` | `loaded_at` set as string, not `datetime` | Ensure `load_to_bq.py` sets `loaded_at` as `datetime` object |
| Row count didn't change in staging | Forgot `--full-refresh` | `dbt run --full-refresh` |
| Auth error in `load_to_bq.py` | ADC expired | `gcloud auth application-default login` |
| Duplicate rows in raw | Re-ran ingestion | Normal — staging deduplicates; do `dbt run --full-refresh` |

---

## Key References
- [ingestion/load_to_bq.py](../../ingestion/load_to_bq.py)
- [dbt-hdb skill](./../dbt-hdb/SKILL.md)
- [stg_hdb_resale_transactions.sql](../../dbt/models/staging/stg_hdb_resale_transactions.sql)
