#!/bin/bash

# This script automates the configuration of a Customer-Managed Encryption Key (CMEK)
# for a new Cloud Logging log bucket, based on the documentation at:
# https://cloud.google.com/logging/docs/routing/managed-encryption-storage

set -e # Exit immediately if a command exits with a non-zero status.
set -u # Treat unset variables as an error.

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Function to print error and exit
error_exit() {
    print_message "$RED" "ERROR: $1" >&2
    exit 1
}

# --- CONFIGURATION VARIABLES ---

# Default values
DEFAULT_LOCATION="us"
DEFAULT_KEY_RING="logging-cmek-keyring"
DEFAULT_KEY="logging-cmek-key"
DEFAULT_RETENTION_DAYS="30"

# Parse command line arguments
BUCKET_PROJECT_ID=""
KMS_PROJECT_ID=""
BUCKET_ID=""
LOCATION="$DEFAULT_LOCATION"
KMS_KEY_RING="$DEFAULT_KEY_RING"
KMS_KEY="$DEFAULT_KEY"
RETENTION_DAYS="$DEFAULT_RETENTION_DAYS"
AUTO_CREATE_KMS=false
ENABLE_ANALYTICS=true

# Function to show usage
show_usage() {
    echo "Usage: $0 --bucket-project PROJECT_ID --kms-project PROJECT_ID --bucket-id BUCKET_ID [OPTIONS]"
    echo ""
    echo "Required arguments:"
    echo "  --bucket-project      Project ID where the log bucket will be created"
    echo "  --kms-project         Project ID where the KMS key is located"
    echo "  --bucket-id           Name/ID for the new log bucket"
    echo ""
    echo "Optional arguments:"
    echo "  --location            Location for resources (default: $DEFAULT_LOCATION)"
    echo "  --key-ring            KMS key ring name (default: $DEFAULT_KEY_RING)"
    echo "  --key-name            KMS key name (default: $DEFAULT_KEY)"
    echo "  --retention-days      Log retention in days (default: $DEFAULT_RETENTION_DAYS)"
    echo "  --auto-create-kms     Automatically create KMS resources if they don't exist"
    echo "  --no-analytics        Disable log analytics (enabled by default)"
    echo "  --help, -h            Show this help message"
    echo ""
    echo "Example:"
    echo "  $0 --bucket-project my-project --kms-project my-project --bucket-id my-cmek-logs"
    echo ""
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --bucket-project)
            BUCKET_PROJECT_ID="$2"
            shift 2
            ;;
        --kms-project)
            KMS_PROJECT_ID="$2"
            shift 2
            ;;
        --bucket-id)
            BUCKET_ID="$2"
            shift 2
            ;;
        --location)
            LOCATION="$2"
            shift 2
            ;;
        --key-ring)
            KMS_KEY_RING="$2"
            shift 2
            ;;
        --key-name)
            KMS_KEY="$2"
            shift 2
            ;;
        --retention-days)
            RETENTION_DAYS="$2"
            shift 2
            ;;
        --auto-create-kms)
            AUTO_CREATE_KMS=true
            shift
            ;;
        --no-analytics)
            ENABLE_ANALYTICS=false
            shift
            ;;
        --help|-h)
            show_usage
            ;;
        *)
            error_exit "Unknown argument: $1"
            ;;
    esac
done

# Validate required arguments
if [[ -z "$BUCKET_PROJECT_ID" ]]; then
    # Try to use current project if not specified
    BUCKET_PROJECT_ID=$(gcloud config get-value project 2>/dev/null || true)
    if [[ -z "$BUCKET_PROJECT_ID" ]]; then
        error_exit "Bucket project ID is required. Use --bucket-project or set a default project with 'gcloud config set project PROJECT_ID'"
    fi
    print_message "$YELLOW" "Using current project for bucket: $BUCKET_PROJECT_ID"
fi

if [[ -z "$KMS_PROJECT_ID" ]]; then
    # Default to bucket project if not specified
    KMS_PROJECT_ID="$BUCKET_PROJECT_ID"
    print_message "$YELLOW" "Using bucket project for KMS: $KMS_PROJECT_ID"
fi

if [[ -z "$BUCKET_ID" ]]; then
    # Generate a default bucket ID
    BUCKET_ID="${BUCKET_PROJECT_ID}-cmek-logs"
    print_message "$YELLOW" "Using default bucket ID: $BUCKET_ID"
fi

# --- SCRIPT EXECUTION ---

