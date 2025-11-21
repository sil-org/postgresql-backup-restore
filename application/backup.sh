#!/usr/bin/env bash

# Initialize logging with timestamp
log() {
    local level="$1";
    local message="$2";
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${level}: ${message}";
}

# Function to remove sensitive values from sentry Event
filter_sensitive_values() {
    local msg="$1"
    for var in AWS_ACCESS_KEY AWS_SECRET_KEY B2_APPLICATION_KEY B2_APPLICATION_KEY_ID DB_ROOTPASSWORD DB_USERPASSWORD; do
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
        --message "${error_message}" \
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

log "INFO" "${MYNAME}: backup: Started";
log "INFO" "${MYNAME}: Backing up ${DB_NAME}";

start=$(date +%s);
$(PGPASSWORD=${DB_USERPASSWORD} pg_dump --host=${DB_HOST} --username=${DB_USER} --create --clean ${DB_OPTIONS} --dbname=${DB_NAME} > /tmp/${DB_NAME}.sql) || STATUS=$?;
end=$(date +%s);

if [ $STATUS -ne 0 ]; then
    error_message="${MYNAME}: FATAL: Backup of ${DB_NAME} returned non-zero status ($STATUS) in $(expr ${end} - ${start}) seconds.";
    log "ERROR" "${error_message}";
    error_to_sentry "${error_message}" "${DB_NAME}" "${STATUS}";
    exit $STATUS;
else
    log "INFO" "${MYNAME}: Backup of ${DB_NAME} completed in $(expr ${end} - ${start}) seconds, ($(stat -c %s /tmp/${DB_NAME}.sql) bytes).";
fi

log "INFO" "Generating checksum for backup file"
cd /tmp || {
    error_message="${MYNAME}: FATAL: Failed to change directory to /tmp";
    log "ERROR" "${error_message}";
    error_to_sentry "${error_message}" "${DB_NAME}" "1";
    exit 1;
}

# Create checksum file format
sha256sum "${DB_NAME}.sql" > "${DB_NAME}.sql.sha256" || {
    error_message="${MYNAME}: FATAL: Failed to generate checksum for backup of ${DB_NAME}";
    log "ERROR" "${error_message}";
    error_to_sentry "${error_message}" "${DB_NAME}" "1";
    exit 1;
}
log "DEBUG" "Checksum file contents: $(cat "${DB_NAME}.sql.sha256")";

# Validate checksum
log "INFO" "${MYNAME}: Validating backup checksum";
sha256sum -c "${DB_NAME}.sql.sha256" || {
    error_message="${MYNAME}: FATAL: Checksum validation failed for backup of ${DB_NAME}";
    log "ERROR" "${error_message}";
    error_to_sentry "${error_message}" "${DB_NAME}" "1";
    exit 1;
}
log "INFO" "${MYNAME}: Checksum validation successful";

# Compression
start=$(date +%s);
gzip -f /tmp/${DB_NAME}.sql || STATUS=$?;
end=$(date +%s);

if [ $STATUS -ne 0 ]; then
    error_message="${MYNAME}: FATAL: Compressing backup of ${DB_NAME} returned non-zero status ($STATUS) in $(expr ${end} - ${start}) seconds.";
    log "ERROR" "${error_message}";
    error_to_sentry "${error_message}" "${DB_NAME}" "${STATUS}";
    exit $STATUS;
else
    log "INFO" "${MYNAME}: Compressing backup of ${DB_NAME} completed in $(expr ${end} - ${start}) seconds.";
fi

# Compress checksum file
gzip -f "${DB_NAME}.sql.sha256";
if [ $? -ne 0 ]; then
    log "WARN" "${MYNAME}: Failed to compress checksum file, but continuing backup process";
fi

# Upload compressed backup file to S3
start=$(date +%s);
aws s3 cp "/tmp/${DB_NAME}.sql.gz" "s3://${S3_BUCKET}/${DB_NAME}.sql.gz" || STATUS=$
if [ $STATUS -ne 0 ]; then
    error_message="${MYNAME}: FATAL: Copy backup to ${S3_BUCKET} of ${DB_NAME} returned non-zero status ($STATUS) in $(expr ${end} - ${start}) seconds.";
    log "ERROR" "${error_message}";
    error_to_sentry "${error_message}" "${DB_NAME}" "${STATUS}";
    exit $STATUS;
fi

# Upload checksum file
aws s3 cp "/tmp/${DB_NAME}.sql.sha256.gz" "s3://${S3_BUCKET}/${DB_NAME}.sql.sha256.gz" || STATUS=$?;
end=$(date +%s);
if [ $STATUS -ne 0 ]; then
    error_message="${MYNAME}: FATAL: Copy checksum to ${S3_BUCKET} of ${DB_NAME} returned non-zero status ($STATUS).";
    log "ERROR" "${error_message}";
    error_to_sentry "${error_message}" "${DB_NAME}" "${STATUS}";
    exit $STATUS;
else
    log "INFO" "${MYNAME}: Copy backup and checksum to ${S3_BUCKET} of ${DB_NAME} completed in $(expr ${end} - ${start}) seconds.";
fi

# Backblaze B2 Upload
if [ "${B2_BUCKET}" != "" ]; then
    start=$(date +%s);
    AWS_ACCESS_KEY_ID="${B2_APPLICATION_KEY_ID}" \
    AWS_SECRET_ACCESS_KEY="${B2_APPLICATION_KEY}" \
    aws s3 cp "/tmp/${DB_NAME}.sql.gz" "s3://${B2_BUCKET}/${DB_NAME}.sql.gz" \
      --endpoint-url "https://${B2_HOST}"
    STATUS=$?;
    end=$(date +%s);
    if [ $STATUS -ne 0 ]; then
        error_message="${MYNAME}: FATAL: Copy backup to Backblaze B2 bucket ${B2_BUCKET} of ${DB_NAME} returned non-zero status ($STATUS) in $(expr ${end} - ${start}) seconds.";
        log "ERROR" "${error_message}";
        error_to_sentry "${error_message}" "${DB_NAME}" "${STATUS}";
        exit $STATUS;
    else
        log "INFO" "${MYNAME}: Copy backup to Backblaze B2 bucket ${B2_BUCKET} of ${DB_NAME} completed in $(expr ${end} - ${start}) seconds.";
    fi
fi

echo "postgresql-backup-restore: backup: Completed";

# Clean up temporary files
rm -f "/tmp/${DB_NAME}.sql.gz" "/tmp/${DB_NAME}.sql.sha256.gz";

log "INFO" "${MYNAME}: backup: Completed";

exit $STATUS;
