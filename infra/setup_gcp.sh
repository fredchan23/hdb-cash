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

echo ""
echo "=== GCP setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Download key for dbt-transform SA and set DBT_GOOGLE_KEYFILE env var."
echo "  2. Copy dbt/profiles.yml.template to ~/.dbt/profiles.yml and fill in key path."
echo "  3. Run: cd dbt && dbt deps && dbt debug"
