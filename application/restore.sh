#!/usr/bin/env sh

# Initialize logging with timestamp
log() {
    local level="$1"
    local message="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${level}: ${message}"
}

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
    local error_message="$1"
    local db_name="$2"
    local status_code="$3"

    error_message=$(filter_sensitive_values "$error_message")

    # Check if SENTRY_DSN is configured - ensures restore continues
    if [ -z "${SENTRY_DSN:-}" ]; then
        log "DEBUG" "Sentry logging skipped - SENTRY_DSN not configured"
        return 0
    fi

    # Validate SENTRY_DSN format
    echo "${SENTRY_DSN}" | grep -E "^https://[^@]+@[^/]+/[0-9]+$" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        log "WARN" "Invalid SENTRY_DSN format - Sentry logging will be skipped"
        return 0
    fi

    # Attempt to send event to Sentry
    if sentry-cli send-event \
        --message "${error_message}" \
        --level error \
        --tag "database:${db_name}" \
        --tag "status:${status_code}"; then
        log "DEBUG" "Successfully sent error to Sentry - Message: ${error_message}, Database: ${db_name}, Status: ${status_code}"
    else
        log "WARN" "Failed to send error to Sentry, but continuing restore process"
    fi

    return 0
}

MYNAME="postgresql-backup-restore"
STATUS=0
log "INFO" "${MYNAME}: restore: Started"

# Ensure the database user exists.
log "INFO" "${MYNAME}: checking for DB user ${DB_USER}"
result=$(psql --host=${DB_HOST} --username=${DB_ROOTUSER} --command='\du' | grep ${DB_USER})
if [ -z "${result}" ]; then
    result=$(psql --host=${DB_HOST} --username=${DB_ROOTUSER} --command="create role ${DB_USER} with login password '${DB_USERPASSWORD}' inherit;")
    if [ "${result}" != "CREATE ROLE" ]; then
        error_message="Create role command failed: ${result}"
        log "ERROR" "${MYNAME}: FATAL: ${error_message}"
        error_to_sentry "${error_message}" "${DB_NAME}" "1"
        exit 1
    fi
fi

# Delete database if it exists.
log "INFO" "${MYNAME}: checking for DB ${DB_NAME}"
result=$(psql --host=${DB_HOST} --username=${DB_ROOTUSER} --list | grep ${DB_NAME})
if [ -z "${result}" ]; then
    log "INFO" "${MYNAME}: INFO: Database \"${DB_NAME}\" on host \"${DB_HOST}\" does not exist."
else
    log "INFO" "${MYNAME}: finding current owner of DB ${DB_NAME}"
    db_owner=$(psql --host=${DB_HOST} --username=${DB_ROOTUSER} --command='\list' | grep ${DB_NAME} | cut -d '|' -f 2 | sed -e 's/ *//g')
    log "INFO" "${MYNAME}: INFO: Database owner is ${db_owner}"

    log "INFO" "${MYNAME}: deleting database ${DB_NAME}"
    result=$(psql --host=${DB_HOST} --dbname=postgres --username=${db_owner} --command="DROP DATABASE ${DB_NAME};")
    if [ "${result}" != "DROP DATABASE" ]; then
        error_message="Drop database command failed: ${result}"
        log "ERROR" "${MYNAME}: FATAL: ${error_message}"
        error_to_sentry "${error_message}" "${DB_NAME}" "1"
        exit 1
    fi
fi

# Download the backup and checksum files
log "INFO" "${MYNAME}: copying database ${DB_NAME} backup and checksum from ${S3_BUCKET}"
start=$(date +%s)

# Download database backup
aws s3 cp "${S3_BUCKET}/${DB_NAME}.sql.gz" "/tmp/${DB_NAME}.sql.gz" || STATUS=$?
if [ $STATUS -ne 0 ]; then
    error_message="${MYNAME}: FATAL: Copy backup of ${DB_NAME} from ${S3_BUCKET} returned non-zero status ($STATUS) in $(expr $(date +%s) - ${start}) seconds."
    log "ERROR" "${error_message}"
    error_to_sentry "${error_message}" "${DB_NAME}" "${STATUS}"
    exit $STATUS
fi

