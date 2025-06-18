#!/bin/bash

# This script automates the configuration of a Customer-Managed Encryption Key (CMEK)
# for a new Cloud Logging log bucket, based on the documentation at:
# https://cloud.google.com/logging/docs/routing/managed-encryption-storage

set -e # Exit immediately if a command exits with a non-zero status.
set -u # Treat unset variables as an error.

# --- PLEASE CONFIGURE THE VARIABLES BELOW ---

# The Google Cloud project ID where you plan to create the log bucket.
BUCKET_PROJECT_ID="your-bucket-project-id"

# The Google Cloud project ID where your Cloud KMS key is located.
KMS_PROJECT_ID="your-kms-project-id"

# The desired name or ID for the new log bucket.
BUCKET_ID="${BUCKET_PROJECT_ID}-cmek-test"

# The location for the log bucket. IMPORTANT: This must match the region of your KMS key.
# Example: "us", "europe-west2", etc.
LOCATION="us"

# The name of your Cloud KMS key ring.
KMS_KEY_RING="logging-cmek-keyring"

# The name of your Cloud KMS key.
KMS_KEY="logging-cmek-key"

# --- SCRIPT EXECUTION ---

echo "Starting CMEK setup for log bucket '$BUCKET_ID' in project '$BUCKET_PROJECT_ID'..."

# Step 1: Determine the Logging service account ID.
echo -e "\n[Step 1/4] Retrieving the Logging service account for project '$BUCKET_PROJECT_ID'..."
KMS_SERVICE_ACCT=$(gcloud logging settings describe --project="$BUCKET_PROJECT_ID" --format='value(kmsServiceAccountId)')

if [ -z "$KMS_SERVICE_ACCT" ]; then
    echo "Error: Could not retrieve the kmsServiceAccountId for project '$BUCKET_PROJECT_ID'." >&2
    echo "Please ensure the project ID is correct and you have 'logging.settings.get' permissions." >&2
    exit 1
fi
echo "Found Logging KMS Service Account: $KMS_SERVICE_ACCT"

# Step 2: Assign the Encrypter/Decrypter role to the service account.
echo -e "\n[Step 2/4] Assigning 'Cloud KMS CryptoKey Encrypter/Decrypter' role to the service account..."
gcloud kms keys add-iam-policy-binding \
  "projects/$KMS_PROJECT_ID/locations/$LOCATION/keyRings/$KMS_KEY_RING/cryptoKeys/$KMS_KEY" \
  --member "serviceAccount:$KMS_SERVICE_ACCT" \
  --role "roles/cloudkms.cryptoKeyEncrypterDecrypter" \
  --project="$KMS_PROJECT_ID"
echo "Role successfully assigned."

# Step 3: Create the log bucket with CMEK enabled.
FULL_KMS_KEY_NAME="projects/$KMS_PROJECT_ID/locations/$LOCATION/keyRings/$KMS_KEY_RING/cryptoKeys/$KMS_KEY"
echo -e "\n[Step 3/4] Creating log bucket '$BUCKET_ID' with CMEK key: $FULL_KMS_KEY_NAME..."
gcloud logging buckets create "$BUCKET_ID" \
  --location="$LOCATION" \
  --cmek-kms-key-name="$FULL_KMS_KEY_NAME" \
  --project="$BUCKET_PROJECT_ID"
echo "Log bucket '$BUCKET_ID' created successfully."

# Step 4: Verify the key enablement on the new bucket.
echo -e "\n[Step 4/4] Verifying CMEK configuration for bucket '$BUCKET_ID'..."
gcloud logging buckets describe "$BUCKET_ID" \
  --location="$LOCATION" \
  --project="$BUCKET_PROJECT_ID"

echo -e "\nScript finished. Please review the bucket details above to confirm CMEK is enabled."

