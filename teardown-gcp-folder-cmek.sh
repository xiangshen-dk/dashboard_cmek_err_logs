#!/bin/bash

# Script to teardown/remove all resources created by setup-gcp-folder-cmek.sh
# 
# IMPORTANT: Folders in GCP can only be deleted when empty!
# This script will:
# 1. Delete all projects in the folder (this removes most resources)
# 2. Delete folder-level resources (log sink, log bucket)
# 3. Schedule KMS keys for destruction (24-hour delay)
# 4. Attempt to delete the folder (only succeeds if empty)
#
# Note: KMS keyrings cannot be deleted (GCP limitation)

set -euo pipefail

# Configuration variables
ORGANIZATION_ID=""
FOLDER_NAME=""
PROJECT_ID=""
LOCATION="us-central1"
KEY_RING_NAME="logging-cmek-keyring"
KEY_NAME="logging-cmek-key"
LOG_BUCKET_NAME=""
REMOVE_FOLDER=false
FORCE=false
DELETE_ALL_PROJECTS=false

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

# Function to get folder ID from folder name
get_folder_id() {
    print_message "$YELLOW" "Looking up folder ID for '$FOLDER_NAME'..."
    
    FOLDER_ID=$(gcloud resource-manager folders list \
        --organization="$ORGANIZATION_ID" \
        --filter="displayName:$FOLDER_NAME" \
        --format="value(name)" 2>/dev/null | cut -d'/' -f2 || true)
    
    if [[ -z "$FOLDER_ID" ]]; then
        print_message "$RED" "Folder '$FOLDER_NAME' not found in organization '$ORGANIZATION_ID'"
        return 1
    fi
    
    print_message "$GREEN" "Found folder ID: $FOLDER_ID"
    return 0
}

# Function to confirm deletion
confirm_deletion() {
    if [[ "$FORCE" == "true" ]]; then
        return 0
    fi
    
    print_message "$YELLOW" "\n=== Resources to be deleted ==="
    print_message "$NC" "Organization: $ORGANIZATION_ID"
    print_message "$NC" "Folder: $FOLDER_NAME (ID: $FOLDER_ID)"
    print_message "$NC" "KMS Project: $PROJECT_ID"
    print_message "$NC" "Location: $LOCATION"
    print_message "$NC" "Log Bucket: $LOG_BUCKET_NAME"
    print_message "$NC" "KMS Key Ring: $KEY_RING_NAME"
    print_message "$NC" "KMS Key: $KEY_NAME"
    
    if [[ "$REMOVE_FOLDER" == "true" ]]; then
        print_message "$RED" "Folder will be removed (if empty)"
    fi
    
    print_message "$RED" "\nThis will also delete all test projects in the folder!"
    print_message "$YELLOW" "\nAre you sure you want to delete these resources? (yes/no): "
    read -r response
    
    if [[ ! "$response" =~ ^[Yy][Ee][Ss]$ ]]; then
        print_message "$YELLOW" "Deletion cancelled."
        exit 0
    fi
}

# Function to delete log sink
delete_log_sink() {
    print_message "$YELLOW" "Deleting log sink..."
    
    SINK_NAME="${LOG_BUCKET_NAME}-sink"
    
    if gcloud logging sinks describe "$SINK_NAME" --folder="$FOLDER_ID" &>/dev/null; then
        gcloud logging sinks delete "$SINK_NAME" \
            --folder="$FOLDER_ID" \
            --quiet
        print_message "$GREEN" "✓ Log sink deleted: $SINK_NAME"
    else
        print_message "$YELLOW" "Log sink not found: $SINK_NAME"
    fi
}

# Function to delete log bucket
delete_log_bucket() {
    print_message "$YELLOW" "Deleting log bucket..."
    
    if gcloud logging buckets describe "$LOG_BUCKET_NAME" \
        --location="$LOCATION" \
        --folder="$FOLDER_ID" &>/dev/null; then
        gcloud logging buckets delete "$LOG_BUCKET_NAME" \
            --location="$LOCATION" \
            --folder="$FOLDER_ID" \
            --quiet
        print_message "$GREEN" "✓ Log bucket deleted: $LOG_BUCKET_NAME"
    else
        print_message "$YELLOW" "Log bucket not found: $LOG_BUCKET_NAME"
    fi
}