print_message "$BLUE" "=== Cloud Logging CMEK Bucket Setup ==="
print_message "$GREEN" "Bucket Project: $BUCKET_PROJECT_ID"
print_message "$GREEN" "KMS Project: $KMS_PROJECT_ID"
print_message "$GREEN" "Bucket ID: $BUCKET_ID"
print_message "$GREEN" "Location: $LOCATION"
print_message "$GREEN" "Key Ring: $KMS_KEY_RING"
print_message "$GREEN" "Key Name: $KMS_KEY"
print_message "$GREEN" "Retention: $RETENTION_DAYS days"
print_message "$GREEN" "Log Analytics: $(if [[ "$ENABLE_ANALYTICS" == "true" ]]; then echo "Enabled"; else echo "Disabled"; fi)"
echo ""

# Step 0: Check if log bucket already exists
print_message "$YELLOW" "[Step 0/6] Checking if log bucket already exists..."
if gcloud logging buckets describe "$BUCKET_ID" \
    --location="$LOCATION" \
    --project="$BUCKET_PROJECT_ID" &>/dev/null; then
    print_message "$YELLOW" "Log bucket '$BUCKET_ID' already exists. Checking CMEK configuration..."
    
    EXISTING_CMEK=$(gcloud logging buckets describe "$BUCKET_ID" \
        --location="$LOCATION" \
        --project="$BUCKET_PROJECT_ID" \
        --format="value(cmekSettings.kmsKeyName)" 2>/dev/null || true)
    
    if [[ -n "$EXISTING_CMEK" ]]; then
        print_message "$GREEN" "✓ Bucket already has CMEK enabled: $EXISTING_CMEK"
        print_message "$YELLOW" "Do you want to update it with the new key? (y/N)"
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            print_message "$YELLOW" "Exiting without changes."
            exit 0
        fi
    fi
fi

# Step 1: Verify that the KMS key exists
print_message "$YELLOW" "[Step 1/6] Verifying KMS key exists..."
if ! gcloud kms keys describe "$KMS_KEY" \
  --keyring="$KMS_KEY_RING" \
  --location="$LOCATION" \
  --project="$KMS_PROJECT_ID" &>/dev/null; then
    
    if [[ "$AUTO_CREATE_KMS" == "true" ]]; then
        print_message "$YELLOW" "KMS key not found. Auto-creating KMS resources..."
        
        # Enable KMS API
        print_message "$YELLOW" "Enabling Cloud KMS API..."
        gcloud services enable cloudkms.googleapis.com --project="$KMS_PROJECT_ID" || true
        sleep 5
        
        # Create key ring if needed
        if ! gcloud kms keyrings describe "$KMS_KEY_RING" --location="$LOCATION" --project="$KMS_PROJECT_ID" &>/dev/null; then
            print_message "$YELLOW" "Creating key ring '$KMS_KEY_RING'..."
            gcloud kms keyrings create "$KMS_KEY_RING" \
                --location="$LOCATION" \
                --project="$KMS_PROJECT_ID"
        fi
        
        # Create key
        print_message "$YELLOW" "Creating key '$KMS_KEY'..."
        # Calculate next rotation time (30 days from now)
        if date --version >/dev/null 2>&1; then
            # GNU date
            NEXT_ROTATION=$(date -u -d '+30 days' '+%Y-%m-%dT%H:%M:%S.%3NZ')
        else
            # BSD date (macOS)
            NEXT_ROTATION=$(date -u -v+30d '+%Y-%m-%dT%H:%M:%S.000Z')
        fi
        
        gcloud kms keys create "$KMS_KEY" \
            --location="$LOCATION" \
            --keyring="$KMS_KEY_RING" \
            --purpose="encryption" \
            --rotation-period="30d" \
            --next-rotation-time="$NEXT_ROTATION" \
            --project="$KMS_PROJECT_ID"
        
        print_message "$GREEN" "✓ KMS resources created successfully"
    else
        print_message "$RED" "Error: KMS key not found at projects/$KMS_PROJECT_ID/locations/$LOCATION/keyRings/$KMS_KEY_RING/cryptoKeys/$KMS_KEY"
        echo ""
        print_message "$YELLOW" "To create the KMS resources, you can either:"
        print_message "$YELLOW" "1. Run this script with --auto-create-kms flag"
        print_message "$YELLOW" "2. Run ./create_kms_resources.sh"
        print_message "$YELLOW" "3. Create them manually using:"
        echo "     gcloud kms keyrings create $KMS_KEY_RING --location=$LOCATION --project=$KMS_PROJECT_ID"
        echo "     gcloud kms keys create $KMS_KEY --keyring=$KMS_KEY_RING --location=$LOCATION --purpose=encryption --project=$KMS_PROJECT_ID"
        exit 1
    fi
