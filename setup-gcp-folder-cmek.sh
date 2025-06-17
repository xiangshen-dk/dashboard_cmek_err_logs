#!/bin/bash

# Script to create a Google Cloud folder and configure CMEK for logging
# Following: https://cloud.google.com/logging/docs/routing/managed-encryption

set -euo pipefail

# Configuration variables
ORGANIZATION_ID=""
FOLDER_NAME=""
PROJECT_ID=""
LOCATION="us-central1"
KEY_RING_NAME="logging-cmek-keyring"
KEY_NAME="logging-cmek-key"
LOG_BUCKET_NAME=""

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Function to check if required tools are installed
check_prerequisites() {
    print_message "$YELLOW" "Checking prerequisites..."
    
    if ! command -v gcloud &> /dev/null; then
        print_message "$RED" "Error: gcloud CLI is not installed. Please install it first."
        exit 1
    fi
    
    if ! command -v jq &> /dev/null; then
        print_message "$RED" "Error: jq is not installed. Please install it first."
        exit 1
    fi
    
    print_message "$GREEN" "Prerequisites check passed."
}

# Function to validate inputs
validate_inputs() {
    if [[ -z "$ORGANIZATION_ID" ]]; then
        print_message "$RED" "Error: ORGANIZATION_ID is not set."
        exit 1
    fi
    
    if [[ -z "$FOLDER_NAME" ]]; then
        print_message "$RED" "Error: FOLDER_NAME is not set."
        exit 1
    fi
    
    if [[ -z "$PROJECT_ID" ]]; then
        print_message "$RED" "Error: PROJECT_ID is not set."
        exit 1
    fi
    
    if [[ -z "$LOG_BUCKET_NAME" ]]; then
        print_message "$RED" "Error: LOG_BUCKET_NAME is not set."
        exit 1
    fi
    
    print_message "$GREEN" "Input validation passed."
}

# Function to create folder in organization
create_folder() {
    print_message "$YELLOW" "Creating folder '$FOLDER_NAME' in organization '$ORGANIZATION_ID'..."
    
    # Check if folder already exists
    EXISTING_FOLDER=$(gcloud resource-manager folders list \
        --organization="$ORGANIZATION_ID" \
        --filter="displayName:$FOLDER_NAME" \
        --format="value(name)" 2>/dev/null || true)
    
    if [[ -n "$EXISTING_FOLDER" ]]; then
        print_message "$YELLOW" "Folder already exists: $EXISTING_FOLDER"
        FOLDER_ID=$(echo "$EXISTING_FOLDER" | cut -d'/' -f2)
    else
        # Create the folder
        FOLDER_RESPONSE=$(gcloud resource-manager folders create \
            --display-name="$FOLDER_NAME" \
            --organization="$ORGANIZATION_ID" \
            --format=json)
        
        FOLDER_ID=$(echo "$FOLDER_RESPONSE" | jq -r '.name' | cut -d'/' -f2)
        print_message "$GREEN" "Folder created successfully. Folder ID: $FOLDER_ID"
    fi
}

# Function to create KMS key ring and key
create_kms_resources() {
    print_message "$YELLOW" "Creating KMS resources..."
    
    # Set the project
    gcloud config set project "$PROJECT_ID"
    
    # Enable required APIs
    print_message "$YELLOW" "Enabling required APIs..."
    gcloud services enable cloudkms.googleapis.com
    gcloud services enable logging.googleapis.com
    
    # Check if key ring exists
    if ! gcloud kms keyrings describe "$KEY_RING_NAME" --location="$LOCATION" &>/dev/null; then
        print_message "$YELLOW" "Creating KMS key ring..."
        gcloud kms keyrings create "$KEY_RING_NAME" \
            --location="$LOCATION"
    else
        print_message "$YELLOW" "KMS key ring already exists."
    fi
    
    # Check if key exists
    if ! gcloud kms keys describe "$KEY_NAME" \
        --keyring="$KEY_RING_NAME" \
        --location="$LOCATION" &>/dev/null; then
        print_message "$YELLOW" "Creating KMS key..."
        gcloud kms keys create "$KEY_NAME" \
            --location="$LOCATION" \
            --keyring="$KEY_RING_NAME" \
            --purpose="encryption" \
            --rotation-period="30d" \
            --next-rotation-time="$(date -u -d '+30 days' '+%Y-%m-%dT%H:%M:%S.%3NZ')"
    else
        print_message "$YELLOW" "KMS key already exists."
    fi
    
    print_message "$GREEN" "KMS resources created successfully."
}

# Function to grant permissions for Cloud Logging to use the KMS key
grant_kms_permissions() {
    print_message "$YELLOW" "Granting KMS permissions to Cloud Logging service account..."
    
    # Get the Cloud Logging service account
    PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")
    LOGGING_SA="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-logging.iam.gserviceaccount.com"
    
    # Grant the Cloud KMS CryptoKey Encrypter/Decrypter role
    gcloud kms keys add-iam-policy-binding "$KEY_NAME" \
        --location="$LOCATION" \
        --keyring="$KEY_RING_NAME" \
        --member="$LOGGING_SA" \
        --role="roles/cloudkms.cryptoKeyEncrypterDecrypter"
    
    print_message "$GREEN" "KMS permissions granted successfully."
}

