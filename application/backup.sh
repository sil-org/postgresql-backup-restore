#!/usr/bin/env bash

# Determine script directory for reliable sourcing
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared library securely using absolute path
# shellcheck source=lib/shared.sh
if [[ ! -f "${SCRIPT_DIR}/lib/shared.sh" ]]; then
    echo "FATAL: Shared library not found at ${SCRIPT_DIR}/lib/shared.sh" >&2
    exit 1
fi
source "${SCRIPT_DIR}/lib/shared.sh"

STATUS=0

log "INFO" "backup: Started"
log "INFO" "Backing up ${DB_NAME}"

start=$(date +%s)
# Pipe output directly to gzip for streaming compression
PGPASSWORD="${DB_USERPASSWORD}" pg_dump --host="${DB_HOST}" --username="${DB_USER}" --create --clean ${DB_OPTIONS} --dbname="${DB_NAME}" | gzip > "/tmp/${DB_NAME}.sql.gz" || STATUS=${PIPESTATUS[0]}
end=$(date +%s)

# Setup AWS credentials with backward compatibility
setup_aws_credentials

if [[ $STATUS -ne 0 ]]; then
    fatal_error "Backup of ${DB_NAME} returned non-zero status ($STATUS) in $((end - start)) seconds." "${DB_NAME}" "$STATUS"
else
    log "INFO" "Backup of ${DB_NAME} completed in $((end - start)) seconds, ($(stat -c %s "/tmp/${DB_NAME}.sql.gz") bytes compressed)."
fi

log "INFO" "Generating checksum for backup file"
cd /tmp || fatal_error "Failed to change directory to /tmp" "${DB_NAME}" 1

# Create checksum file for compressed backup
sha256sum "${DB_NAME}.sql.gz" > "${DB_NAME}.sql.gz.sha256" || \
    fatal_error "Failed to generate checksum for backup of ${DB_NAME}" "${DB_NAME}" 1

log "DEBUG" "Checksum file contents: $(cat "${DB_NAME}.sql.gz.sha256")"

# Validate checksum
log "INFO" "Validating backup checksum"
sha256sum -c -s "${DB_NAME}.sql.gz.sha256" || \
    fatal_error "Checksum validation failed for backup of ${DB_NAME}" "${DB_NAME}" 1

log "INFO" "Checksum validation successful"

# Upload compressed backup file to S3
start=$(date +%s)
aws s3 cp --quiet "/tmp/${DB_NAME}.sql.gz" "${S3_BUCKET}/${DB_NAME}.sql.gz" || STATUS=$?
if [[ $STATUS -ne 0 ]]; then
    fatal_error "Copy backup to ${S3_BUCKET} of ${DB_NAME} returned non-zero status ($STATUS)." "${DB_NAME}" "$STATUS"
fi

# Upload checksum file
aws s3 cp --quiet "/tmp/${DB_NAME}.sql.gz.sha256" "${S3_BUCKET}/${DB_NAME}.sql.gz.sha256" || STATUS=$?
end=$(date +%s)
if [[ $STATUS -ne 0 ]]; then
    fatal_error "Copy checksum to ${S3_BUCKET} of ${DB_NAME} returned non-zero status ($STATUS)." "${DB_NAME}" "$STATUS"
else
    log "INFO" "Copy backup and checksum to ${S3_BUCKET} of ${DB_NAME} completed in $((end - start)) seconds."
fi

# Backblaze B2 Upload
if [[ -n "${B2_BUCKET:-}" ]]; then
    start=$(date +%s)
    AWS_ACCESS_KEY_ID="${B2_APPLICATION_KEY_ID}" \
    AWS_SECRET_ACCESS_KEY="${B2_APPLICATION_KEY}" \
    aws s3 cp --quiet "/tmp/${DB_NAME}.sql.gz" "s3://${B2_BUCKET}/${DB_NAME}.sql.gz" \
      --endpoint-url "https://${B2_HOST}" || STATUS=$?
    if [[ $STATUS -ne 0 ]]; then
        fatal_error "Copy backup to Backblaze B2 bucket ${B2_BUCKET} of ${DB_NAME} returned non-zero status ($STATUS)." "${DB_NAME}" "$STATUS"
    fi

    # Upload checksum file to B2
    AWS_ACCESS_KEY_ID="${B2_APPLICATION_KEY_ID}" \
    AWS_SECRET_ACCESS_KEY="${B2_APPLICATION_KEY}" \
    aws s3 cp --quiet "/tmp/${DB_NAME}.sql.gz.sha256" "s3://${B2_BUCKET}/${DB_NAME}.sql.gz.sha256" \
      --endpoint-url "https://${B2_HOST}" || STATUS=$?
    end=$(date +%s)
    if [[ $STATUS -ne 0 ]]; then
        fatal_error "Copy checksum to Backblaze B2 bucket ${B2_BUCKET} of ${DB_NAME} returned non-zero status ($STATUS)." "${DB_NAME}" "$STATUS"
    else
        log "INFO" "Copy backup and checksum to Backblaze B2 bucket ${B2_BUCKET} of ${DB_NAME} completed in $((end - start)) seconds."
    fi
fi

# Clean up temporary files
rm -f "/tmp/${DB_NAME}.sql.gz" "/tmp/${DB_NAME}.sql.gz.sha256"

log "INFO" "backup: Completed"

exit $STATUS