# Function to delete KMS resources
delete_kms_resources() {
    print_message "$YELLOW" "Deleting KMS resources..."
    
    # Set the project
    gcloud config set project "$PROJECT_ID"
    
    # Delete KMS key (schedule for destruction)
    if gcloud kms keys describe "$KEY_NAME" \
        --keyring="$KEY_RING_NAME" \
        --location="$LOCATION" &>/dev/null; then
        print_message "$YELLOW" "Scheduling KMS key for destruction..."
        
        # Get all versions of the key
        KEY_VERSIONS=$(gcloud kms keys versions list \
            --key="$KEY_NAME" \
            --keyring="$KEY_RING_NAME" \
            --location="$LOCATION" \
            --filter="state:ENABLED OR state:DISABLED" \
            --format="value(name)")
        
        # Destroy each key version
        for VERSION in $KEY_VERSIONS; do
            VERSION_NUM=$(basename "$VERSION")
            print_message "$YELLOW" "Destroying key version: $VERSION_NUM"
            gcloud kms keys versions destroy "$VERSION_NUM" \
                --key="$KEY_NAME" \
                --keyring="$KEY_RING_NAME" \
                --location="$LOCATION" \
                --quiet
        done
        
        print_message "$GREEN" "✓ KMS key scheduled for destruction: $KEY_NAME"
        print_message "$YELLOW" "Note: Key versions will be destroyed after 24 hours (default destroy scheduled duration)"
    else
        print_message "$YELLOW" "KMS key not found: $KEY_NAME"
    fi
    
    # Note: Key rings cannot be deleted in Google Cloud
    print_message "$YELLOW" "Note: KMS key ring '$KEY_RING_NAME' cannot be deleted (GCP limitation)"
}

# Function to delete test projects
delete_test_projects() {
    if [[ "$DELETE_ALL_PROJECTS" == "true" ]]; then
        print_message "$YELLOW" "Finding and deleting ALL projects in folder..."
    else
        print_message "$YELLOW" "Finding and deleting test projects in folder..."
    fi
    
    # List all projects in the folder
    # Using simpler filter to avoid syntax issues
    PROJECTS=$(gcloud projects list \
        --filter="parent.id:$FOLDER_ID" \
        --format="value(projectId)")
    
    if [[ -z "$PROJECTS" ]]; then
        print_message "$YELLOW" "No projects found in folder"
        return
    fi
    
    # Delete each project
    for PROJECT in $PROJECTS; do
        # Check if we should delete this project
        # Projects now follow pattern: {folder-prefix}-test-project1, {folder-prefix}-test-project2
        if [[ "$DELETE_ALL_PROJECTS" == "true" ]] || [[ "$PROJECT" =~ -test-project[0-9]+$ ]]; then
            print_message "$YELLOW" "Deleting project: $PROJECT"
            
            # First, shut down any billing
            gcloud billing projects unlink "$PROJECT" 2>/dev/null || true
            
            # Delete the project
            if gcloud projects delete "$PROJECT" --quiet 2>/dev/null; then
                print_message "$GREEN" "✓ Project deleted: $PROJECT"
            else
                print_message "$YELLOW" "Failed to delete project: $PROJECT (may already be deleted)"
            fi
        else
            print_message "$YELLOW" "Skipping non-test project: $PROJECT"
        fi
    done
}

