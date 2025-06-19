#!/bin/bash

# This script tears down the CMEK log bucket configuration created by setup_cmek_log_bucket.sh
# It will:
# - Delete the log bucket
# - Remove IAM bindings from the KMS key
# - Optionally delete the KMS key and keyring (with confirmation)
# - NOT disable any APIs that were enabled

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

# Parse command line arguments
BUCKET_PROJECT_ID=""
KMS_PROJECT_ID=""
BUCKET_ID=""
LOCATION="$DEFAULT_LOCATION"
KMS_KEY_RING="$DEFAULT_KEY_RING"
KMS_KEY="$DEFAULT_KEY"
DELETE_KMS_RESOURCES=false
FORCE=false
SINK_NAME=""

# Function to show usage
show_usage() {
    echo "Usage: $0 --bucket-project PROJECT_ID --kms-project PROJECT_ID --bucket-id BUCKET_ID [OPTIONS]"
    echo ""
    echo "Required arguments:"
    echo "  --bucket-project      Project ID where the log bucket exists"
    echo "  --kms-project         Project ID where the KMS key is located"
    echo "  --bucket-id           Name/ID of the log bucket to delete"
    echo ""
    echo "Optional arguments:"
    echo "  --location            Location of resources (default: $DEFAULT_LOCATION)"
    echo "  --key-ring            KMS key ring name (default: $DEFAULT_KEY_RING)"
    echo "  --key-name            KMS key name (default: $DEFAULT_KEY)"
    echo "  --sink-name           Name of the log sink to delete (default: BUCKET_ID-sink)"
    echo "  --delete-kms          Also delete the KMS key and keyring (requires confirmation)"
    echo "  --force               Skip confirmation prompts (use with caution!)"
    echo "  --help, -h            Show this help message"
    echo ""
    echo "Example:"
    echo "  $0 --bucket-project my-project --kms-project my-project --bucket-id my-cmek-logs"
    echo ""
    echo "WARNING: This will permanently delete resources. Use with caution!"
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
        --sink-name)
            SINK_NAME="$2"
            shift 2
            ;;
        --delete-kms)
            DELETE_KMS_RESOURCES=true
            shift
            ;;
        --force)
            FORCE=true
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
    # Generate the default bucket ID
    BUCKET_ID="${BUCKET_PROJECT_ID}-cmek-logs"
    print_message "$YELLOW" "Using default bucket ID: $BUCKET_ID"
fi

if [[ -z "$SINK_NAME" ]]; then
    # Generate the default sink name
    SINK_NAME="${BUCKET_ID}-sink"
fi

# --- SCRIPT EXECUTION ---

print_message "$BLUE" "=== Cloud Logging CMEK Bucket Teardown ==="
print_message "$YELLOW" "This script will delete the following resources:"
print_message "$RED" "  • Log bucket: $BUCKET_ID (in project $BUCKET_PROJECT_ID)"
print_message "$RED" "  • Log sink: $SINK_NAME (if exists)"
print_message "$RED" "  • IAM bindings on KMS key: $KMS_KEY"
if [[ "$DELETE_KMS_RESOURCES" == "true" ]]; then
    print_message "$RED" "  • KMS key: $KMS_KEY (in keyring $KMS_KEY_RING)"
    print_message "$RED" "  • KMS keyring: $KMS_KEY_RING (if empty)"
fi
echo ""

# Confirmation prompt
if [[ "$FORCE" != "true" ]]; then
    print_message "$YELLOW" "Are you sure you want to delete these resources? This action cannot be undone! (yes/no)"
    read -r response
    if [[ ! "$response" =~ ^[Yy][Ee][Ss]$ ]]; then
        print_message "$YELLOW" "Teardown cancelled."
        exit 0
    fi
fi

# Step 1: Delete log sink if it exists
print_message "$YELLOW" "[Step 1/6] Checking and deleting log sink..."
if gcloud logging sinks describe "$SINK_NAME" --project="$BUCKET_PROJECT_ID" &>/dev/null; then
    print_message "$YELLOW" "Deleting log sink '$SINK_NAME'..."
    if gcloud logging sinks delete "$SINK_NAME" --project="$BUCKET_PROJECT_ID" 2>&1 | tee /tmp/sink_delete_output.txt; then
        print_message "$GREEN" "✓ Log sink deleted successfully"
    else
        print_message "$RED" "Failed to delete log sink"
        cat /tmp/sink_delete_output.txt
    fi
else
    print_message "$YELLOW" "Log sink '$SINK_NAME' not found or already deleted"
