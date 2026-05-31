# ADR-0001: Apache Superset Deployment for HDB Resale Analysis Dashboard

**Date:** 2026-05-31  
**Status:** Accepted  
**Context:** Migrating the BI dashboard from Looker Studio to Apache Superset to enable CLI-driven chart creation and self-hosted deployment.

---

## Decision

Deploy Apache Superset 4.1.4 as the BI layer, using:
- Docker (local dev) and Cloud Run (production)
- Cloud SQL PostgreSQL 15 as the Superset metadata database
- BigQuery as the data source via ADC (Application Default Credentials)
- A v1 YAML ZIP bundle imported at startup via the REST API

---

## Troubleshooting Log

All issues encountered and resolved during initial deployment are documented here as a reference for future maintainers.

---

### Issue 1: `apache/superset:4.1.0` image not found on Docker Hub

**Symptom:** `docker pull apache/superset:4.1.0` failed; image did not exist.  
**Root cause:** The lowest published release in the 4.x line was 4.1.3; 4.1.0 was never pushed.  
**Fix:** Changed `FROM apache/superset:4.1.4` (latest stable at the time).

---

### Issue 2: `numpy.dtype size changed` binary incompatibility

**Symptom:** Container crashed on startup with:
```
ValueError: numpy.dtype size changed, may indicate binary incompatibility.
Expected 96 from C header, got 88 from PyObject
```
**Root cause:** `sqlalchemy-bigquery` pip-installed `pyarrow` which upgraded `numpy` to 2.x, but the `pandas` in the base image was compiled against `numpy` 1.x.  
**Fix:** Pin `numpy<2` in the `pip install` layer of the Dockerfile:
```dockerfile
RUN pip install --no-cache-dir "numpy<2" sqlalchemy-bigquery pyarrow db-dtypes \
    google-auth google-auth-httplib2 pg8000 authlib
```

---

### Issue 3: `No module named 'authlib'`

**Symptom:** Superset refused to start; traceback showed missing `authlib`.  
**Root cause:** Flask-AppBuilder's OAuth provider requires `authlib`, which is not included in the slim base image.  
**Fix:** Added `authlib` to the `pip install` list in Dockerfile.

---

### Issue 4: Cloud Run returned HTTP 403 Forbidden to browsers

**Symptom:** All requests to the Cloud Run URL returned 403 before reaching Superset.  
**Root cause:** Service was deployed with `--no-allow-unauthenticated`; Cloud Run's IAM layer rejected all unauthenticated requests.  
**Fix:** Redeployed with `--allow-unauthenticated`. Superset handles its own application-level authentication.

---

### Issue 5: Google OAuth `invalid_client` error

**Symptom:** Clicking "Sign in with Google" on the Cloud Run instance returned `invalid_client`.  
**Root cause:** The three GCP secrets (`google-oauth-client-id`, `google-oauth-client-secret`, `superset-admin-password`) still contained placeholder values; no OAuth 2.0 client had been created in Cloud Console.  
**Fix (pending):** Create an OAuth 2.0 Web Application client in Cloud Console → APIs & Services → Credentials. Add the redirect URI `https://<cloud-run-url>/oauth-authorized/google`. Then populate the secrets:
```bash
echo -n 'YOUR_CLIENT_ID' | gcloud secrets versions add google-oauth-client-id --data-file=- --project=hdb-cash
echo -n 'YOUR_CLIENT_SECRET' | gcloud secrets versions add google-oauth-client-secret --data-file=- --project=hdb-cash
echo -n 'StrongPassword' | gcloud secrets versions add superset-admin-password --data-file=- --project=hdb-cash
```

---

### Issue 6: Dashboard import 404 — `zip: command not found`

**Symptom:** `superset_init.sh` failed with `zip: command not found`; no bundle was created.  
**Root cause:** The `apache/superset:4.1.4` base image does not include `zip` or `jq`.  
**Fix:** Added to Dockerfile:
```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends zip jq \
    && rm -rf /var/lib/apt/lists/*
```

---

### Issue 7: Dashboard import used legacy v0 JSON importer

