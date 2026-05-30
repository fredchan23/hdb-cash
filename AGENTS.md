# Agent Instructions — hdb-cash

Analytics pipeline for studying how HDB flat age affects resale price across decades.
Stack: **CSV → GCS → BigQuery (`raw`) → dbt (`staging`, `mart`) → dashboard**.

---

## Project layout

| Path | Purpose |
|---|---|
| `data-raw/` | Five CSV exports from HDB, 1990-01 → 2026-05 |
| `ingestion/load_to_bq.py` | Upload CSVs to GCS + append to BQ `raw.hdb_resale_transactions` |
| `dbt/` | dbt project `hdb_cash`; profile `hdb_cash` |
| `dbt/models/staging/` | Single incremental model `stg_hdb_resale_transactions` |
| `dbt/models/mart/` | Dashboard-ready marts (`mart_age_price_decade_summary`, `mart_age_price_regression_inputs`) |
| `dbt/macros/` | `parse_remaining_lease.sql`, `flat_age_bucket.sql` |
| `dbt/tests/` | Singular tests (e.g. `assert_flat_age_valid.sql`) |
| `infra/setup_gcp.sh` | One-shot GCP provisioning (buckets, datasets, SAs, IAM) |
| `.venv/` | Project virtualenv (python 3.12); **not committed** |

---

## Daily dev commands

```bash
cd /home/fredc/codeforfun/hdb-cash
source .venv/bin/activate
cd dbt
dbt run        # incremental by default
dbt test
```

Run a full rebuild after re-ingesting data:

```bash
dbt run --full-refresh
```

Ingest a new CSV release:

```bash
python ingestion/load_to_bq.py --source-file /path/to/new_release.csv
```

---

## BigQuery layout

| BQ dataset | dbt schema key | dbt `+schema:` |
|---|---|---|
| `raw` | source only | n/a |
| `staging_dev_staging` | staging (dev) | `staging` |
| `staging_dev_mart` | mart (dev) | `mart` |

GCP project ID: **`hdb-cash`**, region: **`asia-southeast1`**.

Authentication uses ADC (`gcloud auth application-default login`).  
`DBT_GOOGLE_KEYFILE` env var is optional; `load_to_bq.py` falls back to ADC when unset.

---

## Key conventions

- **Dashboard reads only from marts**, never from staging or raw.
- Staging model is **incremental** on `transaction_id` (surrogate key from `dbt_utils.generate_surrogate_key`), partitioned by `transaction_month` (date, monthly), clustered by `town / flat_type / lease_commence_date`.
- Mart models are **tables** (no incremental).
- All text fields normalised to `UPPER CASE` in staging.
- `transaction_decade` is `INT64` (e.g. `1990`, `2000`).

---

## Known pitfalls

- **Duplicate raw rows**: `load_to_bq.py` appends; re-running ingestion creates duplicates. Staging deduplicates with `QUALIFY row_number()` on the natural key. Always `dbt run --full-refresh` after re-ingestion.
- **`remaining_lease`** is absent in pre-2015 files and is either a plain integer (years) or a string like `"61 years 04 months"` in later files. Use `parse_remaining_lease()` macro — do not cast directly.
- **BigQuery forbids `ORDER BY` on clustered tables** in `CREATE TABLE AS SELECT`. Do not add `ORDER BY` to mart models.
- **`accepted_values` with integers**: use `dbt_utils.accepted_range` instead of the built-in `accepted_values` test (YAML `quote: false` is mis-parsed by dbt).
- **Org policy blocks SA key files** (`constraints/iam.disableServiceAccountKeyCreation`). Dev profile uses `method: oauth` (ADC). Prod target uses `service-account` for future CI/CD via Workload Identity Federation.

---

## Schema variants in raw CSVs

| File era | Date basis | `remaining_lease` column |
|---|---|---|
| 1990 – 1999, 2000 – Feb 2012 | Approval date | absent |
| Mar 2012 – Dec 2014 | Registration date | absent |
| Jan 2015 – Dec 2016 | Registration date | present (string) |
| Jan 2017 → | Registration date | present (string) |

---

## Useful references

- [dbt staging model](dbt/models/staging/stg_hdb_resale_transactions.sql)
- [staging schema tests](dbt/models/staging/_staging.yml)
- [mart models](dbt/models/mart/)
- [ingestion script](ingestion/load_to_bq.py)
- [GCP setup script](infra/setup_gcp.sh)
- [parse_remaining_lease macro](dbt/macros/parse_remaining_lease.sql)
