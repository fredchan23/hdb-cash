# Looker Studio Dashboard — Setup Guide

This guide walks through connecting Looker Studio to the `hdb-cash` BigQuery marts
and building the core analytics dashboard. Intended for onboarding new team members.

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

## Step 1 — Open Looker Studio

1. Go to [lookerstudio.google.com](https://lookerstudio.google.com).
2. Click **Create → Report**.

---

## Step 2 — Add the summary data source

1. In the connector panel, choose **BigQuery**.
2. Authorize with the Google account that has access to `hdb-cash`.
3. Select:
   - **Project:** `hdb-cash`
   - **Dataset:** `staging_dev_mart`
   - **Table:** `mart_age_price_decade_summary`
4. Click **Add → Add to Report**.

> **Tip:** Change the `transaction_decade` field type to **Text** in the data source
> schema editor. If left as a number, Looker Studio treats it as a continuous axis
> and draws misleading interpolations between decades.

---

## Step 3 — Add the regression inputs data source (optional)

Repeat Step 2 but select `mart_age_price_regression_inputs`.
Add a **default filter** (`transaction_decade = 2020`) to limit bytes scanned on
every chart refresh.

---

## Step 4 — Build core charts

### 4a — Median price over decades (Line chart)

| Setting | Value |
|---|---|
| Data source | `mart_age_price_decade_summary` |
| Chart type | Line chart |
| Dimension | `transaction_decade` |
| Metric | `median_resale_price` |
| Breakdown dimension | `flat_type` (optional) |

### 4b — Price by flat age bucket (Bar chart)

| Setting | Value |
|---|---|
| Data source | `mart_age_price_decade_summary` |
| Chart type | Grouped bar chart |
| Dimension | `flat_age_bucket` |
| Metric | `avg_resale_price` |
| Breakdown dimension | `flat_type` |

Sort `flat_age_bucket` manually or prefix buckets with a numeric sort key so they
appear in age order (the macro already outputs them in order).

### 4c — Price per sqm heatmap (Pivot table)

| Setting | Value |
|---|---|
| Data source | `mart_age_price_decade_summary` |
| Chart type | Pivot table with heatmap |
| Row dimension | `transaction_decade` |
| Column dimension | `flat_age_bucket` |
| Metric | `median_price_per_sqm` |

### 4d — Transaction volume scorecard

| Setting | Value |
|---|---|
| Data source | `mart_age_price_decade_summary` |
| Chart type | Scorecard |
| Metric | `SUM(transaction_count)` |

### 4e — Flat age vs. price scatter plot

| Setting | Value |
|---|---|
| Data source | `mart_age_price_regression_inputs` |
| Chart type | Scatter chart |
| X-axis | `flat_age_years` |
| Y-axis | `resale_price` |
| Breakdown dimension | `flat_type` |

Apply a **report-level filter** (`transaction_decade = 2020`) to keep this chart
responsive.

---

## Step 5 — Add interactive filter controls

Add the following **Filter controls** to the report header so viewers can slice all
charts simultaneously:

| Control | Field | Type |
|---|---|---|
| Flat type | `flat_type` | Drop-down list |
| Decade | `transaction_decade` | Drop-down list |
| Town | `town` (regression source) | Drop-down list |

Set **"Apply filter to all compatible data sources"** on each control so both mart
tables respond.

---

## Step 6 — Performance tips

- **Extract data:** For charts using `mart_age_price_regression_inputs`, enable
  *Data → Extract data* caching. Looker Studio caches a snapshot so BigQuery is
  not queried on every page load. Refresh the extract after each `dbt run`.
- **Date range control:** Add a date range control bound to `transaction_month` on
  the regression inputs source to let viewers focus on specific periods.
- **Billing:** BigQuery charges per bytes scanned. The summary mart is tiny (~KB).
  The regression inputs mart is larger; always pre-filter by decade or town.

---

## Troubleshooting

| Issue | Fix |
|---|---|
| `staging_dev_mart` dataset not visible | Confirm the signed-in account has `roles/bigquery.dataViewer` on the `hdb-cash` project |
| Charts show no data | Run `dbt run` (or `dbt run --full-refresh`) to materialise the marts |
| `transaction_decade` axis shows decimal points | Change field type to **Text** in the data source schema editor |
| Scatter plot times out | Add a `transaction_decade` filter; avoid querying all 35+ years at once |
| `flat_age_bucket` sorts alphabetically | Prefix bucket labels with a number (e.g. `"1 – 0-10 yrs"`) or use a calculated field for sort order |

---

## Related resources

- [AGENTS.md](../AGENTS.md) — project overview and BigQuery layout
- [dbt-hdb skill](../.github/skills/dbt-hdb/SKILL.md) — how to run and validate the pipeline
- [mart models](../dbt/models/mart/) — SQL source for both mart tables
- [Looker Studio Help Centre](https://support.google.com/looker-studio)