fi
print_message "$GREEN" "✓ KMS key verified"

# Step 2: Enable required APIs
print_message "$YELLOW" "[Step 2/6] Ensuring required APIs are enabled..."

# Enable Logging API in bucket project
if ! gcloud services list --enabled --project="$BUCKET_PROJECT_ID" | grep -q "logging.googleapis.com"; then
    print_message "$YELLOW" "Enabling Cloud Logging API in bucket project..."
    gcloud services enable logging.googleapis.com --project="$BUCKET_PROJECT_ID"
    sleep 5
fi

# Enable KMS API in KMS project if different
if [[ "$KMS_PROJECT_ID" != "$BUCKET_PROJECT_ID" ]]; then
    if ! gcloud services list --enabled --project="$KMS_PROJECT_ID" | grep -q "cloudkms.googleapis.com"; then
        print_message "$YELLOW" "Enabling Cloud KMS API in KMS project..."
        gcloud services enable cloudkms.googleapis.com --project="$KMS_PROJECT_ID"
        sleep 5
    fi
fi

print_message "$GREEN" "✓ Required APIs enabled"

# Step 3: Determine the Logging service account ID.
print_message "$YELLOW" "[Step 3/6] Retrieving the Logging service account for project '$BUCKET_PROJECT_ID'..."

# Retry logic for getting service account
MAX_RETRIES=5
RETRY_COUNT=0
KMS_SERVICE_ACCT=""

while [[ $RETRY_COUNT -lt $MAX_RETRIES && -z "$KMS_SERVICE_ACCT" ]]; do
    KMS_SERVICE_ACCT=$(gcloud logging settings describe --project="$BUCKET_PROJECT_ID" --format='value(kmsServiceAccountId)' 2>/dev/null || true)
    
    if [[ -z "$KMS_SERVICE_ACCT" ]]; then
        if [[ $RETRY_COUNT -eq 0 ]]; then
            print_message "$YELLOW" "Logging service account not found. Triggering creation..."
            # Create a temporary log entry to trigger service account creation
            gcloud logging write init-log "Initializing logging service account" --project="$BUCKET_PROJECT_ID" &>/dev/null || true
        fi
        
        print_message "$YELLOW" "Waiting for service account creation... (attempt $((RETRY_COUNT + 1))/$MAX_RETRIES)"
        sleep 10
        RETRY_COUNT=$((RETRY_COUNT + 1))
    fi
done

if [[ -z "$KMS_SERVICE_ACCT" ]]; then
    error_exit "Could not retrieve the Logging service account after $MAX_RETRIES attempts. Please ensure you have the necessary permissions."
fi

print_message "$GREEN" "✓ Found Logging KMS Service Account: $KMS_SERVICE_ACCT"

# Step 4: Assign the Encrypter/Decrypter role to the service account.
print_message "$YELLOW" "[Step 4/6] Assigning 'Cloud KMS CryptoKey Encrypter/Decrypter' role to the service account..."

# Check if the role is already assigned
EXISTING_BINDING=$(gcloud kms keys get-iam-policy "$KMS_KEY" \
    --keyring="$KMS_KEY_RING" \
    --location="$LOCATION" \
    --project="$KMS_PROJECT_ID" \
    --flatten="bindings[].members" \
    --filter="bindings.members:serviceAccount:$KMS_SERVICE_ACCT AND bindings.role:roles/cloudkms.cryptoKeyEncrypterDecrypter" \
    --format="value(bindings.members)" 2>/dev/null || true)

if [[ -n "$EXISTING_BINDING" ]]; then
    print_message "$GREEN" "✓ Role already assigned"
else
    if gcloud kms keys add-iam-policy-binding "$KMS_KEY" \
        --keyring="$KMS_KEY_RING" \
        --location="$LOCATION" \
        --member="serviceAccount:$KMS_SERVICE_ACCT" \
        --role="roles/cloudkms.cryptoKeyEncrypterDecrypter" \
        --project="$KMS_PROJECT_ID" 2>&1 | tee /tmp/iam_binding_output.txt; then
        print_message "$GREEN" "✓ Role successfully assigned"
    else
        print_message "$RED" "Failed to assign IAM role"
        cat /tmp/iam_binding_output.txt
        error_exit "Could not grant KMS permissions to the Logging service account"
    fi
fi

# Step 5: Create or update the log bucket with CMEK enabled.
FULL_KMS_KEY_NAME="projects/$KMS_PROJECT_ID/locations/$LOCATION/keyRings/$KMS_KEY_RING/cryptoKeys/$KMS_KEY"
print_message "$YELLOW" "[Step 5/6] Configuring log bucket '$BUCKET_ID' with CMEK..."

