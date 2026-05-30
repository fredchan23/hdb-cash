#!/usr/bin/env bash
# setup_gcp.sh
# Creates GCS buckets, BigQuery datasets, and service accounts for hdb-cash.
# Run once per environment (or re-run safely — checks before creating).
set -euo pipefail

PROJECT_ID="hdb-cash"
REGION="asia-southeast1"   # Singapore

echo "=== Setting up GCP resources for project: ${PROJECT_ID} ==="
gcloud config set project "${PROJECT_ID}"

# -------------------------------------------------------------------
# GCS Buckets
# -------------------------------------------------------------------
for bucket in hdb-cash-raw hdb-cash-artifacts; do
  if gsutil ls -b "gs://${bucket}" &>/dev/null; then
    echo "  [exists] gs://${bucket}"
  else
    gsutil mb -p "${PROJECT_ID}" -l "${REGION}" -b on "gs://${bucket}"
    echo "  [created] gs://${bucket}"
  fi
done

# -------------------------------------------------------------------
# BigQuery Datasets
# -------------------------------------------------------------------
for dataset in raw staging mart audit; do
  if bq ls --project_id="${PROJECT_ID}" "${dataset}" &>/dev/null; then
    echo "  [exists] BQ dataset: ${dataset}"
  else
    bq mk --project_id="${PROJECT_ID}" --location="${REGION}" --dataset "${dataset}"
    echo "  [created] BQ dataset: ${dataset}"
  fi
done

# -------------------------------------------------------------------
# Service Accounts
# -------------------------------------------------------------------
SA_TRANSFORM="dbt-transform@${PROJECT_ID}.iam.gserviceaccount.com"
SA_BI="looker-bi@${PROJECT_ID}.iam.gserviceaccount.com"

for sa_name in dbt-transform looker-bi; do
  sa="${sa_name}@${PROJECT_ID}.iam.gserviceaccount.com"
  if gcloud iam service-accounts describe "${sa}" --project="${PROJECT_ID}" &>/dev/null; then
    echo "  [exists] SA: ${sa}"
  else
    gcloud iam service-accounts create "${sa_name}" \
      --project="${PROJECT_ID}" \
      --display-name="${sa_name}"
    echo "  [created] SA: ${sa}"
  fi
done

# -------------------------------------------------------------------
# IAM bindings
# dbt-transform: BQ data editor + job user + GCS object viewer
# looker-bi:     BQ data viewer on mart dataset only
# -------------------------------------------------------------------
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SA_TRANSFORM}" \
  --role="roles/bigquery.dataEditor" --condition=None

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SA_TRANSFORM}" \
  --role="roles/bigquery.jobUser" --condition=None

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SA_TRANSFORM}" \
  --role="roles/storage.objectViewer" --condition=None

# Dataset-level IAM (bq add-iam-policy-binding) requires allowlisting.
# Grant project-level dataViewer to looker-bi instead; this is acceptable
# for a single-purpose project where mart is the only consumer-facing dataset.
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SA_BI}" \
  --role="roles/bigquery.dataViewer" --condition=None

# -------------------------------------------------------------------
# Workload Identity Federation (GitHub Actions CI/CD)
# -------------------------------------------------------------------
GITHUB_REPO="fredchan23/hdb-cash"
WIF_POOL="github-actions-pool"
WIF_PROVIDER="github-actions-provider"

PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")

if gcloud iam workload-identity-pools describe "${WIF_POOL}" \
     --project="${PROJECT_ID}" --location=global &>/dev/null; then
  echo "  [exists] WIF pool: ${WIF_POOL}"
else
  gcloud iam workload-identity-pools create "${WIF_POOL}" \
    --project="${PROJECT_ID}" \
    --location=global \
    --display-name="GitHub Actions Pool"
  echo "  [created] WIF pool: ${WIF_POOL}"
fi

if gcloud iam workload-identity-pools providers describe "${WIF_PROVIDER}" \
     --project="${PROJECT_ID}" --location=global \
     --workload-identity-pool="${WIF_POOL}" &>/dev/null; then
  echo "  [exists] WIF provider: ${WIF_PROVIDER}"
else
  gcloud iam workload-identity-pools providers create-oidc "${WIF_PROVIDER}" \
    --project="${PROJECT_ID}" \
    --location=global \
    --workload-identity-pool="${WIF_POOL}" \
    --display-name="GitHub Actions OIDC Provider" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.actor=assertion.actor" \
    --attribute-condition="attribute.repository=='${GITHUB_REPO}'"
  echo "  [created] WIF provider: ${WIF_PROVIDER}"
fi

WIF_MEMBER="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL}/attribute.repository/${GITHUB_REPO}"
gcloud iam service-accounts add-iam-policy-binding "${SA_TRANSFORM}" \
  --project="${PROJECT_ID}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="${WIF_MEMBER}"
echo "  [bound] WIF → ${SA_TRANSFORM}"

echo ""
echo "=== GCP setup complete ==="
echo ""
echo "Add these secrets to your GitHub repo (Settings → Secrets → Actions):"
echo "  WIF_PROVIDER        = projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL}/providers/${WIF_PROVIDER}"
echo "  WIF_SERVICE_ACCOUNT = ${SA_TRANSFORM}"
echo ""
echo "Local dev setup:"
echo "  1. Copy dbt/profiles.yml.template to ~/.dbt/profiles.yml"
echo "  2. Run: gcloud auth application-default login"
echo "  3. Run: cd dbt && dbt deps && dbt debug"
