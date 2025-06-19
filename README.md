# GCP CMEK Setup and Error Reporting Demo

This repository contains scripts for:
1. Setting up Google Cloud Platform (GCP) folders with Customer-Managed Encryption Keys (CMEK) for Cloud Logging
2. Generating error log entries that follow the Error Reporting format

## Table of Contents
- [CMEK Setup Scripts](#cmek-setup-scripts)
- [Error Log Generator](#error-log-generator)

---

## CMEK Setup Scripts

### Main Script: `setup-gcp-folder-cmek.sh`

A comprehensive script that creates a GCP folder, test project, and configures CMEK for logging with robust error handling.

#### Features

- Creates a folder in your organization
- Automatically creates a test project within the folder (with unique ID generation)
- Enables Cloud KMS API with proper error handling
- Creates KMS keyring and key
- Configures log bucket with CMEK
- Sets up log sink for routing logs
- Includes retry logic for handling GCP's eventual consistency
- Graceful error handling for permission issues

#### Usage

```bash
./setup-gcp-folder-cmek.sh \
  --org-id YOUR_ORG_ID \
  --folder-name "Your Folder Name" \
  --log-bucket-name "your-log-bucket" \
  --billing-account-id YOUR_BILLING_ID
```

#### Optional Parameters

- `--location`: Location for resources (default: us)
- `--key-ring-name`: KMS key ring name (default: logging-cmek-keyring)
- `--key-name`: KMS key name (default: logging-cmek-key)

### Teardown Script: `teardown-gcp-folder-cmek.sh`

Cleans up resources created by the setup script.

#### Usage

```bash
./teardown-gcp-folder-cmek.sh \
  --folder-id FOLDER_ID \
  --project-id PROJECT_ID
```

---

## Error Log Generator

### Script: `generate_error_logs.py`

A Python program that generates various types of error log entries that follow the Google Cloud Error Reporting format. These errors will automatically appear in the Error Reporting console.

### Features

The script generates five different types of error log entries:

1. **Text Payload with Stack Trace**: Multi-line text containing a stack trace
2. **JSON Payload with Stack Trace**: JSON with `stack_trace` field
3. **Text Message Errors**: Simple error messages without stack traces (using special `@type`)
4. **ReportedErrorEvent Format**: Fully formatted error events with all context
5. **Custom JSON with Embedded Stack Trace**: Stack traces in nested JSON fields

**Note**: Logs are written to Cloud Logging and will be automatically routed to any configured log buckets based on your log sink configurations. The CMEK setup script creates a sink that routes logs to a CMEK-encrypted bucket.

### Installation

1. Install the required dependencies:
   ```bash
   pip install -r requirements.txt
   ```

2. Set up Google Cloud authentication:
   ```bash
   gcloud auth application-default login
   ```

### Usage

#### Generate mixed error types (default):
```bash
python generate_error_logs.py
```

#### Generate specific number of errors:
```bash
python generate_error_logs.py --count 20
```

#### Generate specific error type:
```bash
python generate_error_logs.py --type json --count 5
```

#### Specify project ID:
```bash
python generate_error_logs.py --project-id YOUR_PROJECT_ID
```

#### Add a prefix to all error messages:
```bash
python generate_error_logs.py --prefix "test1"
```

This will prepend "test1" to all error messages, for example:
- Text payload: `test1\nValueError: invalid literal for int() with base 10: 'not_a_number'`
- JSON message: `test1 Error occurred: division by zero`
- Simple message: `test1 Database connection timeout after 30 seconds`


### Command Line Options

- `--project-id`: Google Cloud Project ID (optional, uses default if not specified)
- `--count`: Number of error log entries to generate (default: 10)
- `--type`: Type of error to generate. Options:
  - `text`: Stack trace in textPayload
  - `json`: Stack trace in jsonPayload
  - `message`: Text message errors (no stack trace)
  - `reported`: ReportedErrorEvent format
  - `custom`: Custom JSON with embedded stack trace
  - `all`: Mix of all types (default)
- `--prefix`: String to prepend to all error messages (useful for filtering/grouping)

### Error Types Generated

#### 1. Python Exceptions with Stack Traces
- ZeroDivisionError
- IndexError
- KeyError
- ValueError
- TypeError

#### 2. Application Error Messages
- Database connection timeouts
- Authentication failures
- Payment processing errors
- API rate limit errors
- File upload failures
- Cache misses

#### 3. Simulated Service Errors
- NullPointerException (Java-style)
- SQLException
- TimeoutException

### Viewing the Errors

After running the script, you can view the generated errors in:

1. **Cloud Logging Console**: 
   ```
   https://console.cloud.google.com/logs
   ```
   Filter by `logName="projects/YOUR_PROJECT/logs/error-reporting-demo"`

2. **Error Reporting Console**: 
   ```
   https://console.cloud.google.com/errors
   ```
   Errors will be automatically grouped by Error Reporting

### Example Output

```
Generating 10 error log entries...
==================================================
Logged error with textPayload: division by zero
  [1/10] ✓ Error logged successfully
Logged ReportedErrorEvent format error for payment-service
  [2/10] ✓ Error logged successfully
Logged text message error: Database connection timeout after 30 seconds
  [3/10] ✓ Error logged successfully
...
==================================================
Finished generating 10 error log entries.

Check Google Cloud Console:
  - Logging: https://console.cloud.google.com/logs
  - Error Reporting: https://console.cloud.google.com/errors
```

---

## Requirements

### For CMEK Setup Scripts
- `gcloud` CLI installed and authenticated
- `jq` command-line JSON processor
- `openssl` for generating random suffixes
- Appropriate GCP permissions:
  - `resourcemanager.folders.create` on the organization
  - `resourcemanager.projects.create` on the folder
  - `billing.resourceAssociations.create` for billing
  - `cloudkms.keyRings.create` and related KMS permissions

### For Error Log Generator
- Python 3.6+
- `google-cloud-logging` library
- Appropriate GCP permissions:
  - `logging.logEntries.create` permission
  - Access to the target project

## Troubleshooting

### CMEK Setup Issues

1. **Authentication issues**:
   ```bash
   gcloud auth list
   gcloud config get-value account
   ```

2. **Permission verification**:
   ```bash
   gcloud organizations get-iam-policy YOUR_ORG_ID
   gcloud resource-manager folders get-iam-policy FOLDER_ID
   ```

### Error Log Generator Issues

1. **Authentication errors**:
   ```bash
   gcloud auth application-default login
   ```

2. **Missing permissions**:
   Ensure your account has the `Logs Writer` role:
   ```bash
   gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
     --member="user:YOUR_EMAIL" \
     --role="roles/logging.logWriter"
   ```

3. **Errors not appearing in Error Reporting**:
   - Ensure the severity is set to ERROR or higher
   - Check that the log entries follow the correct format
   - Wait a few minutes for errors to appear (there can be a delay)

## Notes

- The CMEK setup script is idempotent - it checks for existing resources before creating new ones
- Error log entries may take a few minutes to appear in Error Reporting
- Stack traces must follow supported language formats to be properly parsed
- The `@type` field is required for text messages without stack traces
