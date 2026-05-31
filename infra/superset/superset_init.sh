#!/usr/bin/env bash
# superset_init.sh
# Container entrypoint:
#   1. Run DB migrations (idempotent)
#   2. Create admin user if absent
#   3. Init Superset roles/permissions
#   4. Import dashboard YAML definitions
#   5. Start Gunicorn
set -euo pipefail

echo "[superset_init] Running database migrations..."
superset db upgrade

echo "[superset_init] Creating admin user (no-op if already exists)..."
superset fab create-admin \
  --username  "${SUPERSET_ADMIN_USERNAME:-admin}" \
  --firstname "Admin" \
  --lastname  "User" \
  --email     "${SUPERSET_ADMIN_EMAIL:-admin@hdb-cash.local}" \
  --password  "${SUPERSET_ADMIN_PASSWORD:-changeme}" 2>&1 || true

echo "[superset_init] Initialising roles and permissions..."
superset init

echo "[superset_init] Starting Gunicorn on port ${PORT:-8080}..."
gunicorn \
  --bind "0.0.0.0:${PORT:-8080}" \
  --workers "${SUPERSET_WORKERS:-4}" \
  --worker-class gthread \
  --threads "${SUPERSET_THREADS:-20}" \
  --timeout 120 \
  --limit-request-line 0 \
  --limit-request-field_size 0 \
  --access-logfile - \
  --error-logfile - \
  "superset.app:create_app()" &
GUNICORN_PID=$!

# Wait for Superset to accept requests (v1 YAML ZIP import requires REST API)
echo "[superset_init] Waiting for Superset to be ready..."
PORT_NUM="${PORT:-8080}"
for i in $(seq 1 60); do
  if curl -sf "http://localhost:${PORT_NUM}/health" > /dev/null 2>&1; then
    echo "[superset_init] Superset is ready (attempt ${i})."
    break
  fi
  sleep 2
done

echo "[superset_init] Importing dashboard definitions via REST API..."
if [ -f "/app/superset_defs/import.sh" ]; then
  bash /app/superset_defs/import.sh \
    "http://localhost:${PORT_NUM}" \
    "${SUPERSET_ADMIN_USERNAME:-admin}" \
    "${SUPERSET_ADMIN_PASSWORD:-changeme}" \
    && echo "[superset_init] Dashboard import complete." \
    || echo "[superset_init] WARNING: dashboard import failed — check logs above."
fi

# Keep container alive — gunicorn is PID of foreground child
wait "${GUNICORN_PID}"
