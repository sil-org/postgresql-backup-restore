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
log "INFO" "restore: Started"

# Ensure the database user exists.
log "INFO" "checking for DB user ${DB_USER}"
result=$(psql --host="${DB_HOST}" --username="${DB_ROOTUSER}" --command='\du' | grep "${DB_USER}")
if [[ -z "${result}" ]]; then
    result=$(psql --host="${DB_HOST}" --username="${DB_ROOTUSER}" --command="create role ${DB_USER} with login password '${DB_USERPASSWORD}' inherit;")
    if [[ "${result}" != "CREATE ROLE" ]]; then
        fatal_error "Create role command failed: ${result}" "${DB_NAME}" 1
    fi
fi

# Delete database if it exists.
log "INFO" "checking for DB ${DB_NAME}"
result=$(psql --host="${DB_HOST}" --username="${DB_ROOTUSER}" --list | grep "${DB_NAME}")
if [[ -z "${result}" ]]; then
    log "INFO" "Database \"${DB_NAME}\" on host \"${DB_HOST}\" does not exist."
else
    log "INFO" "finding current owner of DB ${DB_NAME}"
    db_owner=$(psql --host="${DB_HOST}" --username="${DB_ROOTUSER}" --command='\list' | grep "${DB_NAME}" | cut -d '|' -f 2 | sed -e 's/ *//g')
    log "INFO" "Database owner is ${db_owner}"

    log "INFO" "deleting database ${DB_NAME}"
    result=$(psql --host="${DB_HOST}" --dbname=postgres --username="${db_owner}" --command="DROP DATABASE ${DB_NAME};")
    if [[ "${result}" != "DROP DATABASE" ]]; then
        fatal_error "Drop database command failed: ${result}" "${DB_NAME}" 1
    fi
fi

# Download the backup and checksum files
log "INFO" "copying database ${DB_NAME} backup and checksum from ${S3_BUCKET}"
start=$(date +%s)

# Setup AWS credentials with backward compatibility
setup_aws_credentials

# Download database backup
aws s3 cp --quiet "${S3_BUCKET}/${DB_NAME}.sql.gz" "/tmp/${DB_NAME}.sql.gz" || STATUS=$?
if [[ $STATUS -ne 0 ]]; then
    fatal_error "Copy backup of ${DB_NAME} from ${S3_BUCKET} returned non-zero status ($STATUS) in $(($(date +%s) - start)) seconds." "${DB_NAME}" "$STATUS"
fi

# Download checksum file
aws s3 cp --quiet "${S3_BUCKET}/${DB_NAME}.sql.gz.sha256" "/tmp/${DB_NAME}.sql.gz.sha256" || STATUS=$?
end=$(date +%s)
if [[ $STATUS -ne 0 ]]; then
    fatal_error "Copy checksum of ${DB_NAME} from ${S3_BUCKET} returned non-zero status ($STATUS) in $((end - start)) seconds." "${DB_NAME}" "$STATUS"
else
    log "INFO" "Copy backup and checksum of ${DB_NAME} from ${S3_BUCKET} completed in $((end - start)) seconds."
fi

# Validate the checksum of compressed backup before decompression
log "INFO" "Validating backup integrity with checksum"
cd /tmp || fatal_error "Failed to change directory to /tmp" "${DB_NAME}" 1

sha256sum -c -s "${DB_NAME}.sql.gz.sha256" || \
    fatal_error "Checksum validation failed for backup of ${DB_NAME}. The backup may be corrupted or tampered with." "${DB_NAME}" 1

log "INFO" "Checksum validation successful - backup integrity confirmed"

# Decompress backup file
log "INFO" "decompressing backup of ${DB_NAME}"
start=$(date +%s)
gunzip -f "/tmp/${DB_NAME}.sql.gz" || STATUS=$?
end=$(date +%s)
if [[ $STATUS -ne 0 ]]; then
    fatal_error "Decompressing backup of ${DB_NAME} returned non-zero status ($STATUS) in $((end - start)) seconds." "${DB_NAME}" "$STATUS"
else
    log "INFO" "Decompressing backup of ${DB_NAME} completed in $((end - start)) seconds."
fi

# Restore the database
log "INFO" "restoring ${DB_NAME}"
start=$(date +%s)
psql --host="${DB_HOST}" --username="${DB_ROOTUSER}" --dbname=postgres ${DB_OPTIONS} < "/tmp/${DB_NAME}.sql" || STATUS=$?
end=$(date +%s)

if [[ $STATUS -ne 0 ]]; then
    fatal_error "Restore of ${DB_NAME} returned non-zero status ($STATUS) in $((end - start)) seconds." "${DB_NAME}" "$STATUS"
else
    log "INFO" "Restore of ${DB_NAME} completed in $((end - start)) seconds."
fi

# Verify database restore success
log "INFO" "Verifying database restore success"
result=$(psql --host="${DB_HOST}" --username="${DB_ROOTUSER}" --list | grep "${DB_NAME}")
if [[ -z "${result}" ]]; then
    fatal_error "Database ${DB_NAME} not found after restore attempt." "${DB_NAME}" 1
else
    log "INFO" "Database ${DB_NAME} successfully restored and verified."
fi

# Clean up temporary files
rm -f "/tmp/${DB_NAME}.sql" "/tmp/${DB_NAME}.sql.gz.sha256"
log "INFO" "Temporary files cleaned up"

log "INFO" "restore: Completed"
exit $STATUS
