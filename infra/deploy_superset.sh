#!/usr/bin/env bash
# infra/deploy_superset.sh
# Build, push, and deploy the Superset Docker image to GCP Cloud Run.
# Run from the repo root.
#
# Prerequisites:
#   - gcloud auth login && gcloud auth application-default login
#   - Docker daemon running
#   - infra/setup_superset_gcp.sh completed (creates secrets, SA, Cloud SQL, AR repo)
#
# Usage:
#   bash infra/deploy_superset.sh             # builds + deploys
#   IMAGE_TAG=v1.2.3 bash infra/deploy_superset.sh   # pin a tag
set -euo pipefail

PROJECT_ID="hdb-cash"
REGION="asia-southeast1"
AR_HOST="${REGION}-docker.pkg.dev"
AR_REPO="superset"
SERVICE_NAME="hdb-cash-superset"
SA_EMAIL="superset-runner@${PROJECT_ID}.iam.gserviceaccount.com"
CLOUDSQL_INSTANCE="${PROJECT_ID}:${REGION}:hdb-cash-superset-db"
IMAGE_TAG="${IMAGE_TAG:-$(date +%Y%m%d-%H%M%S)}"
IMAGE="${AR_HOST}/${PROJECT_ID}/${AR_REPO}/superset:${IMAGE_TAG}"

echo "=== Building Superset image ==="
echo "  Image: ${IMAGE}"
docker build \
  -f infra/superset/Dockerfile \
  -t "${IMAGE}" \
  .
echo "  [ok] build complete"

echo "=== Pushing to Artifact Registry ==="
gcloud auth configure-docker "${AR_HOST}" --quiet
docker push "${IMAGE}"
echo "  [ok] push complete"

echo "=== Fetching DB password from Secret Manager ==="
DB_PASSWORD=$(gcloud secrets versions access latest \
  --secret=superset-db-password --project="${PROJECT_ID}")

# Cloud SQL Unix socket URI used by Cloud Run + Cloud SQL proxy sidecar
DB_URL="postgresql+pg8000://superset:${DB_PASSWORD}@/superset?unix_sock=/cloudsql/${CLOUDSQL_INSTANCE}/.s.PGSQL.5432"

echo "=== Deploying to Cloud Run ==="
gcloud run deploy "${SERVICE_NAME}" \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --image="${IMAGE}" \
  --service-account="${SA_EMAIL}" \
  --add-cloudsql-instances="${CLOUDSQL_INSTANCE}" \
  --set-secrets="SUPERSET_SECRET_KEY=superset-secret-key:latest,\
GOOGLE_CLIENT_ID=google-oauth-client-id:latest,\
GOOGLE_CLIENT_SECRET=google-oauth-client-secret:latest,\
SUPERSET_ADMIN_PASSWORD=superset-admin-password:latest" \
  --set-env-vars="SUPERSET_DATABASE_URL=${DB_URL},\
SUPERSET_ADMIN_USERNAME=admin,\
SUPERSET_ADMIN_EMAIL=admin@hdb-cash.local,\
SESSION_COOKIE_SECURE=true" \
  --min-instances=0 \
  --max-instances=4 \
  --cpu=2 \
  --memory=2Gi \
  --timeout=300 \
  --allow-unauthenticated

echo "  [ok] Cloud Run revision deployed"

echo "=== Service URL ==="
SERVICE_URL=$(gcloud run services describe "${SERVICE_NAME}" \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --format="value(status.url)")
echo "  URL: ${SERVICE_URL}"

echo ""
echo "Post-deploy checklist:"
echo "  1. Add this redirect URI to your Google OAuth 2.0 client:"
echo "       ${SERVICE_URL}/oauth-authorized/google"
echo "  2. Allow your account access via:"
echo "       gcloud run services add-iam-policy-binding ${SERVICE_NAME} \\"
echo "         --region=${REGION} --member=user:YOUR_EMAIL --role=roles/run.invoker"
echo "  3. Verify dashboard: ${SERVICE_URL}/dashboard/hdb-resale-analysis"
