# Apache Superset Dashboard — Setup Guide

This guide covers running Apache Superset against the `hdb-cash` BigQuery marts.
Charts and dashboards are defined as YAML in `superset/` and loaded via the CLI —
no manual clicking required. Intended for onboarding new team members.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Google account | Must have access to the `hdb-cash` GCP project |
| dbt marts built | Run `dbt run` in `dbt/` before connecting — see [dbt-hdb skill](../.github/skills/dbt-hdb/SKILL.md) |
| BigQuery dataset | `staging_dev_mart` in project `hdb-cash`, region `asia-southeast1` |

---

## Available mart tables

### `mart_age_price_decade_summary`
Pre-aggregated summary — **one row per (decade × flat_age_bucket × flat_type)**.
Use this for most dashboard charts; it is fast and small.

| Column | Type | Description |
|---|---|---|
| `transaction_decade` | INT64 | e.g. `1990`, `2000`, `2010`, `2020` |
| `flat_age_bucket` | STRING | Age bracket, e.g. `"0-10 years"` |
| `flat_type` | STRING | e.g. `"3 ROOM"`, `"4 ROOM"` |
| `transaction_count` | INT64 | Number of transactions in group |
| `median_resale_price` | FLOAT64 | Median resale price (SGD) |
| `avg_resale_price` | FLOAT64 | Mean resale price (SGD) |
| `min_resale_price` | FLOAT64 | Minimum resale price (SGD) |
| `max_resale_price` | FLOAT64 | Maximum resale price (SGD) |
| `avg_price_per_sqm` | FLOAT64 | Mean price per sqm (size-normalised) |
| `median_price_per_sqm` | FLOAT64 | Median price per sqm |
| `avg_floor_area_sqm` | FLOAT64 | Mean floor area |
| `avg_flat_age_years` | FLOAT64 | Mean flat age in the group |
| `avg_remaining_lease_months` | FLOAT64 | Mean remaining lease (months) |

### `mart_age_price_regression_inputs`
Transaction-level table with engineered features. Use for scatter plots and
detailed drill-downs. Larger — filter by decade or town to keep queries fast.

| Column | Type | Description |
|---|---|---|
| `transaction_id` | STRING | Surrogate key (unique) |
| `transaction_month` | DATE | Monthly partition key |
| `transaction_decade` | INT64 | Decade grouping |
| `town` | STRING | HDB town (upper case) |
| `flat_type` | STRING | Flat type (upper case) |
| `flat_age_years` | FLOAT64 | Age of flat at transaction date |
| `flat_age_years_sq` | FLOAT64 | Squared age (for quadratic OLS term) |
| `flat_age_bucket` | STRING | Age bracket label |
| `storey_midpoint` | FLOAT64 | `(storey_low + storey_high) / 2` |
| `remaining_lease_months` | FLOAT64 | Remaining lease in months |
| `resale_price` | FLOAT64 | Transaction price (SGD) |
| `log_resale_price` | FLOAT64 | Natural log of price (for log-linear models) |
| `resale_price_per_sqm` | FLOAT64 | Price normalised by floor area |

---

## Step 1 — First-time GCP setup

Run once to provision Cloud SQL, Artifact Registry, Secret Manager secrets, and
the Cloud Run service:

```bash
bash infra/setup_superset_gcp.sh
```

Then populate the three OAuth/admin secrets with real values (see the script
output for exact commands). The script creates placeholder values for:
- `google-oauth-client-id` — from Google Cloud Console OAuth 2.0 client
- `google-oauth-client-secret` — same
- `superset-admin-password` — choose a strong password for the built-in admin

---

## Step 2 — Local development

**Prerequisites:**
- Docker Desktop (or Docker Engine) running
- Copy your ADC credentials: `cp ~/.config/gcloud/application_default_credentials.json .adc.json`

```bash
# Start Superset + PostgreSQL metadata DB
docker compose -f infra/superset/docker-compose.dev.yml up -d

# Superset is available at http://localhost:8088
# Login: admin / changeme
```