fi

# Step 2: Remove exclusion from _Default sink
print_message "$YELLOW" "[Step 2/6] Removing exclusion from _Default sink..."
EXCLUSION_NAME="${SINK_NAME}-exclusion"

# Remove the exclusion from _Default sink
if gcloud logging sinks update _Default \
    --remove-exclusion="${EXCLUSION_NAME}" \
    --project="$BUCKET_PROJECT_ID" 2>&1 | tee /tmp/default_sink_update.txt; then
    print_message "$GREEN" "✓ Exclusion removed from _Default sink successfully"
else
    if grep -q "does not exist" /tmp/default_sink_update.txt || grep -q "not found" /tmp/default_sink_update.txt; then
        print_message "$YELLOW" "Exclusion '$EXCLUSION_NAME' not found in _Default sink (may have been already removed)"
    else
        print_message "$RED" "Failed to remove exclusion from _Default sink"
        cat /tmp/default_sink_update.txt
    fi
fi

# Step 3: Check if log bucket exists and get its configuration
print_message "$YELLOW" "[Step 3/6] Checking log bucket configuration..."
if ! gcloud logging buckets describe "$BUCKET_ID" \
    --location="$LOCATION" \
    --project="$BUCKET_PROJECT_ID" &>/dev/null; then
    print_message "$YELLOW" "Log bucket '$BUCKET_ID' not found in project '$BUCKET_PROJECT_ID' at location '$LOCATION'"
    print_message "$YELLOW" "It may have already been deleted or doesn't exist."
else
    # Get the CMEK key used by the bucket
    BUCKET_CMEK=$(gcloud logging buckets describe "$BUCKET_ID" \
        --location="$LOCATION" \
        --project="$BUCKET_PROJECT_ID" \
        --format="value(cmekSettings.kmsKeyName)" 2>/dev/null || true)
    
    if [[ -n "$BUCKET_CMEK" ]]; then
        print_message "$GREEN" "✓ Found bucket with CMEK: $BUCKET_CMEK"
    else
        print_message "$YELLOW" "Bucket exists but doesn't have CMEK enabled"
    fi
fi

# Step 4: Delete the log bucket
print_message "$YELLOW" "[Step 4/6] Deleting log bucket..."
if gcloud logging buckets describe "$BUCKET_ID" \
    --location="$LOCATION" \
    --project="$BUCKET_PROJECT_ID" &>/dev/null; then
    
    if gcloud logging buckets delete "$BUCKET_ID" \
        --location="$LOCATION" \
        --project="$BUCKET_PROJECT_ID" 2>&1 | tee /tmp/bucket_delete_output.txt; then
        print_message "$GREEN" "✓ Log bucket deleted successfully"
    else
        print_message "$RED" "Failed to delete log bucket"
        cat /tmp/bucket_delete_output.txt
        # Continue with other cleanup even if bucket deletion fails
    fi
else
    print_message "$YELLOW" "Log bucket already deleted or doesn't exist"
fi

# Step 5: Remove IAM binding from KMS key
print_message "$YELLOW" "[Step 5/6] Removing IAM bindings from KMS key..."

# Get the Logging service account
PROJECT_NUMBER=$(gcloud projects describe "$BUCKET_PROJECT_ID" --format="value(projectNumber)" 2>/dev/null || true)
if [[ -n "$PROJECT_NUMBER" ]]; then
    LOGGING_SA="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-logging.iam.gserviceaccount.com"
    
    # Check if the KMS key exists
    if gcloud kms keys describe "$KMS_KEY" \
        --keyring="$KMS_KEY_RING" \
        --location="$LOCATION" \
        --project="$KMS_PROJECT_ID" &>/dev/null; then
        
        # Check if the binding exists
        EXISTING_BINDING=$(gcloud kms keys get-iam-policy "$KMS_KEY" \
            --keyring="$KMS_KEY_RING" \
            --location="$LOCATION" \
            --project="$KMS_PROJECT_ID" \
            --flatten="bindings[].members" \
            --filter="bindings.members:$LOGGING_SA AND bindings.role:roles/cloudkms.cryptoKeyEncrypterDecrypter" \
            --format="value(bindings.members)" 2>/dev/null || true)
        
        if [[ -n "$EXISTING_BINDING" ]]; then
            print_message "$YELLOW" "Removing IAM binding for $LOGGING_SA..."
            if gcloud kms keys remove-iam-policy-binding "$KMS_KEY" \
                --keyring="$KMS_KEY_RING" \
                --location="$LOCATION" \
                --member="$LOGGING_SA" \
                --role="roles/cloudkms.cryptoKeyEncrypterDecrypter" \
                --project="$KMS_PROJECT_ID" 2>&1 | tee /tmp/iam_remove_output.txt; then
                print_message "$GREEN" "✓ IAM binding removed successfully"
            else
                print_message "$RED" "Failed to remove IAM binding"
                cat /tmp/iam_remove_output.txt
            fi
        else
            print_message "$YELLOW" "IAM binding not found or already removed"
        fi
    else
        print_message "$YELLOW" "KMS key not found, skipping IAM binding removal"
    fi
