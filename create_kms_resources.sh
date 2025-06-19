#!/bin/bash

# Helper script to create KMS resources for CMEK log bucket setup

set -e # Exit immediately if a command exits with a non-zero status.

# Configuration
PROJECT_ID="shenxiang-gcp-solution"
LOCATION="us"
KEY_RING_NAME="logging-cmek-keyring"
KEY_NAME="logging-cmek-key"

echo "Creating KMS resources in project: $PROJECT_ID"
echo "Location: $LOCATION"
echo ""

# Enable Cloud KMS API if not already enabled
echo "Ensuring Cloud KMS API is enabled..."
if gcloud services list --enabled --project="$PROJECT_ID" | grep -q "cloudkms.googleapis.com"; then
    echo "✓ Cloud KMS API is already enabled"
else
    echo "Enabling Cloud KMS API..."
    gcloud services enable cloudkms.googleapis.com --project="$PROJECT_ID"
    echo "✓ Cloud KMS API enabled"
    echo "Waiting for API to be ready..."
    sleep 10
fi

# Check if key ring exists
echo ""
echo "Checking if key ring '$KEY_RING_NAME' exists..."
if gcloud kms keyrings describe "$KEY_RING_NAME" --location="$LOCATION" --project="$PROJECT_ID" &>/dev/null; then
    echo "✓ Key ring already exists"
else
    echo "Creating key ring '$KEY_RING_NAME'..."
    gcloud kms keyrings create "$KEY_RING_NAME" \
        --location="$LOCATION" \
        --project="$PROJECT_ID"
    echo "✓ Key ring created"
fi

# Check if key exists
echo ""
echo "Checking if key '$KEY_NAME' exists..."
if gcloud kms keys describe "$KEY_NAME" \
    --keyring="$KEY_RING_NAME" \
    --location="$LOCATION" \
    --project="$PROJECT_ID" &>/dev/null; then
    echo "✓ Key already exists"
else
    echo "Creating key '$KEY_NAME'..."
    # Calculate next rotation time (30 days from now)
    # Handle both GNU date (Linux) and BSD date (macOS)
    if date --version >/dev/null 2>&1; then
        # GNU date
        NEXT_ROTATION=$(date -u -d '+30 days' '+%Y-%m-%dT%H:%M:%S.%3NZ')
    else
        # BSD date (macOS)
        NEXT_ROTATION=$(date -u -v+30d '+%Y-%m-%dT%H:%M:%S.000Z')
    fi
    
    gcloud kms keys create "$KEY_NAME" \
        --location="$LOCATION" \
        --keyring="$KEY_RING_NAME" \
        --purpose="encryption" \
        --rotation-period="30d" \
        --next-rotation-time="$NEXT_ROTATION" \
        --project="$PROJECT_ID"
    echo "✓ Key created"
fi

echo ""
echo "KMS resources created successfully!"
echo "Key path: projects/$PROJECT_ID/locations/$LOCATION/keyRings/$KEY_RING_NAME/cryptoKeys/$KEY_NAME"
echo ""
echo "You can now run ./setup_cmek_log_bucket.sh to set up your CMEK-enabled log bucket."
