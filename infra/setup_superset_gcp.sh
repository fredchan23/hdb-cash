#!/usr/bin/env bash
# setup_superset_gcp.sh
# Provisions GCP resources required to run Apache Superset on Cloud Run.
# Prerequisites: gcloud, gcloud auth application-default login, billing enabled.
# Run once per environment (re-run is safe — checks before creating).
set -euo pipefail

PROJECT_ID="hdb-cash"
REGION="asia-southeast1"
SA_NAME="superset-runner"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
CLOUDSQL_INSTANCE="hdb-cash-superset-db"
CLOUDSQL_DB="superset"
CLOUDSQL_USER="superset"
AR_REPO="superset"
CLOUD_RUN_SERVICE="hdb-cash-superset"

echo "=== Setting up Superset GCP resources for project: ${PROJECT_ID} ==="
gcloud config set project "${PROJECT_ID}"

# -------------------------------------------------------------------
# Enable required APIs
# -------------------------------------------------------------------
echo "--- Enabling APIs ---"
gcloud services enable \
  run.googleapis.com \
  sqladmin.googleapis.com \
  secretmanager.googleapis.com \
  artifactregistry.googleapis.com \
  --project="${PROJECT_ID}"

# -------------------------------------------------------------------
# Cloud SQL — PostgreSQL 15 metadata store
# -------------------------------------------------------------------
echo "--- Cloud SQL ---"
if gcloud sql instances describe "${CLOUDSQL_INSTANCE}" --project="${PROJECT_ID}" &>/dev/null; then
  echo "  [exists] Cloud SQL instance: ${CLOUDSQL_INSTANCE}"
else
  gcloud sql instances create "${CLOUDSQL_INSTANCE}" \
    --project="${PROJECT_ID}" \
    --database-version=POSTGRES_15 \
    --tier=db-f1-micro \
    --region="${REGION}" \
    --storage-type=SSD \
    --storage-size=10GB \
    --backup-start-time=03:00 \
    --assign-ip \
    --connector-enforcement=REQUIRED
  echo "  [created] Cloud SQL instance: ${CLOUDSQL_INSTANCE}"
fi

INSTANCE_CONNECTION_NAME="${PROJECT_ID}:${REGION}:${CLOUDSQL_INSTANCE}"

if gcloud sql databases describe "${CLOUDSQL_DB}" \
     --instance="${CLOUDSQL_INSTANCE}" --project="${PROJECT_ID}" &>/dev/null; then
  echo "  [exists] Cloud SQL database: ${CLOUDSQL_DB}"
else
  gcloud sql databases create "${CLOUDSQL_DB}" \
    --instance="${CLOUDSQL_INSTANCE}" --project="${PROJECT_ID}"
  echo "  [created] Cloud SQL database: ${CLOUDSQL_DB}"
fi

# Generate a random password and store it (only on first creation)
if ! gcloud secrets describe superset-db-password \
       --project="${PROJECT_ID}" &>/dev/null; then
  DB_PASSWORD=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
  gcloud sql users create "${CLOUDSQL_USER}" \
    --instance="${CLOUDSQL_INSTANCE}" \
    --password="${DB_PASSWORD}" \
    --project="${PROJECT_ID}"
  echo "${DB_PASSWORD}" | \
    gcloud secrets create superset-db-password \
      --data-file=- --project="${PROJECT_ID}"
  echo "  [created] Cloud SQL user + secret: superset-db-password"
else
  echo "  [exists] secret: superset-db-password"
fi

# -------------------------------------------------------------------
# Secret Manager — Superset secrets
# -------------------------------------------------------------------
echo "--- Secret Manager ---"

# superset-secret-key — Flask/WTF secret key
if ! gcloud secrets describe superset-secret-key \
       --project="${PROJECT_ID}" &>/dev/null; then
  python3 -c "import secrets; print(secrets.token_hex(64))" | \
    gcloud secrets create superset-secret-key \
      --data-file=- --project="${PROJECT_ID}"
  echo "  [created] secret: superset-secret-key"
else
  echo "  [exists]  secret: superset-secret-key"
fi

# google-oauth-client-id + google-oauth-client-secret
# Must be created manually in Google Cloud Console → APIs & Services → Credentials
# Then populated here with: gcloud secrets versions add google-oauth-client-id --data-file=-
for secret in google-oauth-client-id google-oauth-client-secret superset-admin-password; do
  if ! gcloud secrets describe "${secret}" \
         --project="${PROJECT_ID}" &>/dev/null; then
    echo "PLACEHOLDER" | \
      gcloud secrets create "${secret}" \
        --data-file=- --project="${PROJECT_ID}"
    echo "  [created] secret: ${secret}  ← UPDATE with real value before first deploy"
  else
    echo "  [exists]  secret: ${secret}"
  fi