else
    print_message "$YELLOW" "Could not determine project number, skipping IAM cleanup"
fi

# Step 6: Optionally delete KMS resources
if [[ "$DELETE_KMS_RESOURCES" == "true" ]]; then
    print_message "$YELLOW" "[Step 6/6] Deleting KMS resources..."
    
    # Check if KMS key exists
    if gcloud kms keys describe "$KMS_KEY" \
        --keyring="$KMS_KEY_RING" \
        --location="$LOCATION" \
        --project="$KMS_PROJECT_ID" &>/dev/null; then
        
        print_message "$YELLOW" "Scheduling KMS key for destruction..."
        print_message "$RED" "WARNING: KMS keys have a 24-hour waiting period before permanent deletion!"
        
        if [[ "$FORCE" != "true" ]]; then
            print_message "$YELLOW" "Are you sure you want to schedule the KMS key for destruction? (yes/no)"
            read -r response
            if [[ ! "$response" =~ ^[Yy][Ee][Ss]$ ]]; then
                print_message "$YELLOW" "Skipping KMS key deletion"
            else
                # Schedule key for destruction
                if gcloud kms keys versions destroy 1 \
                    --key="$KMS_KEY" \
                    --keyring="$KMS_KEY_RING" \
                    --location="$LOCATION" \
                    --project="$KMS_PROJECT_ID" 2>&1 | tee /tmp/key_destroy_output.txt; then
                    print_message "$GREEN" "✓ KMS key scheduled for destruction (24-hour waiting period)"
                    print_message "$YELLOW" "To cancel destruction within 24 hours, use:"
                    echo "  gcloud kms keys versions restore 1 \\"
                    echo "    --key=$KMS_KEY \\"
                    echo "    --keyring=$KMS_KEY_RING \\"
                    echo "    --location=$LOCATION \\"
                    echo "    --project=$KMS_PROJECT_ID"
                else
                    print_message "$RED" "Failed to schedule key destruction"
                    cat /tmp/key_destroy_output.txt
                fi
            fi
        else
            # Force mode - schedule destruction without confirmation
            gcloud kms keys versions destroy 1 \
                --key="$KMS_KEY" \
                --keyring="$KMS_KEY_RING" \
                --location="$LOCATION" \
                --project="$KMS_PROJECT_ID" &>/dev/null || true
            print_message "$GREEN" "✓ KMS key scheduled for destruction"
        fi
    else
        print_message "$YELLOW" "KMS key not found or already deleted"
    fi
    
    # Note: KMS keyrings cannot be deleted, only keys within them
    print_message "$YELLOW" "Note: KMS keyrings cannot be deleted. The keyring '$KMS_KEY_RING' will remain but will be empty."
else
    print_message "$YELLOW" "[Step 6/6] Skipping KMS resource deletion (use --delete-kms to delete them)"
fi

# Display summary
echo ""
print_message "$BLUE" "=== Teardown Complete ==="
print_message "$GREEN" "The following actions were performed:"
print_message "$GREEN" "✓ Log sink '$SINK_NAME' deleted (or was already deleted)"
print_message "$GREEN" "✓ Exclusion removed from _Default sink (if existed)"
print_message "$GREEN" "✓ Log bucket '$BUCKET_ID' deleted (or was already deleted)"
print_message "$GREEN" "✓ IAM bindings removed from KMS key"
if [[ "$DELETE_KMS_RESOURCES" == "true" ]]; then
    print_message "$GREEN" "✓ KMS key scheduled for destruction (24-hour waiting period)"
fi
print_message "$YELLOW" ""
print_message "$YELLOW" "Note: APIs that were enabled during setup have been left enabled."
print_message "$YELLOW" "If you want to disable them, you can do so manually:"
echo "  gcloud services disable logging.googleapis.com --project=$BUCKET_PROJECT_ID"
echo "  gcloud services disable cloudkms.googleapis.com --project=$KMS_PROJECT_ID"
