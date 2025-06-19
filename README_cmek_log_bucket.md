# CMEK Log Bucket Setup Scripts

This repository contains scripts to set up and manage Cloud Logging buckets with Customer-Managed Encryption Keys (CMEK) in Google Cloud Platform.

## Scripts Overview

### 1. `setup_cmek_log_bucket.sh`
Main script for creating a Cloud Logging bucket with CMEK encryption and log analytics.

**Features:**
- Creates a log bucket with CMEK encryption
- Enables log analytics by default (can be disabled with `--no-analytics`)
- Automatically configures IAM permissions for the Logging service account
- Can auto-create KMS resources if they don't exist
- Supports updating existing buckets

**Usage:**
```bash
# Basic usage (will prompt for missing values)
./setup_cmek_log_bucket.sh \
    --bucket-project PROJECT_ID \
    --kms-project PROJECT_ID \
    --bucket-id BUCKET_ID

# Full example with all options
./setup_cmek_log_bucket.sh \
    --bucket-project my-project \
    --kms-project my-project \
    --bucket-id my-cmek-logs \
    --location us \
    --key-ring logging-cmek-keyring \
    --key-name logging-cmek-key \
    --retention-days 30 \
    --auto-create-kms

# Disable log analytics
./setup_cmek_log_bucket.sh \
    --bucket-project my-project \
    --kms-project my-project \
    --bucket-id my-cmek-logs \
    --no-analytics
```

### 2. `setup_cmek_log_bucket_simple.sh`
Wrapper script with hardcoded values for quick setup.

```bash
# Uses predefined values for shenxiang-gcp-solution project
./setup_cmek_log_bucket_simple.sh

# Pass additional flags
./setup_cmek_log_bucket_simple.sh --auto-create-kms
```

### 3. `create_kms_resources.sh`
Helper script to create KMS keyring and key if they don't exist.

```bash
./create_kms_resources.sh
```

### 4. `teardown_cmek_log_bucket.sh`
Removes all resources created by the setup script.

**Features:**
- Deletes the log bucket
- Removes IAM bindings from the KMS key
- Optionally schedules KMS key for destruction
- Preserves enabled APIs

**Usage:**
```bash
# Basic teardown
./teardown_cmek_log_bucket.sh \
    --bucket-project PROJECT_ID \
    --kms-project PROJECT_ID \
    --bucket-id BUCKET_ID

# Also delete KMS resources
./teardown_cmek_log_bucket.sh \
    --bucket-project my-project \
    --kms-project my-project \
    --bucket-id my-cmek-logs \
    --delete-kms

# Skip confirmation prompts
./teardown_cmek_log_bucket.sh \
    --bucket-project my-project \
    --kms-project my-project \
    --bucket-id my-cmek-logs \
    --force
```

### 5. `teardown_cmek_log_bucket_simple.sh`
Wrapper script for teardown with hardcoded values.

```bash
# Simple teardown
./teardown_cmek_log_bucket_simple.sh

# With KMS deletion
./teardown_cmek_log_bucket_simple.sh --delete-kms
```

## Log Analytics Feature

When creating a log bucket, log analytics is **enabled by default**. This allows you to:
- Run SQL queries on your logs
- Create custom dashboards and reports
- Perform advanced log analysis

To disable log analytics, use the `--no-analytics` flag:
```bash
./setup_cmek_log_bucket.sh \
    --bucket-project my-project \
    --kms-project my-project \
    --bucket-id my-cmek-logs \
    --no-analytics
```

## Prerequisites

1. Google Cloud SDK (`gcloud`) installed and configured
2. `jq` command-line JSON processor
3. Appropriate IAM permissions:
   - `logging.buckets.create` and `logging.buckets.update`
   - `cloudkms.cryptoKeys.create` (if auto-creating KMS resources)
   - `cloudkms.cryptoKeys.setIamPolicy`
   - `logging.settings.get`

## Common Workflows

### 1. First-time Setup
```bash
# Create KMS resources and log bucket with analytics
./setup_cmek_log_bucket.sh \
    --bucket-project my-project \
    --kms-project my-project \
    --bucket-id my-cmek-logs \
    --auto-create-kms
```

### 2. Update Existing Bucket
```bash
# Enable analytics on existing bucket
./setup_cmek_log_bucket.sh \
    --bucket-project my-project \
    --kms-project my-project \
    --bucket-id my-existing-bucket
```

### 3. Complete Cleanup
```bash
# Remove everything including KMS resources
./teardown_cmek_log_bucket.sh \
    --bucket-project my-project \
    --kms-project my-project \
    --bucket-id my-cmek-logs \
    --delete-kms \
    --force
```

## Troubleshooting

### KMS Key Not Found Error
If you get an error that the KMS key doesn't exist:
1. Run `./create_kms_resources.sh` first, or
2. Use the `--auto-create-kms` flag with the setup script

### Service Account Not Found
The script will automatically trigger service account creation by writing a test log entry. If this fails:
1. Ensure the Cloud Logging API is enabled
2. Wait a few minutes for the service account to be created
3. Re-run the script

### Permission Errors
Ensure your user account has the necessary IAM roles:
- `roles/logging.admin` for log bucket operations
- `roles/cloudkms.admin` for KMS operations
- `roles/resourcemanager.projectIamAdmin` for IAM bindings

## Notes

- KMS keyrings cannot be deleted once created
- KMS keys have a 24-hour waiting period before permanent deletion
- APIs enabled by the scripts are not disabled during teardown
- Log analytics may incur additional costs based on usage