done

# -------------------------------------------------------------------
# Service Account
# -------------------------------------------------------------------
echo "--- Service Account ---"
if gcloud iam service-accounts describe "${SA_EMAIL}" \
     --project="${PROJECT_ID}" &>/dev/null; then
  echo "  [exists] SA: ${SA_EMAIL}"
else
  gcloud iam service-accounts create "${SA_NAME}" \
    --project="${PROJECT_ID}" \
    --display-name="Superset Cloud Run SA"
  echo "  [created] SA: ${SA_EMAIL}"
fi

for role in \
  roles/bigquery.dataViewer \
  roles/bigquery.jobUser \
  roles/secretmanager.secretAccessor \
  roles/cloudsql.client; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="${role}" \
    --condition=None
done
echo "  [bound] IAM roles → ${SA_EMAIL}"

# -------------------------------------------------------------------
# Artifact Registry — Docker repository
# -------------------------------------------------------------------
echo "--- Artifact Registry ---"
if gcloud artifacts repositories describe "${AR_REPO}" \
     --project="${PROJECT_ID}" \
     --location="${REGION}" &>/dev/null; then
  echo "  [exists] Artifact Registry repo: ${AR_REPO}"
else
  gcloud artifacts repositories create "${AR_REPO}" \
    --project="${PROJECT_ID}" \
    --repository-format=docker \
    --location="${REGION}" \
    --description="Apache Superset images"
  echo "  [created] Artifact Registry repo: ${AR_REPO}"
fi

AR_HOST="${REGION}-docker.pkg.dev"
AR_FULL="${AR_HOST}/${PROJECT_ID}/${AR_REPO}"
gcloud auth configure-docker "${AR_HOST}" --quiet

# -------------------------------------------------------------------
# Cloud Run service (initial placeholder deploy)
# -------------------------------------------------------------------
echo "--- Cloud Run service ---"
if gcloud run services describe "${CLOUD_RUN_SERVICE}" \
     --project="${PROJECT_ID}" \
     --region="${REGION}" &>/dev/null; then
  echo "  [exists] Cloud Run service: ${CLOUD_RUN_SERVICE} — run infra/deploy_superset.sh to update"
else
  # Deploy a placeholder; the real image is pushed by infra/deploy_superset.sh
  gcloud run deploy "${CLOUD_RUN_SERVICE}" \
    --project="${PROJECT_ID}" \
    --region="${REGION}" \
    --image="us-docker.pkg.dev/cloudrun/container/hello" \
    --service-account="${SA_EMAIL}" \
    --no-allow-unauthenticated \
    --min-instances=0 \
    --max-instances=4 \
    --cpu=2 \
    --memory=2Gi
  echo "  [created] Cloud Run service: ${CLOUD_RUN_SERVICE} (placeholder image)"
fi

# -------------------------------------------------------------------
# Workload Identity Federation binding for GitHub Actions
# (reuses pool/provider created by infra/setup_gcp.sh)
# -------------------------------------------------------------------
echo "--- WIF binding for Superset SA ---"
PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")
WIF_POOL="github-actions-pool"
GITHUB_REPO="fredchan23/hdb-cash"
WIF_MEMBER="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL}/attribute.repository/${GITHUB_REPO}"

gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
  --project="${PROJECT_ID}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="${WIF_MEMBER}"
echo "  [bound] WIF → ${SA_EMAIL}"

# Grant GitHub Actions SA the Artifact Registry writer role
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="${WIF_MEMBER}" \
  --role="roles/artifactregistry.writer" \
  --condition=None

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="${WIF_MEMBER}" \
  --role="roles/run.developer" \
  --condition=None

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------
echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Update OAuth secrets (replace PLACEHOLDER values):"
echo "       echo 'YOUR_CLIENT_ID'     | gcloud secrets versions add google-oauth-client-id     --data-file=- --project=${PROJECT_ID}"
echo "       echo 'YOUR_CLIENT_SECRET' | gcloud secrets versions add google-oauth-client-secret  --data-file=- --project=${PROJECT_ID}"
echo "       echo 'YOUR_ADMIN_PASS'    | gcloud secrets versions add superset-admin-password      --data-file=- --project=${PROJECT_ID}"
echo ""
echo "  2. In Google Cloud Console → APIs & Services → Credentials → your OAuth 2.0 Client:"
echo "       Add Authorised Redirect URI:  https://<cloud-run-url>/oauth-authorized/google"
echo "       (URL is printed after running infra/deploy_superset.sh)"
echo ""
echo "  3. Build and deploy Superset:"
echo "       bash infra/deploy_superset.sh"
echo ""
echo "  Instance connection name: ${INSTANCE_CONNECTION_NAME}"
echo "  Artifact Registry image:  ${AR_FULL}/superset:<tag>"