# Function to delete folder (if empty)
delete_folder() {
    if [[ "$REMOVE_FOLDER" != "true" ]]; then
        print_message "$YELLOW" "Skipping folder deletion (use --remove-folder to delete)"
        return
    fi
    
    print_message "$YELLOW" "Attempting to delete folder..."
    
    # Check if folder has any resources
    FOLDER_PROJECTS=$(gcloud projects list --filter="parent.id:$FOLDER_ID" --format="value(projectId)" | wc -l)
    FOLDER_SUBFOLDERS=$(gcloud resource-manager folders list --folder="$FOLDER_ID" --format="value(name)" | wc -l)
    
    if [[ "$FOLDER_PROJECTS" -gt 0 ]] || [[ "$FOLDER_SUBFOLDERS" -gt 0 ]]; then
        print_message "$RED" "✗ Cannot delete folder - it still contains resources"
        print_message "$YELLOW" "  Projects: $FOLDER_PROJECTS"
        print_message "$YELLOW" "  Subfolders: $FOLDER_SUBFOLDERS"
        return
    fi
    
    # Delete the folder
    gcloud resource-manager folders delete "$FOLDER_ID" --quiet
    print_message "$GREEN" "✓ Folder deleted: $FOLDER_NAME"
}

# Function to show remaining resources
show_remaining_resources() {
    print_message "$YELLOW" "\n=== Checking for remaining resources ==="
    
    # Check if KMS keyring still exists (it will, as it can't be deleted)
    print_message "$YELLOW" "KMS Key Ring '$KEY_RING_NAME' still exists (cannot be deleted)"
    
    # Check for any remaining projects in folder
    if [[ -n "$FOLDER_ID" ]]; then
        REMAINING_PROJECTS=$(gcloud projects list --filter="parent.id:$FOLDER_ID" --format="value(projectId)")
        if [[ -n "$REMAINING_PROJECTS" ]]; then
            print_message "$YELLOW" "\nRemaining projects in folder:"
            echo "$REMAINING_PROJECTS"
        fi
    fi
}

# Main execution
main() {
    print_message "$GREEN" "=== Google Cloud CMEK Teardown Script ==="
    
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
            --remove-folder)
                REMOVE_FOLDER=true
                shift
                ;;
            --force)
                FORCE=true
                shift
                ;;
            --delete-all-projects)
                DELETE_ALL_PROJECTS=true
                shift
                ;;
            --help|-h)
                echo "Usage: $0 --org-id ORG_ID --folder-name FOLDER_NAME --project-id PROJECT_ID --log-bucket-name BUCKET_NAME [OPTIONS]"
                echo ""
                echo "Required arguments:"
                echo "  --org-id              Organization ID"
                echo "  --folder-name         Name of the folder containing resources"
                echo "  --project-id          Project ID where KMS resources exist"
                echo "  --log-bucket-name     Name of the log bucket to delete"
                echo ""
                echo "Optional arguments:"
                echo "  --location            Location for resources (default: us)"
                echo "  --key-ring-name       KMS key ring name (default: logging-cmek-keyring)"
                echo "  --key-name            KMS key name (default: logging-cmek-key)"
                echo "  --remove-folder       Also remove the folder if empty"
                echo "  --force               Skip confirmation prompt"
                echo "  --delete-all-projects Delete ALL projects in folder (not just test projects)"
                echo "  --help, -h            Show this help message"
                exit 0
                ;;
            *)
                print_message "$RED" "Unknown argument: $1"
                exit 1
                ;;
        esac
    done
    
    # Execute teardown steps
    check_prerequisites
    validate_inputs
    
    # Get folder ID
    if ! get_folder_id; then
        print_message "$RED" "Cannot proceed without valid folder ID"
        exit 1
    fi
    
    # Confirm deletion
    confirm_deletion
    
    print_message "$YELLOW" "\nStarting resource deletion..."
    
    # Delete resources in reverse order of creation
    delete_log_sink
    delete_log_bucket
    delete_kms_resources
    delete_test_projects
    delete_folder
    
    # Show any remaining resources
    show_remaining_resources
    
    print_message "$GREEN" "\n=== Teardown completed ==="
    print_message "$YELLOW" "Note: KMS key versions are scheduled for destruction and will be permanently deleted after 24 hours"
    print_message "$YELLOW" "Note: KMS key rings cannot be deleted in Google Cloud Platform"
}

# Run main function
main "$@"