Charts and dashboards are automatically imported on container startup from `superset/`.
To re-import after editing YAML definitions:

```bash
# Option A — restart the container (re-runs import on startup)
docker compose -f infra/superset/docker-compose.dev.yml restart superset

# Option B — import directly against the running container via REST API
bash superset/import.sh
```

---

## Step 3 — Deploy to Cloud Run

```bash
# Build, push, and deploy (uses current ADC for gcloud)
bash infra/deploy_superset.sh
```

After the first deploy, the script prints the Cloud Run URL. Add that URL's
OAuth redirect to your Google Cloud Console OAuth 2.0 client:

```
https://<cloud-run-url>/oauth-authorized/google
```

Then re-deploy once to pick up the correct redirect URI in the config.

---

## Step 4 — Dashboard overview

The dashboard **HDB Resale Analysis** (`/dashboard/hdb-resale-analysis`) contains
five charts loaded automatically on startup:

| Chart | Viz type | Dataset |
|---|---|---|
| Total Transaction Volume | Big number | `mart_age_price_decade_summary` |
| Median Resale Price by Decade | Line (echarts) | `mart_age_price_decade_summary` |
| Avg Resale Price by Flat Age Bucket | Bar (echarts) | `mart_age_price_decade_summary` |
| Median Price per sqm Heatmap | Pivot table | `mart_age_price_decade_summary` |
| Flat Age vs Resale Price Scatter | Scatter (echarts) | `mart_age_price_regression_inputs` |

Two native filters sit at the top: **Flat Type** and **Decade**, applying to all
compatible charts simultaneously.

---

## Step 5 — Modifying charts

**Recommended workflow** (chart as code):

1. Edit the relevant YAML file in `superset/charts/` or `superset/dashboards/`.
2. Re-import: `bash superset/import.sh` (local) or push to `main` (CI/CD auto-deploys).

**Alternative — UI first, then export:**

1. Edit the chart in the Superset Explore view.
2. Export: *Dashboards → ··· → Export* (downloads a ZIP).
3. Unzip and replace the YAML files in `superset/`.
4. Commit the updated YAML files.

---

## Step 6 — CI/CD

`.github/workflows/superset-deploy.yml` triggers automatically on any push to
`main` that touches `infra/superset/**` or `superset/**`. It uses the same WIF
service account as the dbt workflow (`WIF_PROVIDER` / `WIF_SERVICE_ACCOUNT`
secrets). No additional GitHub secrets are needed.

---

## Troubleshooting

| Issue | Fix |
|---|---|
| `staging_dev_mart` not visible in Explore | Confirm the Cloud Run SA `superset-runner@hdb-cash.iam.gserviceaccount.com` has `roles/bigquery.dataViewer` |
| Charts show no data | Run `dbt run` (or `dbt run --full-refresh`) to materialise the marts |
| Import fails with HTTP 400 | Check that `metadata.yaml` is present in `superset/` and the `version: 1.0.0` field is set in all YAML files |
| Scatter plot times out | The default filter pre-selects `transaction_decade = 2020`; remove it only after adding a native filter to restrict rows |
| Google OAuth redirect error | Ensure the Cloud Run URL's `/oauth-authorized/google` path is listed as an authorised redirect URI in your Google OAuth 2.0 client |
| Cold start takes > 60s | Set `min-instances=1` in `infra/deploy_superset.sh` and re-deploy (~$15/month fixed cost) |
| `SESSION_COOKIE_SECURE` errors on `localhost` | The dev compose sets `SESSION_COOKIE_SECURE=false`; do not set it to `true` for local HTTP |

---

## Related resources

- [AGENTS.md](../AGENTS.md) — project overview and BigQuery layout
- [dbt-hdb skill](../.github/skills/dbt-hdb/SKILL.md) — how to run and validate the pipeline
- [mart models](../dbt/models/mart/) — SQL source for both mart tables
- [superset/ folder](../superset/) — chart and dashboard YAML definitions
- [Apache Superset docs](https://superset.apache.org/docs/intro/)