**Symptom:** Logs showed `superset import-dashboards` being called; it rejected YAML with "Invalid JSON file".  
**Root cause:** The `superset import-dashboards` CLI command uses the v0 importer which only handles legacy JSON exports.  
**Fix:** Rewrote `superset_init.sh` to start gunicorn in the background, wait for `/health` to return 200, then call `import.sh` which uses the REST API endpoint `POST /api/v1/dashboard/import/` (the v1 YAML/ZIP importer).

---

### Issue 8: Local login blocked — AUTH_OAUTH active without client credentials

**Symptom:** Visiting `http://localhost:8088` redirected immediately to Google OAuth; no username/password form was available.  
**Root cause:** `AUTH_TYPE = AUTH_OAUTH` was set unconditionally in `superset_config.py`.  
**Fix:** Added a conditional in `superset_config.py`:
```python
_GOOGLE_CLIENT_ID = os.environ.get("GOOGLE_CLIENT_ID", "")
if _GOOGLE_CLIENT_ID:
    AUTH_TYPE = AUTH_OAUTH
    # ... OAUTH_PROVIDERS block ...
else:
    AUTH_TYPE = AUTH_DB  # local dev — username/password form
```
Local dev sets `GOOGLE_CLIENT_ID: ""` in `docker-compose.dev.yml`.

---

### Issue 9: Import returned HTTP 302 (no session cookie)

**Symptom:** `POST /api/v1/dashboard/import/` returned 302 (redirect to login).  
**Root cause:** `curl` did not carry the session cookie from the login call to subsequent API calls. Without the session cookie, the CSRF check fails and Superset redirects to the login page.  
**Fix:** Added a cookie jar to `import.sh`:
```bash
COOKIE_JAR=$(mktemp)
trap 'rm -f "${COOKIE_JAR}"' EXIT
# Use -c / -b on every curl call to write/read the jar
```

---

### Issue 10: Import returned HTTP 500 — three YAML schema validation failures

**Symptom:** `POST /api/v1/dashboard/import/` returned 500. Superset logs showed Marshmallow validation errors.  
**Root cause:** Three distinct schema mismatches between the generated YAML and the Superset 4.x v1 schema:

| File | Field | Problem | Fix |
|---|---|---|---|
| `databases/BigQuery_hdb_cash.yaml` | `extra` | Was a JSON string; `ImportV1DatabaseSchema` expects a nested dict | Convert to YAML dict; remove unknown fields `schema_options` and `allow_multi_schema_metadata_fetch` |
| `charts/*.yaml` (5 files) | `params` | Was a JSON string; `ImportV1ChartSchema` expects a nested dict | Parse with `json.loads()` and rewrite as YAML dict |
| `charts/*.yaml` (5 files) | `query_context` | Converted to `{}` dict; schema expects a string | Revert to `""` (empty string) |
| `datasets/*.yaml` (2 files) | `is_sqllab_view` | Unknown field in Superset 4.x schema | Remove the field entirely |

**Validated with:**
```python
# Inside container app context
from superset.charts.schemas import ImportV1ChartSchema
schema.load(yaml.safe_load(open(path).read()))  # must not raise
```

---

### Issue 11: v1 importer raised `IncorrectVersionError` → fell back to v0

**Symptom:** Even after YAML fixes, logs showed the v0 importer running and failing.  
**Root cause:** `get_contents_from_bundle()` calls `remove_root()` which strips the **first path component** of every ZIP entry. When files were stored flat (`databases/BigQuery.yaml`, `metadata.yaml`), `metadata.yaml` became `.` after stripping — causing `IncorrectVersionError("Missing metadata.yaml")` and silent fallback to v0.  
**Fix:** Wrap all files under a single root directory in the ZIP:
```bash
mkdir -p /tmp/hdb_superset_root
cp -r "${SCRIPT_DIR}/databases" "${SCRIPT_DIR}/charts" \
       "${SCRIPT_DIR}/datasets" "${SCRIPT_DIR}/dashboards" \
       "${SCRIPT_DIR}/metadata.yaml" /tmp/hdb_superset_root/
(cd /tmp && zip -r "${BUNDLE}" hdb_superset_root/)
```
After `remove_root()`, entries become `databases/BigQuery.yaml`, `metadata.yaml`, etc. — exactly what v1 expects.

