#!/bin/bash

# Script to create a Google Cloud folder and configure CMEK for logging
# Following: https://cloud.google.com/logging/docs/routing/managed-encryption
# 
# Features:
# - Creates a folder in your organization
# - Automatically creates a test project within the folder
# - Enables necessary APIs with proper error handling
# - Creates KMS keyring and key
# - Configures log bucket with CMEK
# - Sets up log sink for routing logs

set -euo pipefail

# Configuration variables
ORGANIZATION_ID=""
FOLDER_NAME=""
LOCATION="us"
KEY_RING_NAME="logging-cmek-keyring"
KEY_NAME="logging-cmek-key"
LOG_BUCKET_NAME=""
BILLING_ACCOUNT_ID=""
PROJECT_ID=""  # This will be set to the test project ID

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
    
    if ! command -v openssl &> /dev/null; then
        print_message "$RED" "Error: openssl is not installed. Please install it first."
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
    
    if [[ -z "$LOG_BUCKET_NAME" ]]; then
        print_message "$RED" "Error: LOG_BUCKET_NAME is not set."
        exit 1
    fi
    
    if [[ -z "$BILLING_ACCOUNT_ID" ]]; then
        print_message "$RED" "Error: BILLING_ACCOUNT_ID is not set."
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

# Function to create test project in the folder
create_test_project() {
    print_message "$YELLOW" "Creating test project in folder..."
    
    # Create predictable project ID based on folder name
    # Replace spaces and special characters with hyphens, convert to lowercase
    FOLDER_PREFIX=$(echo "$FOLDER_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')
    
    # Add a random suffix to make project ID unique
    RANDOM_SUFFIX=$(openssl rand -hex 3)
    
    # Create project ID with random suffix
    TEST_PROJECT_ID="${FOLDER_PREFIX}-cmek-${RANDOM_SUFFIX}"
    
    # Ensure project ID is valid (6-30 characters, lowercase letters, numbers, hyphens)
    # Truncate if necessary (keeping the random suffix at the end)
    if [ ${#TEST_PROJECT_ID} -gt 30 ]; then
        # Calculate how much to trim from the prefix
        TRIM_LENGTH=$((${#TEST_PROJECT_ID} - 30))
        FOLDER_PREFIX_TRIMMED=$(echo "$FOLDER_PREFIX" | cut -c1-$((${#FOLDER_PREFIX} - TRIM_LENGTH)))
        TEST_PROJECT_ID="${FOLDER_PREFIX_TRIMMED}-cmek-${RANDOM_SUFFIX}"
    fi
    
    print_message "$YELLOW" "Generated project ID: $TEST_PROJECT_ID"
    
    # Create test project
    print_message "$YELLOW" "Creating test project: $TEST_PROJECT_ID..."
    if ! gcloud projects describe "$TEST_PROJECT_ID" &>/dev/null; then
        if ! gcloud projects create "$TEST_PROJECT_ID" \
            --name="CMEK Test Project" \
            --folder="$FOLDER_ID" 2>&1 | tee /tmp/project_create_output.txt; then
            print_message "$RED" "Failed to create project $TEST_PROJECT_ID"
            cat /tmp/project_create_output.txt
            
            # Check if it's a duplicate project ID error
            if grep -q "already exists" /tmp/project_create_output.txt; then
                print_message "$YELLOW" "Project ID already exists globally. Trying with a different ID..."
                # Try again with a different random suffix
                RANDOM_SUFFIX=$(openssl rand -hex 4)
                TEST_PROJECT_ID="${FOLDER_PREFIX}-cmek-${RANDOM_SUFFIX}"
                if [ ${#TEST_PROJECT_ID} -gt 30 ]; then
                    TEST_PROJECT_ID=$(echo "$TEST_PROJECT_ID" | cut -c1-30)
                fi
                print_message "$YELLOW" "New project ID: $TEST_PROJECT_ID"
                
                if ! gcloud projects create "$TEST_PROJECT_ID" \
                    --name="CMEK Test Project" \
                    --folder="$FOLDER_ID" 2>&1 | tee /tmp/project_create_output2.txt; then
                    print_message "$RED" "Failed to create project with new ID"
                    cat /tmp/project_create_output2.txt
                    return 1
                fi
            else
                return 1
            fi
        fi
        
        # Wait for project to be fully created
        print_message "$YELLOW" "Waiting for project to be fully provisioned..."
        sleep 15
        
        # Verify project exists and we can access it
        print_message "$YELLOW" "Verifying project access..."
        local retry_count=0
        local max_retries=5
        
        while [ $retry_count -lt $max_retries ]; do
            if gcloud projects describe "$TEST_PROJECT_ID" &>/dev/null; then
                print_message "$GREEN" "✓ Project is accessible"
                break
            else
                print_message "$YELLOW" "Project not yet accessible, waiting... (attempt $((retry_count + 1))/$max_retries)"
                sleep 10
                retry_count=$((retry_count + 1))
            fi
        done
        
        if [ $retry_count -eq $max_retries ]; then
            print_message "$RED" "Project $TEST_PROJECT_ID was created but cannot be accessed after $max_retries attempts"
            return 1
        fi
        
        # Link billing account
        print_message "$YELLOW" "Linking billing account to $TEST_PROJECT_ID..."
        if ! gcloud billing projects link "$TEST_PROJECT_ID" \
            --billing-account="$BILLING_ACCOUNT_ID" 2>&1 | tee /tmp/billing_link_output.txt; then
            print_message "$RED" "Failed to link billing account"
            cat /tmp/billing_link_output.txt
            print_message "$YELLOW" "Continuing without billing account..."
        fi
        
        print_message "$GREEN" "Test project created: $TEST_PROJECT_ID"
    else
        print_message "$YELLOW" "Project $TEST_PROJECT_ID already exists"
    fi
    
    # Set PROJECT_ID for KMS resources
    PROJECT_ID="$TEST_PROJECT_ID"
    print_message "$YELLOW" "Using $PROJECT_ID for KMS resources"
    
    # Set the project as the current project
    print_message "$YELLOW" "Setting $PROJECT_ID as the current project..."
    gcloud config set project "$PROJECT_ID"
    
    # Wait a bit more for everything to be ready
    print_message "$YELLOW" "Waiting for project to be fully ready..."
    sleep 10
}

# Function to enable required APIs
enable_required_apis() {
    print_message "$YELLOW" "Enabling required APIs..."
    
    # Enable Cloud KMS API
    print_message "$YELLOW" "Enabling Cloud KMS API..."
    if gcloud services list --enabled --project="$PROJECT_ID" | grep -q "cloudkms.googleapis.com"; then
        print_message "$GREEN" "✓ Cloud KMS API is already enabled"
    else
        if gcloud services enable cloudkms.googleapis.com --project="$PROJECT_ID" 2>&1 | tee /tmp/kms_api_enable.txt; then
            print_message "$GREEN" "✓ Cloud KMS API enabled successfully"
            sleep 10
        else
            print_message "$RED" "✗ Failed to enable Cloud KMS API"
            cat /tmp/kms_api_enable.txt
            
            # Check if we can at least use the API
            if gcloud kms keyrings list --location="$LOCATION" --project="$PROJECT_ID" &>/dev/null; then
                print_message "$GREEN" "✓ Cloud KMS API appears to be working despite the error"
            else
                print_message "$RED" "✗ Cloud KMS API is not accessible"
                return 1
            fi
        fi
    fi
    
    # Enable Cloud Logging API (this ensures the service account is created)
    print_message "$YELLOW" "Enabling Cloud Logging API..."
    if gcloud services list --enabled --project="$PROJECT_ID" | grep -q "logging.googleapis.com"; then
        print_message "$GREEN" "✓ Cloud Logging API is already enabled"
    else
        if gcloud services enable logging.googleapis.com --project="$PROJECT_ID" 2>&1 | tee /tmp/logging_api_enable.txt; then
            print_message "$GREEN" "✓ Cloud Logging API enabled successfully"
            sleep 10
        else
            print_message "$RED" "✗ Failed to enable Cloud Logging API"
            cat /tmp/logging_api_enable.txt
        fi
    fi
    
    # Ensure the Logging service account exists by making a simple API call
    print_message "$YELLOW" "Ensuring Cloud Logging service account exists..."
    if gcloud logging logs list --project="$PROJECT_ID" --limit=1 &>/dev/null; then
        print_message "$GREEN" "✓ Cloud Logging service account is ready"
    else
        print_message "$YELLOW" "Triggering Cloud Logging service account creation..."
        # Try to write a simple log entry to trigger service account creation
        gcloud logging write test-log "Test log entry to trigger service account creation" --project="$PROJECT_ID" &>/dev/null || true
        sleep 10
    fi
    
    return 0
}

# Function to create KMS key ring and key
create_kms_resources() {
    print_message "$YELLOW" "Creating KMS resources..."
    
    # Check if key ring exists
    if ! gcloud kms keyrings describe "$KEY_RING_NAME" --location="$LOCATION" --project="$PROJECT_ID" &>/dev/null; then
        print_message "$YELLOW" "Creating KMS key ring..."
        if ! gcloud kms keyrings create "$KEY_RING_NAME" \
            --location="$LOCATION" \
            --project="$PROJECT_ID" 2>&1 | tee /tmp/keyring_create_output.txt; then
            print_message "$RED" "✗ Failed to create KMS key ring"
            cat /tmp/keyring_create_output.txt
            return 1
        fi
        print_message "$GREEN" "✓ KMS key ring created successfully"
    else
        print_message "$YELLOW" "KMS key ring already exists."
    fi
    
    # Check if key exists
    if ! gcloud kms keys describe "$KEY_NAME" \
        --keyring="$KEY_RING_NAME" \
        --location="$LOCATION" \
        --project="$PROJECT_ID" &>/dev/null; then
        print_message "$YELLOW" "Creating KMS key..."
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
    
    # Wait for the service account to be created
    print_message "$YELLOW" "Waiting for Cloud Logging service account to be created..."
    local retry_count=0
    local max_retries=10
    
    while [ $retry_count -lt $max_retries ]; do
        # Try to check if the service account exists by listing IAM policy
        if gcloud projects get-iam-policy "$PROJECT_ID" --flatten="bindings[].members" --format="value(bindings.members)" | grep -q "service-${PROJECT_NUMBER}@gcp-sa-logging.iam.gserviceaccount.com"; then
            print_message "$GREEN" "✓ Cloud Logging service account exists"
            break
        else
            print_message "$YELLOW" "Service account not yet created, waiting... (attempt $((retry_count + 1))/$max_retries)"
            
            # Try to trigger service account creation by creating a log bucket
            if [ $retry_count -eq 0 ]; then
                print_message "$YELLOW" "Creating a temporary log bucket to trigger service account creation..."
                gcloud logging buckets create temp-bucket-${RANDOM} \
                    --location="$LOCATION" \
                    --project="$PROJECT_ID" \
                    --retention-days=1 &>/dev/null || true
            fi
            
            sleep 10
            retry_count=$((retry_count + 1))
        fi
    done
    
    if [ $retry_count -eq $max_retries ]; then
        print_message "$RED" "Cloud Logging service account was not created after $max_retries attempts"
        print_message "$YELLOW" "This might be a temporary issue. You can try running the script again."
        return 1
    fi
    
    # Grant the Cloud KMS CryptoKey Encrypter/Decrypter role
    print_message "$YELLOW" "Granting KMS permissions to $LOGGING_SA..."
    if gcloud kms keys add-iam-policy-binding "$KEY_NAME" \
        --location="$LOCATION" \
        --keyring="$KEY_RING_NAME" \
        --member="$LOGGING_SA" \
        --role="roles/cloudkms.cryptoKeyEncrypterDecrypter" \
        --project="$PROJECT_ID" 2>&1 | tee /tmp/kms_iam_output.txt; then
        print_message "$GREEN" "KMS permissions granted successfully."
    else
        print_message "$RED" "Failed to grant KMS permissions"
        cat /tmp/kms_iam_output.txt
        return 1
    fi
}

# Function to create or update log bucket with CMEK
configure_log_bucket_cmek() {
    print_message "$YELLOW" "Configuring log bucket with CMEK..."
    
    # First ensure we have a log bucket in the project to trigger service account creation
    print_message "$YELLOW" "Ensuring project log bucket exists to trigger service account creation..."
    if ! gcloud logging buckets describe "_Default" \
        --location="global" \
        --project="$PROJECT_ID" &>/dev/null; then
        print_message "$YELLOW" "Creating default log bucket in project..."
        gcloud logging buckets create "_Default" \
            --location="global" \
            --project="$PROJECT_ID" \
            --retention-days=30 &>/dev/null || true
        sleep 5
    fi
    
    # Construct the full KMS key name
    KMS_KEY_NAME="projects/$PROJECT_ID/locations/$LOCATION/keyRings/$KEY_RING_NAME/cryptoKeys/$KEY_NAME"
    
    # Check if log bucket exists at folder level
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
                # Deprecated - kept for backward compatibility
                print_message "$YELLOW" "Warning: --project-id is deprecated. The script will create and use a test project automatically."
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
            --billing-account-id)
                BILLING_ACCOUNT_ID="$2"
                shift 2
                ;;
            --help|-h)
                echo "Usage: $0 --org-id ORG_ID --folder-name FOLDER_NAME --log-bucket-name BUCKET_NAME --billing-account-id BILLING_ID [OPTIONS]"
                echo ""
                echo "Required arguments:"
                echo "  --org-id              Organization ID"
                echo "  --folder-name         Name of the folder to create"
                echo "  --log-bucket-name     Name of the log bucket"
                echo "  --billing-account-id  Billing account ID for test projects"
                echo ""
                echo "Optional arguments:"
                echo "  --location            Location for resources (default: us)"
                echo "  --key-ring-name       KMS key ring name (default: logging-cmek-keyring)"
                echo "  --key-name            KMS key name (default: logging-cmek-key)"
                echo "  --help, -h            Show this help message"
                echo ""
                echo "Note: The script will automatically create a test project in the folder and use it for KMS resources."
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
    
    if create_test_project; then
        print_message "$GREEN" "✓ Project creation successful!"
        
        if enable_required_apis; then
            print_message "$GREEN" "✓ Required APIs enabled successfully!"
            
            if create_kms_resources; then
                grant_kms_permissions
                configure_log_bucket_cmek
                create_log_sink
                verify_cmek_configuration
                
                print_message "$GREEN" "=== Setup completed successfully! ==="
                print_message "$GREEN" "Folder ID: $FOLDER_ID"
                print_message "$GREEN" "Test Project: $PROJECT_ID"
                print_message "$GREEN" "KMS Key: projects/$PROJECT_ID/locations/$LOCATION/keyRings/$KEY_RING_NAME/cryptoKeys/$KEY_NAME"
                print_message "$GREEN" "Log Bucket: $LOG_BUCKET_NAME"
                print_message "$GREEN" ""
                print_message "$GREEN" "All logs from projects in folder $FOLDER_ID will now be encrypted with your CMEK key."
            else
                print_message "$YELLOW" "=== Partial setup completed ==="
                print_message "$YELLOW" "Project and APIs were set up, but KMS resources could not be created."
                print_message "$GREEN" "Folder ID: $FOLDER_ID"
                print_message "$GREEN" "Test Project: $PROJECT_ID"
            fi
        else
            print_message "$YELLOW" "=== Partial setup completed ==="
            print_message "$YELLOW" "Project was created but required APIs could not be enabled."
            print_message "$GREEN" "Folder ID: $FOLDER_ID"
            print_message "$GREEN" "Test Project: $PROJECT_ID"
        fi
    else
        print_message "$RED" "=== Setup failed ==="
        print_message "$RED" "Could not create or access the test project."
        print_message "$GREEN" "Folder ID: $FOLDER_ID"
    fi
}

# Run main function
main "$@"