if gcloud logging buckets describe "$BUCKET_ID" \
    --location="$LOCATION" \
    --project="$BUCKET_PROJECT_ID" &>/dev/null; then
    # Update existing bucket
    print_message "$YELLOW" "Updating existing log bucket with CMEK..."
    UPDATE_CMD="gcloud logging buckets update \"$BUCKET_ID\" \
        --location=\"$LOCATION\" \
        --cmek-kms-key-name=\"$FULL_KMS_KEY_NAME\" \
        --retention-days=\"$RETENTION_DAYS\""
    
    if [[ "$ENABLE_ANALYTICS" == "true" ]]; then
        UPDATE_CMD="$UPDATE_CMD --enable-analytics"
    fi
    
    UPDATE_CMD="$UPDATE_CMD --project=\"$BUCKET_PROJECT_ID\""
    
    if eval "$UPDATE_CMD" 2>&1 | tee /tmp/bucket_update_output.txt; then
        print_message "$GREEN" "✓ Log bucket updated successfully"
    else
        print_message "$RED" "Failed to update log bucket"
        cat /tmp/bucket_update_output.txt
        error_exit "Could not update the log bucket with CMEK"
    fi
else
    # Create new bucket
    print_message "$YELLOW" "Creating new log bucket with CMEK..."
    CREATE_CMD="gcloud logging buckets create \"$BUCKET_ID\" \
        --location=\"$LOCATION\" \
        --cmek-kms-key-name=\"$FULL_KMS_KEY_NAME\" \
        --retention-days=\"$RETENTION_DAYS\""
    
    if [[ "$ENABLE_ANALYTICS" == "true" ]]; then
        CREATE_CMD="$CREATE_CMD --enable-analytics"
    fi
    
    CREATE_CMD="$CREATE_CMD --project=\"$BUCKET_PROJECT_ID\""
    
    if eval "$CREATE_CMD" 2>&1 | tee /tmp/bucket_create_output.txt; then
        print_message "$GREEN" "✓ Log bucket created successfully"
    else
        print_message "$RED" "Failed to create log bucket"
        cat /tmp/bucket_create_output.txt
        error_exit "Could not create the log bucket with CMEK"
    fi
fi

# Step 6: Verify the key enablement on the bucket.
print_message "$YELLOW" "[Step 6/6] Verifying CMEK configuration for bucket '$BUCKET_ID'..."

BUCKET_INFO=$(gcloud logging buckets describe "$BUCKET_ID" \
    --location="$LOCATION" \
    --project="$BUCKET_PROJECT_ID" \
    --format=json)

CMEK_KEY=$(echo "$BUCKET_INFO" | jq -r '.cmekSettings.kmsKeyName // empty')
RETENTION=$(echo "$BUCKET_INFO" | jq -r '.retentionDays // empty')
ANALYTICS_ENABLED=$(echo "$BUCKET_INFO" | jq -r '.analyticsEnabled // false')

if [[ -n "$CMEK_KEY" ]]; then
    print_message "$GREEN" "✓ CMEK is enabled: $CMEK_KEY"
    print_message "$GREEN" "✓ Retention period: $RETENTION days"
    print_message "$GREEN" "✓ Log Analytics: $(if [[ "$ANALYTICS_ENABLED" == "true" ]]; then echo "Enabled"; else echo "Disabled"; fi)"
else
    print_message "$RED" "✗ CMEK is NOT enabled on the bucket"
    error_exit "CMEK configuration verification failed"
fi

# Display summary
echo ""
print_message "$BLUE" "=== Setup Complete ==="
print_message "$GREEN" "✓ Log bucket: $BUCKET_ID"
print_message "$GREEN" "✓ Location: $LOCATION"
print_message "$GREEN" "✓ Project: $BUCKET_PROJECT_ID"
print_message "$GREEN" "✓ CMEK Key: $CMEK_KEY"
print_message "$GREEN" "✓ Retention: $RETENTION days"
print_message "$GREEN" "✓ Log Analytics: $(if [[ "$ANALYTICS_ENABLED" == "true" ]]; then echo "Enabled"; else echo "Disabled"; fi)"
echo ""
print_message "$YELLOW" "To route logs to this bucket, create a log sink:"
echo "  gcloud logging sinks create SINK_NAME \\"
echo "    logging.googleapis.com/projects/$BUCKET_PROJECT_ID/locations/$LOCATION/buckets/$BUCKET_ID \\"
echo "    --log-filter='YOUR_FILTER' \\"
echo "    --project=YOUR_PROJECT"
