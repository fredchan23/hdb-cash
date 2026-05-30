---
name: add-mart-model
description: "Scaffold a new dbt mart model for the hdb-cash project. Use when: adding a mart model, creating a new aggregation or analysis table, adding dashboard-facing tables, following mart conventions (table materialization, no ORDER BY, INT64 decade, _mart.yml entry)."
argument-hint: "Name of the new mart model (e.g. mart_price_by_town)"
---

# add-mart-model — Scaffold a New dbt Mart Model

## When to Use
- Adding a new aggregation or analysis table to serve a dashboard or analysis
- Creating a new mart that reads from `stg_hdb_resale_transactions`

---

## Conventions (must follow)

- **Materialization**: always `table` (never incremental for marts)
- **No `ORDER BY`**: BigQuery forbids `ORDER BY` in `CREATE TABLE AS SELECT` for clustered tables
- **`transaction_decade`**: always `INT64` (e.g. `1990`, `2000`) — never a string
- **Clustering**: add `cluster_by` in config for columns used in dashboard filters
- **Text fields**: already `UPPER CASE` in staging — do not re-upper in marts
- **Source**: always `{{ ref('stg_hdb_resale_transactions') }}`, never raw or source directly
- **Schema tests**: add a `_mart.yml` entry with `not_null` on key columns and `unique` on any surrogate/PK

---

## Procedure

### Step 1 — Create the SQL model

Create `dbt/models/mart/<model_name>.sql`:

```sql
{{
  config(
    materialized = 'table',
    cluster_by   = ['<col1>', '<col2>']   -- columns used as dashboard filters
  )
}}

-- <model_name>
-- <One-line description of what this mart contains>

select
    <dimensions>,
    <aggregates>
from {{ ref('stg_hdb_resale_transactions') }}
group by <dimension_numbers>
-- NO ORDER BY
```

**Available columns in staging** (key ones):
| Column | Type | Notes |
|---|---|---|
| `transaction_id` | STRING | surrogate key |
| `transaction_month` | DATE | monthly partition |
| `transaction_year` | INT64 | |
| `transaction_decade` | INT64 | e.g. 1990, 2000 |
| `town` | STRING | UPPER CASE |
| `flat_type` | STRING | UPPER CASE |
| `flat_model` | STRING | Title Case |
| `floor_area_sqm` | FLOAT64 | |
| `storey_low` | INT64 | |
| `storey_high` | INT64 | |
| `storey_mid` | FLOAT64 | computed midpoint |
| `lease_commence_date` | INT64 | year |
| `flat_age_years` | INT64 | transaction_year - lease_commence_date |
| `flat_age_bucket` | STRING | from `flat_age_bucket()` macro |
| `remaining_lease_months` | INT64 | from `parse_remaining_lease()` macro |
| `resale_price` | FLOAT64 | |
| `log_resale_price` | FLOAT64 | natural log |
| `price_per_sqm` | FLOAT64 | |

### Step 2 — Add schema tests to `_mart.yml`

Open `dbt/models/mart/_mart.yml` and add a new entry under `models:`:

```yaml
  - name: <model_name>
    description: >
      <Description of what this mart contains and who consumes it.>
    columns:
      - name: <primary_key_column>
        tests:
          - unique
          - not_null
      - name: <key_metric>
        tests: [not_null]
```

For decade columns use `dbt_utils.accepted_range` (not `accepted_values`):
```yaml
      - name: transaction_decade
        tests:
          - dbt_utils.accepted_range:
              min_value: 1990
              max_value: 2029
```

### Step 3 — Run and test the new model

```bash
cd dbt
dbt run --select <model_name>
dbt test --select <model_name>
```

### Step 4 — Verify in BigQuery

```bash
bq query --use_legacy_sql=false --project_id=hdb-cash \
  'SELECT COUNT(*) as rows FROM staging_dev_mart.<model_name>'
```

---

## Example — mart_price_by_town

```sql
{{
  config(
    materialized = 'table',
    cluster_by   = ['town', 'transaction_decade']
  )
}}

select
    town,
    transaction_decade,
    flat_type,
    count(*)                                                   as transaction_count,
    round(avg(resale_price), 0)                                as avg_resale_price,
    round(approx_quantiles(resale_price, 100)[offset(50)], 0) as median_resale_price,
    round(avg(price_per_sqm), 0)                               as avg_price_per_sqm
from {{ ref('stg_hdb_resale_transactions') }}
group by 1, 2, 3
```

---

## Key References
- [mart_age_price_decade_summary.sql](../../dbt/models/mart/mart_age_price_decade_summary.sql) — reference implementation
- [_mart.yml](../../dbt/models/mart/_mart.yml) — schema tests to extend
- [stg_hdb_resale_transactions.sql](../../dbt/models/staging/stg_hdb_resale_transactions.sql) — all available columns
- [flat_age_bucket.sql](../../dbt/macros/flat_age_bucket.sql) — age bucketing macro
