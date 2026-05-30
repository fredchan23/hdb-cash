#!/usr/bin/env python3
"""
load_to_bq.py

Uploads HDB resale CSV files to GCS and appends them into
BigQuery table  hdb-cash.raw.hdb_resale_transactions.

Usage
-----
# Initial bulk load from local data-raw/ directory
python ingestion/load_to_bq.py --source-dir data-raw/

# Single new release file (after a new authority release)
python ingestion/load_to_bq.py --source-file /path/to/new_release.csv

# Load only to BigQuery (skip GCS upload, useful for local dev)
python ingestion/load_to_bq.py --source-dir data-raw/ --skip-gcs

Environment
-----------
  DBT_GOOGLE_KEYFILE   Path to the dbt-transform service-account JSON key.
                       Falls back to Application Default Credentials if unset.
"""

from __future__ import annotations

import argparse
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd
from dotenv import load_dotenv
from google.cloud import bigquery, storage
from google.oauth2 import service_account

load_dotenv()

# -----------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------
PROJECT_ID = "hdb-cash"
GCS_BUCKET = "hdb-cash-raw"
BQ_DATASET = "raw"
BQ_TABLE = "hdb_resale_transactions"
BQ_TABLE_REF = f"{PROJECT_ID}.{BQ_DATASET}.{BQ_TABLE}"

# Columns that must exist in every loaded row (in order)
FINAL_COLUMNS = [
    "month",
    "town",
    "flat_type",
    "block",
    "street_name",
    "storey_range",
    "floor_area_sqm",
    "flat_model",
    "lease_commence_date",
    "remaining_lease",   # NULL for pre-2015 files
    "resale_price",
    "source_file",
    "source_basis",
    "loaded_at",
]

BQ_SCHEMA = [
    bigquery.SchemaField("month",                "STRING"),
    bigquery.SchemaField("town",                 "STRING"),
    bigquery.SchemaField("flat_type",            "STRING"),
    bigquery.SchemaField("block",                "STRING"),
    bigquery.SchemaField("street_name",          "STRING"),
    bigquery.SchemaField("storey_range",         "STRING"),
    bigquery.SchemaField("floor_area_sqm",       "STRING"),
    bigquery.SchemaField("flat_model",           "STRING"),
    bigquery.SchemaField("lease_commence_date",  "STRING"),
    bigquery.SchemaField("remaining_lease",      "STRING",    mode="NULLABLE"),
    bigquery.SchemaField("resale_price",         "STRING"),
    bigquery.SchemaField("source_file",          "STRING"),
    bigquery.SchemaField("source_basis",         "STRING"),
    bigquery.SchemaField("loaded_at",            "TIMESTAMP"),
]


# -----------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------

def _build_clients() -> tuple[storage.Client | None, bigquery.Client]:
    keyfile = os.getenv("DBT_GOOGLE_KEYFILE")
    # Only use keyfile if the path is set AND the file actually exists with content.
    # Falls back to ADC when key creation is blocked by org policy.
    if keyfile and Path(keyfile).expanduser().exists() and Path(keyfile).expanduser().stat().st_size > 0:
        keyfile = str(Path(keyfile).expanduser())
        creds = service_account.Credentials.from_service_account_file(
            keyfile,
            scopes=[
                "https://www.googleapis.com/auth/cloud-platform",
            ],
        )
        gcs_client = storage.Client(project=PROJECT_ID, credentials=creds)
        bq_client  = bigquery.Client(project=PROJECT_ID, credentials=creds)
    else:
        # Fall back to Application Default Credentials
        gcs_client = storage.Client(project=PROJECT_ID)
        bq_client  = bigquery.Client(project=PROJECT_ID)
    return gcs_client, bq_client


def _detect_source_basis(filename: str) -> str:
    """Return 'approval' for pre-2012 files, 'registration' for all others."""
    return "approval" if "approval" in filename.lower() else "registration"


def _read_csv(filepath: Path) -> pd.DataFrame:
    """Read CSV with all columns as strings; normalise column names."""
    df = pd.read_csv(filepath, dtype=str)
    df.columns = [c.strip().lower().replace(" ", "_") for c in df.columns]
    return df


def _harmonise(df: pd.DataFrame, filepath: Path) -> pd.DataFrame:
    """Add metadata and ensure schema completeness."""
    df = df.copy()

    # Ensure remaining_lease exists (absent in pre-2015 files)
    if "remaining_lease" not in df.columns:
        df["remaining_lease"] = None

    df["source_file"]   = filepath.name
    df["source_basis"]  = _detect_source_basis(filepath.name)
    df["loaded_at"]     = datetime.now(timezone.utc).replace(microsecond=0)

    # Detect unexpected extra columns and log them (schema drift warning)
    known = set(FINAL_COLUMNS)
    extra = [c for c in df.columns if c not in known]
    if extra:
        print(f"  [WARN] Unexpected columns in {filepath.name}: {extra}")
        print(f"         They are stored in BigQuery but not modelled yet.")

    # Ensure all required columns present and in order
    for col in FINAL_COLUMNS:
        if col not in df.columns:
            df[col] = None
    df = df[FINAL_COLUMNS]

    return df


def _upload_to_gcs(filepath: Path, gcs_client: storage.Client) -> None:
    bucket = gcs_client.bucket(GCS_BUCKET)
    gcs_path = f"releases/{filepath.name}"
    blob = bucket.blob(gcs_path)
    blob.upload_from_filename(str(filepath))
    print(f"  Uploaded to gs://{GCS_BUCKET}/{gcs_path}")


def _load_to_bq(df: pd.DataFrame, bq_client: bigquery.Client) -> None:
    job_config = bigquery.LoadJobConfig(
        schema=BQ_SCHEMA,
        write_disposition=bigquery.WriteDisposition.WRITE_APPEND,
        create_disposition=bigquery.CreateDisposition.CREATE_IF_NEEDED,
    )
    job = bq_client.load_table_from_dataframe(df, BQ_TABLE_REF, job_config=job_config)
    job.result()  # blocks until complete
    print(f"  Loaded {len(df):,} rows into {BQ_TABLE_REF}")


# -----------------------------------------------------------------------
# Main pipeline
# -----------------------------------------------------------------------

def process_file(filepath: Path, skip_gcs: bool, gcs_client: storage.Client, bq_client: bigquery.Client) -> None:
    print(f"\nProcessing: {filepath.name}")
    df = _read_csv(filepath)
    df = _harmonise(df, filepath)

    if not skip_gcs:
        _upload_to_gcs(filepath, gcs_client)

    _load_to_bq(df, bq_client)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Load HDB resale CSVs to GCS and BigQuery (hdb-cash project).",
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--source-dir",  help="Directory containing CSV files to load.")
    group.add_argument("--source-file", help="Path to a single CSV file to load.")
    parser.add_argument(
        "--skip-gcs",
        action="store_true",
        help="Skip GCS upload and load directly to BigQuery (useful for local dev).",
    )
    args = parser.parse_args()

    gcs_client, bq_client = _build_clients()

    if args.source_dir:
        csvs = sorted(Path(args.source_dir).glob("*.csv"))
        if not csvs:
            print(f"ERROR: No CSV files found in {args.source_dir}", file=sys.stderr)
            sys.exit(1)
        for csv_file in csvs:
            process_file(csv_file, args.skip_gcs, gcs_client, bq_client)
    else:
        process_file(Path(args.source_file), args.skip_gcs, gcs_client, bq_client)

    print("\nDone.")


if __name__ == "__main__":
    main()