# Function to create or update log bucket with CMEK
configure_log_bucket_cmek() {
    print_message "$YELLOW" "Configuring log bucket with CMEK..."
    
    # Construct the full KMS key name
    KMS_KEY_NAME="projects/$PROJECT_ID/locations/$LOCATION/keyRings/$KEY_RING_NAME/cryptoKeys/$KEY_NAME"
    
    # Check if log bucket exists
    if gcloud logging buckets describe "$LOG_BUCKET_NAME" \
        --location="$LOCATION" \
        --folder="$FOLDER_ID" &>/dev/null; then
        print_message "$YELLOW" "Updating existing log bucket with CMEK..."
        gcloud logging buckets update "$LOG_BUCKET_NAME" \
            --location="$LOCATION" \
            --folder="$FOLDER_ID" \
            --cmek-kms-key-name="$KMS_KEY_NAME"
    else
        print_message "$YELLOW" "Creating new log bucket with CMEK..."
        gcloud logging buckets create "$LOG_BUCKET_NAME" \
            --location="$LOCATION" \
            --folder="$FOLDER_ID" \
            --retention-days=30 \
            --cmek-kms-key-name="$KMS_KEY_NAME"
    fi
    
    print_message "$GREEN" "Log bucket configured with CMEK successfully."
}

# Function to create a log sink to route logs to the CMEK-enabled bucket
create_log_sink() {
    print_message "$YELLOW" "Creating log sink to route logs to CMEK-enabled bucket..."
    
    SINK_NAME="${LOG_BUCKET_NAME}-sink"
    DESTINATION="logging.googleapis.com/projects/$PROJECT_ID/locations/$LOCATION/buckets/$LOG_BUCKET_NAME"
    
    # Check if sink exists
    if gcloud logging sinks describe "$SINK_NAME" --folder="$FOLDER_ID" &>/dev/null; then
        print_message "$YELLOW" "Updating existing log sink..."
        gcloud logging sinks update "$SINK_NAME" \
            --folder="$FOLDER_ID" \
            --log-filter='' \
            --destination="$DESTINATION"
    else
        print_message "$YELLOW" "Creating new log sink..."
        gcloud logging sinks create "$SINK_NAME" \
            --folder="$FOLDER_ID" \
            --log-filter='' \
            --destination="$DESTINATION"
    fi
    
    print_message "$GREEN" "Log sink configured successfully."
}

# Function to verify CMEK configuration
verify_cmek_configuration() {
    print_message "$YELLOW" "Verifying CMEK configuration..."
    
    # Check bucket CMEK configuration
    BUCKET_CMEK=$(gcloud logging buckets describe "$LOG_BUCKET_NAME" \
        --location="$LOCATION" \
        --folder="$FOLDER_ID" \
        --format="value(cmekSettings.kmsKeyName)")
    
    if [[ -n "$BUCKET_CMEK" ]]; then
        print_message "$GREEN" "✓ Log bucket is configured with CMEK: $BUCKET_CMEK"
    else
        print_message "$RED" "✗ Log bucket is NOT configured with CMEK"
        return 1
    fi
    
    # Check if logs are being routed
    SINK_DESTINATION=$(gcloud logging sinks describe "${LOG_BUCKET_NAME}-sink" \
        --folder="$FOLDER_ID" \
        --format="value(destination)")
    
    if [[ -n "$SINK_DESTINATION" ]]; then
        print_message "$GREEN" "✓ Log sink is configured: $SINK_DESTINATION"
    else
        print_message "$RED" "✗ Log sink is NOT configured"
        return 1
    fi
}

# Main execution
main() {
    print_message "$GREEN" "=== Google Cloud Folder and CMEK Setup Script ==="
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --org-id)
                ORGANIZATION_ID="$2"
                shift 2
                ;;
            --folder-name)
                FOLDER_NAME="$2"
                shift 2
                ;;
            --project-id)
                PROJECT_ID="$2"
                shift 2
                ;;
            --location)
                LOCATION="$2"
                shift 2
                ;;
            --key-ring-name)
                KEY_RING_NAME="$2"
                shift 2
                ;;
            --key-name)
                KEY_NAME="$2"
                shift 2
                ;;
            --log-bucket-name)
                LOG_BUCKET_NAME="$2"
                shift 2
                ;;
            --help|-h)
                echo "Usage: $0 --org-id ORG_ID --folder-name FOLDER_NAME --project-id PROJECT_ID --log-bucket-name BUCKET_NAME [OPTIONS]"
                echo ""
                echo "Required arguments:"
                echo "  --org-id          Organization ID"
                echo "  --folder-name     Name of the folder to create"
                echo "  --project-id      Project ID for KMS resources"
                echo "  --log-bucket-name Name of the log bucket"
                echo ""
                echo "Optional arguments:"
                echo "  --location        Location for resources (default: us-central1)"
                echo "  --key-ring-name   KMS key ring name (default: logging-cmek-keyring)"
                echo "  --key-name        KMS key name (default: logging-cmek-key)"
                echo "  --help, -h        Show this help message"
                exit 0
                ;;
            *)
                print_message "$RED" "Unknown argument: $1"
                exit 1
                ;;
        esac
    done
    
    # Execute steps
    check_prerequisites
    validate_inputs
    create_folder
    create_kms_resources
    grant_kms_permissions
    configure_log_bucket_cmek
    create_log_sink
    verify_cmek_configuration
    
    print_message "$GREEN" "=== Setup completed successfully! ==="
    print_message "$GREEN" "Folder ID: $FOLDER_ID"
    print_message "$GREEN" "KMS Key: projects/$PROJECT_ID/locations/$LOCATION/keyRings/$KEY_RING_NAME/cryptoKeys/$KEY_NAME"
    print_message "$GREEN" "Log Bucket: $LOG_BUCKET_NAME"
}

# Run main function
main "$@"