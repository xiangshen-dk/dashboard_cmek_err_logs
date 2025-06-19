#!/bin/bash

# Simple wrapper script for backward compatibility
# This script uses the hardcoded values from the original setup script

./teardown_cmek_log_bucket.sh \
    --bucket-project "shenxiang-gcp-solution" \
    --kms-project "shenxiang-gcp-solution" \
    --bucket-id "shenxiang-gcp-solution-cmek-err-rpt-test4" \
    --location "us" \
    --key-ring "logging-cmek-keyring" \
    --key-name "logging-cmek-key" \
    "$@"