---

### Issue 12: Import HTTP 500 — `_get_client` crashes when no SA key is configured

**Symptom:** After ZIP structure fix, v1 importer ran but crashed in `import_database` → `add_permissions` → `get_all_catalog_names`. Traceback:
```
service_account.Credentials.from_service_account_info(None)
AttributeError: 'NoneType' object has no attribute 'keys'
```
**Root cause:** `BigQueryEngineSpec._get_client()` unconditionally calls `service_account.Credentials.from_service_account_info(engine.dialect.credentials_info)`. When no SA key is configured (ADC / user-credential auth), `credentials_info` is `None`.  
**Fix:** Monkey-patch `_get_client` via `FLASK_APP_MUTATOR` in `superset_config.py` to fall back to `google.auth.default()` and extract the project ID from the SQLAlchemy URI:
```python
def _apply_bigquery_adc_patch(app) -> None:
    from superset.db_engine_specs.bigquery import BigQueryEngineSpec
    import google.auth
    from google.cloud import bigquery as _bq

    @classmethod
    def _get_client_adc(cls, engine):
        if engine.dialect.credentials_info:
            from google.oauth2 import service_account as _sa
            creds = _sa.Credentials.from_service_account_info(engine.dialect.credentials_info)
            project = engine.dialect.credentials_info.get("project_id")
        else:
            creds, project = google.auth.default(
                scopes=["https://www.googleapis.com/auth/bigquery"]
            )
        if not project:
            project = engine.url.host or engine.url.database
        return _bq.Client(credentials=creds, project=project)

    BigQueryEngineSpec._get_client = _get_client_adc

FLASK_APP_MUTATOR = _apply_bigquery_adc_patch
```
**Note:** `FLASK_APP_MUTATOR` must be used (not a bare module-level call) because the BigQuery spec module is not importable before the Flask app context is initialised.

---

## Known Remaining Issues

### Charts: `ECHARTS_BAR` / `ECHARTS_SC` visualization type not supported; `Error: Empty query?`

**Observed on:** `Avg Resale Price by Flat Age Bucket` (bar) and `Flat Age vs Resale Price Scatter` (scatter).  
**Symptom:** Chart editor shows "This visualization type is not supported." and "Error: Empty query?". Metrics and Columns panels show 0 items ("N ineligible items are hidden").  
**Likely cause:** The `params` dict (converted from JSON during YAML fix) may have lost required fields such as `metrics`, `groupby`, or `viz_type` that the chart editor requires to reconstruct the query. Alternatively, `viz_type` in the params does not map to a registered plugin in this Superset build.  
**To investigate in next session:**
1. Open the chart in Explore, inspect the raw `params` in the YAML file, and compare against a freshly saved chart of the same type to identify missing required fields.
2. Check whether `echarts_bar` and `echarts_timeseries_scatter` plugins are registered: `SELECT * FROM ab_permission WHERE name LIKE '%echarts%';` in SQL Lab.
3. Consider rebuilding affected chart YAMLs from scratch by creating the charts interactively in Superset and re-exporting.

---

## Final Working Architecture (Local Dev)

```
docker-compose.dev.yml
  ├── postgres:15-alpine   (Superset metadata DB on port 5432)
  └── superset-superset    (extends apache/superset:4.1.4)
        ├── gunicorn on :8080 (mapped to host :8088)
        ├── superset_config.py (AUTH_DB locally, FLASK_APP_MUTATOR BigQuery patch)
        ├── superset_init.sh  (db upgrade → create-admin → init → gunicorn bg → import)
        └── superset_defs/    (volume-mounted superset/ from host)
              ├── metadata.yaml
              ├── databases/BigQuery_hdb_cash.yaml
              ├── datasets/mart_age_price_decade_summary.yaml
              ├── datasets/mart_age_price_regression_inputs.yaml
              ├── charts/ (5 × .yaml)
              ├── dashboards/hdb_resale_analysis.yaml
              └── import.sh
```

Login: `http://localhost:8088/dashboard/hdb-resale-analysis/` — `admin` / `changeme`
