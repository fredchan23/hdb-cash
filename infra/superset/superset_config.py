"""
superset_config.py — Apache Superset runtime configuration for hdb-cash.
Loaded from /app/pythonpath/ by the Superset Flask factory.
All sensitive values are injected via environment variables (Secret Manager on GCP).
"""
import os
from flask_appbuilder.security.manager import AUTH_OAUTH, AUTH_DB

# ---------------------------------------------------------------------------
# Core
# ---------------------------------------------------------------------------
SECRET_KEY = os.environ["SUPERSET_SECRET_KEY"]

# PostgreSQL via Cloud SQL Unix socket on Cloud Run, plain URL for local dev
SQLALCHEMY_DATABASE_URI = os.environ["SUPERSET_DATABASE_URL"]

# Sit behind the Cloud Run ingress / load balancer
ENABLE_PROXY_FIX = True
PROXY_FIX_CONFIG = {"x_for": 1, "x_proto": 1, "x_host": 1, "x_port": 1, "x_prefix": 1}

# ---------------------------------------------------------------------------
# Cache — SimpleCache for MVP; swap for Redis (Cloud Memorystore) later
# ---------------------------------------------------------------------------
CACHE_CONFIG = {
    "CACHE_TYPE": "SimpleCache",
    "CACHE_DEFAULT_TIMEOUT": 300,
}
DATA_CACHE_CONFIG = CACHE_CONFIG
EXPLORE_FORM_DATA_CACHE_CONFIG = CACHE_CONFIG

# ---------------------------------------------------------------------------
# Authentication — Google OAuth SSO when client ID is present, DB auth locally
# ---------------------------------------------------------------------------
_GOOGLE_CLIENT_ID = os.environ.get("GOOGLE_CLIENT_ID", "")

if _GOOGLE_CLIENT_ID:
    AUTH_TYPE = AUTH_OAUTH

    OAUTH_PROVIDERS = [
        {
            "name": "google",
            "token_key": "access_token",
            "icon": "fa-google",
            "remote_app": {
                "client_id": _GOOGLE_CLIENT_ID,
                "client_secret": os.environ.get("GOOGLE_CLIENT_SECRET", ""),
                "server_metadata_url": (
                    "https://accounts.google.com/.well-known/openid-configuration"
                ),
                "api_base_url": "https://www.googleapis.com/oauth2/v2/",
                "client_kwargs": {
                    "scope": "openid email profile",
                },
            },
        }
    ]

    # Auto-register first-time Google OAuth users; assign the Gamma (viewer) role.
    AUTH_USER_REGISTRATION = True
    AUTH_USER_REGISTRATION_ROLE = "Gamma"
else:
    # Local dev — no OAuth client configured; use username/password form
    AUTH_TYPE = AUTH_DB

# ---------------------------------------------------------------------------
# Security
# ---------------------------------------------------------------------------
WTF_CSRF_ENABLED = True
WTF_CSRF_TIME_LIMIT = 60 * 60 * 24 * 7  # 1 week
# Allow CSRF tokens over plain HTTP (needed for local dev and internal curl calls)
WTF_CSRF_SSL_STRICT = False

SESSION_COOKIE_HTTPONLY = True
SESSION_COOKIE_SAMESITE = "Lax"
SESSION_COOKIE_SECURE = os.environ.get("SESSION_COOKIE_SECURE", "true").lower() == "true"

# Prevent accidental exposure of raw BigQuery/CloudSQL credentials in UI
PREVENT_UNSAFE_DB_CONNECTIONS = True

# Allow BigQuery and Cloud SQL origins
SQLALCHEMY_CUSTOM_PASSWORD_STORE = {}  # no extra password store needed with ADC

# ---------------------------------------------------------------------------
# Feature flags
# ---------------------------------------------------------------------------
FEATURE_FLAGS = {
    "ENABLE_TEMPLATE_PROCESSING": False,
    "DASHBOARD_NATIVE_FILTERS": True,
    "ALERT_REPORTS": False,
}

# ---------------------------------------------------------------------------
# BigQuery ADC patch
# Superset's BigQuery engine spec unconditionally calls
# service_account.Credentials.from_service_account_info() even when no SA key
# is configured (ADC / user-credential auth). Patch _get_client to fall back to
# google.auth.default() so database import succeeds without a SA key file.
# The patch is applied via FLASK_APP_MUTATOR which runs after the app is created.
# ---------------------------------------------------------------------------
def _apply_bigquery_adc_patch(app) -> None:
    """Called by FLASK_APP_MUTATOR after the Flask app is fully initialised."""
    try:
        from superset.db_engine_specs.bigquery import BigQueryEngineSpec  # type: ignore[import]
        import google.auth
        from google.cloud import bigquery as _bq

        @classmethod  # type: ignore[misc]
        def _get_client_adc(cls, engine):  # type: ignore[override]
            if engine.dialect.credentials_info:
                from google.oauth2 import service_account as _sa
                creds = _sa.Credentials.from_service_account_info(
                    engine.dialect.credentials_info
                )
                project = engine.dialect.credentials_info.get("project_id")
            else:
                creds, project = google.auth.default(
                    scopes=["https://www.googleapis.com/auth/bigquery"]
                )
            # Fall back to the project encoded in the SQLAlchemy URI (bigquery://PROJECT)
            if not project:
                project = engine.url.host or engine.url.database
            return _bq.Client(credentials=creds, project=project)

        BigQueryEngineSpec._get_client = _get_client_adc
        app.logger.info("BigQuery ADC patch applied to _get_client")
    except Exception as exc:  # pragma: no cover
        app.logger.warning("BigQuery ADC patch skipped: %s", exc)


FLASK_APP_MUTATOR = _apply_bigquery_adc_patch

# ---------------------------------------------------------------------------
# Miscellaneous
# ---------------------------------------------------------------------------
ROW_LIMIT = 50_000
VIZ_ROW_LIMIT = 10_000

# Allow embedding dashboards (read-only iframes) if needed later
GUEST_ROLE_NAME = "Public"
GUEST_TOKEN_JWT_EXP_SECONDS = 3600