# Download checksum file
aws s3 cp "${S3_BUCKET}/${DB_NAME}.sql.sha256.gz" "/tmp/${DB_NAME}.sql.sha256.gz" || STATUS=$?
end=$(date +%s)
if [ $STATUS -ne 0 ]; then
    error_message="${MYNAME}: FATAL: Copy checksum of ${DB_NAME} from ${S3_BUCKET} returned non-zero status ($STATUS) in $(expr ${end} - ${start}) seconds."
    log "ERROR" "${error_message}"
    error_to_sentry "${error_message}" "${DB_NAME}" "${STATUS}"
    exit $STATUS
else
    log "INFO" "${MYNAME}: Copy backup and checksum of ${DB_NAME} from ${S3_BUCKET} completed in $(expr ${end} - ${start}) seconds."
fi

# Decompress both files
log "INFO" "${MYNAME}: decompressing backup and checksum of ${DB_NAME}"
start=$(date +%s)

# Decompress backup file
gunzip -f /tmp/${DB_NAME}.sql.gz || STATUS=$?
if [ $STATUS -ne 0 ]; then
    error_message="${MYNAME}: FATAL: Decompressing backup of ${DB_NAME} returned non-zero status ($STATUS) in $(expr $(date +%s) - ${start}) seconds."
    log "ERROR" "${error_message}"
    error_to_sentry "${error_message}" "${DB_NAME}" "${STATUS}"
    exit $STATUS
fi

# Decompress checksum file
gunzip -f /tmp/${DB_NAME}.sql.sha256.gz || STATUS=$?
end=$(date +%s)
if [ $STATUS -ne 0 ]; then
    error_message="${MYNAME}: FATAL: Decompressing checksum of ${DB_NAME} returned non-zero status ($STATUS) in $(expr ${end} - ${start}) seconds."
    log "ERROR" "${error_message}"
    error_to_sentry "${error_message}" "${DB_NAME}" "${STATUS}"
    exit $STATUS
else
    log "INFO" "${MYNAME}: Decompressing backup and checksum of ${DB_NAME} completed in $(expr ${end} - ${start}) seconds."
fi

# Validate the checksum
log "INFO" "${MYNAME}: Validating backup integrity with checksum"
cd /tmp || {
    error_message="${MYNAME}: FATAL: Failed to change directory to /tmp"
    log "ERROR" "${error_message}"
    error_to_sentry "${error_message}" "${DB_NAME}" "1"
    exit 1
}

sha256sum -c "${DB_NAME}.sql.sha256" || {
    error_message="${MYNAME}: FATAL: Checksum validation failed for backup of ${DB_NAME}. The backup may be corrupted or tampered with."
    log "ERROR" "${error_message}"
    error_to_sentry "${error_message}" "${DB_NAME}" "1"
    exit 1
}
log "INFO" "${MYNAME}: Checksum validation successful - backup integrity confirmed"

# Restore the database
log "INFO" "${MYNAME}: restoring ${DB_NAME}"
start=$(date +%s)
psql --host=${DB_HOST} --username=${DB_ROOTUSER} --dbname=postgres ${DB_OPTIONS} < /tmp/${DB_NAME}.sql || STATUS=$?
end=$(date +%s)

if [ $STATUS -ne 0 ]; then
    error_message="${MYNAME}: FATAL: Restore of ${DB_NAME} returned non-zero status ($STATUS) in $(expr ${end} - ${start}) seconds."
    log "ERROR" "${error_message}"
    error_to_sentry "${error_message}" "${DB_NAME}" "${STATUS}"
    exit $STATUS
else
    log "INFO" "${MYNAME}: Restore of ${DB_NAME} completed in $(expr ${end} - ${start}) seconds."
fi

# Verify database restore success
log "INFO" "${MYNAME}: Verifying database restore success"
result=$(psql --host=${DB_HOST} --username=${DB_ROOTUSER} --list | grep ${DB_NAME})
if [ -z "${result}" ]; then
    error_message="${MYNAME}: FATAL: Database ${DB_NAME} not found after restore attempt."
    log "ERROR" "${error_message}"
    error_to_sentry "${error_message}" "${DB_NAME}" "1"
    exit 1
else
    log "INFO" "${MYNAME}: Database ${DB_NAME} successfully restored and verified."
fi

# Clean up temporary files
rm -f "/tmp/${DB_NAME}.sql" "/tmp/${DB_NAME}.sql.sha256"
log "INFO" "${MYNAME}: Temporary files cleaned up"

log "INFO" "${MYNAME}: restore: Completed"
exit $STATUS
