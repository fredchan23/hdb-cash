#!/usr/bin/env bash
# superset/import.sh
# Import Superset dashboard definitions via the REST API.
# Targets a running Superset instance (local dev or Cloud Run URL).
#
# Usage:
#   ./superset/import.sh                                     # http://localhost:8088, admin/changeme
#   ./superset/import.sh https://superset.example.com       # admin/changeme
#   ./superset/import.sh https://superset.example.com admin MyPass
#
# Prerequisites: curl, jq, zip (standard on macOS/Linux)
set -euo pipefail

SUPERSET_URL="${1:-http://localhost:8088}"
SUPERSET_USER="${2:-admin}"
SUPERSET_PASS="${3:-changeme}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE=/tmp/hdb_superset_bundle.zip
# Superset v1 importer calls remove_root() which strips the first path component
# from every ZIP entry, so all files must be nested under a single root directory.
ROOT_DIR=/tmp/hdb_superset_root

echo "=== Packing YAML bundle ==="
rm -rf "${ROOT_DIR}"
mkdir -p "${ROOT_DIR}"
cp -r "${SCRIPT_DIR}/databases" "${SCRIPT_DIR}/charts" \
       "${SCRIPT_DIR}/datasets" "${SCRIPT_DIR}/dashboards" \
       "${SCRIPT_DIR}/metadata.yaml" "${ROOT_DIR}/"
(cd /tmp && zip -r "${BUNDLE}" hdb_superset_root/ 2>/dev/null)
rm -rf "${ROOT_DIR}"
echo "  [ok] bundle written to ${BUNDLE}"

# Use a cookie jar so the session cookie from login is sent with all subsequent requests
COOKIE_JAR=$(mktemp)
trap 'rm -f "${COOKIE_JAR}"' EXIT

echo "=== Authenticating to ${SUPERSET_URL} ==="
TOKEN=$(curl -s -c "${COOKIE_JAR}" \
  -X POST "${SUPERSET_URL}/api/v1/security/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\": \"${SUPERSET_USER}\", \"password\": \"${SUPERSET_PASS}\", \"provider\": \"db\", \"refresh\": true}" \
  | jq -r '.access_token')

if [[ -z "${TOKEN}" || "${TOKEN}" == "null" ]]; then
  echo "ERROR: failed to get access token. Check Superset URL and credentials."
  exit 1
fi
echo "  [ok] access token acquired"

CSRF_TOKEN=$(curl -s -b "${COOKIE_JAR}" -c "${COOKIE_JAR}" \
  -X GET "${SUPERSET_URL}/api/v1/security/csrf_token/" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Referer: ${SUPERSET_URL}" \
  | jq -r '.result')

if [[ -z "${CSRF_TOKEN}" || "${CSRF_TOKEN}" == "null" ]]; then
  echo "ERROR: failed to get CSRF token."
  exit 1
fi
echo "  [ok] CSRF token acquired"

echo "=== Importing dashboard bundle ==="
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  -b "${COOKIE_JAR}" \
  -X POST "${SUPERSET_URL}/api/v1/dashboard/import/" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "X-CSRFToken: ${CSRF_TOKEN}" \
  -H "Referer: ${SUPERSET_URL}" \
  -F "formData=@${BUNDLE};type=application/zip" \
  -F "overwrite=true")

if [[ "${HTTP_STATUS}" == "200" ]]; then
  echo "  [ok] import succeeded (HTTP 200)"
else
  echo "ERROR: import returned HTTP ${HTTP_STATUS}."
  echo "  Tip: check Superset logs or re-run with SUPERSET_LOG_LEVEL=DEBUG"
  exit 1
fi

echo ""
echo "Done. Open ${SUPERSET_URL}/dashboard/hdb-resale-analysis/ to verify."

rm -f "${BUNDLE}"
