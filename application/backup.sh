#!/usr/bin/env bash

# Initialize logging with timestamp
log() {
    local level="$1";
    local message="$2";
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${MYNAME}: ${level}: ${message}";
}

# Function to remove sensitive values from sentry Event
filter_sensitive_values() {
    local msg="$1"
    for var in AWS_ACCESS_KEY AWS_SECRET_KEY AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY B2_APPLICATION_KEY B2_APPLICATION_KEY_ID DB_ROOTPASSWORD DB_USERPASSWORD; do
        val="${!var}"
        if [ -n "$val" ]; then
            msg="${msg//$val/[FILTERED]}"
        fi
    done
    echo "$msg"
}

# Sentry reporting with validation and backwards compatibility
error_to_sentry() {
    local error_message="$1";
    local db_name="$2";
    local status_code="$3";

    error_message=$(filter_sensitive_values "$error_message")

    # Check if SENTRY_DSN is configured - ensures backup continues
    if [ -z "${SENTRY_DSN:-}" ]; then
        log "DEBUG" "Sentry logging skipped - SENTRY_DSN not configured";
        return 0;
    fi

    # Validate SENTRY_DSN format
    if ! [[ "${SENTRY_DSN}" =~ ^https://[^@]+@[^/]+/[0-9]+$ ]]; then
        log "WARN" "Invalid SENTRY_DSN format - Sentry logging will be skipped";
        return 0;
    fi

    # Attempt to send event to Sentry
    if sentry-cli send-event \
        --message "${MYNAME}: ${error_message}" \
        --level error \
        --tag "database:${db_name}" \
        --tag "status:${status_code}"; then
        log "DEBUG" "Successfully sent error to Sentry - Message: ${error_message}, Database: ${db_name}, Status: ${status_code}";
    else
        log "WARN" "Failed to send error to Sentry, but continuing backup process";
    fi

    return 0;
}

MYNAME="postgresql-backup-restore";
STATUS=0;

log "INFO" "backup: Started";
log "INFO" "Backing up ${DB_NAME}";

start=$(date +%s);
# Pipe output directly to gzip for streaming compression
PGPASSWORD=${DB_USERPASSWORD} pg_dump --host=${DB_HOST} --username=${DB_USER} --create --clean ${DB_OPTIONS} --dbname=${DB_NAME} | gzip > /tmp/${DB_NAME}.sql.gz || STATUS=${PIPESTATUS[0]};
end=$(date +%s);

# maintain backward compatibility with key variables accepted by s3cmd
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-$AWS_ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-$AWS_SECRET_KEY}"

if [ $STATUS -ne 0 ]; then
    error_message="FATAL: Backup of ${DB_NAME} returned non-zero status ($STATUS) in $(expr ${end} - ${start}) seconds.";
    log "ERROR" "${error_message}";
    error_to_sentry "${error_message}" "${DB_NAME}" "${STATUS}";
    exit $STATUS;
else
    log "INFO" "Backup of ${DB_NAME} completed in $(expr ${end} - ${start}) seconds, ($(stat -c %s /tmp/${DB_NAME}.sql.gz) bytes compressed).";
fi

log "INFO" "Generating checksum for backup file"
cd /tmp || {
    error_message="FATAL: Failed to change directory to /tmp";
    log "ERROR" "${error_message}";
    error_to_sentry "${error_message}" "${DB_NAME}" "1";
    exit 1;
}

# Create checksum file for compressed backup
sha256sum "${DB_NAME}.sql.gz" > "${DB_NAME}.sql.gz.sha256" || {
    error_message="FATAL: Failed to generate checksum for backup of ${DB_NAME}";
    log "ERROR" "${error_message}";
    error_to_sentry "${error_message}" "${DB_NAME}" "1";
    exit 1;
}
log "DEBUG" "Checksum file contents: $(cat "${DB_NAME}.sql.gz.sha256")";

# Validate checksum
log "INFO" "Validating backup checksum";
sha256sum -c -s "${DB_NAME}.sql.gz.sha256" || {
    error_message="FATAL: Checksum validation failed for backup of ${DB_NAME}";
    log "ERROR" "${error_message}";
    error_to_sentry "${error_message}" "${DB_NAME}" "1";
    exit 1;
}
log "INFO" "Checksum validation successful";

# Upload compressed backup file to S3
start=$(date +%s);
aws s3 cp --quiet "/tmp/${DB_NAME}.sql.gz" "${S3_BUCKET}/${DB_NAME}.sql.gz" || STATUS=$?
if [ $STATUS -ne 0 ]; then
    error_message="FATAL: Copy backup to ${S3_BUCKET} of ${DB_NAME} returned non-zero status ($STATUS) in $(expr ${end} - ${start}) seconds.";
    log "ERROR" "${error_message}";
    error_to_sentry "${error_message}" "${DB_NAME}" "${STATUS}";
    exit $STATUS;
fi

# Upload checksum file
aws s3 cp --quiet "/tmp/${DB_NAME}.sql.gz.sha256" "${S3_BUCKET}/${DB_NAME}.sql.gz.sha256" || STATUS=$?;
end=$(date +%s);
if [ $STATUS -ne 0 ]; then
    error_message="FATAL: Copy checksum to ${S3_BUCKET} of ${DB_NAME} returned non-zero status ($STATUS).";
    log "ERROR" "${error_message}";
    error_to_sentry "${error_message}" "${DB_NAME}" "${STATUS}";
    exit $STATUS;
else
    log "INFO" "Copy backup and checksum to ${S3_BUCKET} of ${DB_NAME} completed in $(expr ${end} - ${start}) seconds.";
fi

# Backblaze B2 Upload
if [ "${B2_BUCKET}" != "" ]; then
    start=$(date +%s);
    AWS_ACCESS_KEY_ID="${B2_APPLICATION_KEY_ID}" \
    AWS_SECRET_ACCESS_KEY="${B2_APPLICATION_KEY}" \
    aws s3 cp --quiet "/tmp/${DB_NAME}.sql.gz" "s3://${B2_BUCKET}/${DB_NAME}.sql.gz" \
      --endpoint-url "https://${B2_HOST}"
    STATUS=$?;
    end=$(date +%s);
    if [ $STATUS -ne 0 ]; then
        error_message="FATAL: Copy backup to Backblaze B2 bucket ${B2_BUCKET} of ${DB_NAME} returned non-zero status ($STATUS) in $(expr ${end} - ${start}) seconds.";
        log "ERROR" "${error_message}";
        error_to_sentry "${error_message}" "${DB_NAME}" "${STATUS}";
        exit $STATUS;
    else
        log "INFO" "Copy backup to Backblaze B2 bucket ${B2_BUCKET} of ${DB_NAME} completed in $(expr ${end} - ${start}) seconds.";
    fi
fi

# Clean up temporary files
rm -f "/tmp/${DB_NAME}.sql.gz" "/tmp/${DB_NAME}.sql.gz.sha256";

log "INFO" "backup: Completed";

exit $STATUS;
