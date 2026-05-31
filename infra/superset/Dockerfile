# infra/superset/Dockerfile
# Extends the official apache/superset image with BigQuery + Cloud SQL drivers.
# Build context is the repo root so that `superset/` defs are copied in.

FROM apache/superset:4.1.4

USER root

# Install system utilities required by superset_init.sh and import.sh
RUN apt-get update && apt-get install -y --no-install-recommends zip jq \
    && rm -rf /var/lib/apt/lists/*

# Install BigQuery SQLAlchemy driver + Cloud SQL pg8000 driver
# Pin numpy<2 to avoid binary incompatibility with pandas compiled against numpy 1.x
RUN pip install --no-cache-dir \
    "numpy<2" \
    sqlalchemy-bigquery \
    pyarrow \
    db-dtypes \
    google-auth \
    google-auth-httplib2 \
    pg8000 \
    authlib

# Superset config — read from env at runtime
COPY infra/superset/superset_config.py /app/pythonpath/superset_config.py

# Dashboard definitions (databases/, datasets/, charts/, dashboards/, metadata.yaml)
COPY superset/ /app/superset_defs/

# Startup script
COPY infra/superset/superset_init.sh /app/superset_init.sh
RUN chmod +x /app/superset_init.sh

USER superset

ENTRYPOINT ["/app/superset_init.sh"]
