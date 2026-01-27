#!/usr/bin/env bash
#
# Shared library for postgresql-backup-restore scripts
# This file should be sourced, not executed directly
#

# Prevent direct execution - this file must be sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "ERROR: This script must be sourced, not executed directly." >&2
    exit 1
fi

# Prevent multiple sourcing
if [[ -n "${_SHARED_LIB_LOADED:-}" ]]; then
    return 0
fi
readonly _SHARED_LIB_LOADED=1

# Application name constant
readonly MYNAME="postgresql-backup-restore"

# Initialize logging with timestamp
# Usage: log "INFO" "message"
log() {
    local level="$1"
    local message="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${MYNAME}: ${level}: ${message}"
}

# List of sensitive environment variables to filter from logs
readonly SENSITIVE_VARS=(
    AWS_ACCESS_KEY
    AWS_SECRET_KEY
    AWS_ACCESS_KEY_ID
    AWS_SECRET_ACCESS_KEY
    B2_APPLICATION_KEY
    B2_APPLICATION_KEY_ID
    DB_ROOTPASSWORD
    DB_USERPASSWORD
)

# Filter sensitive values from messages before logging/sending to external services
# Usage: filtered_msg=$(filter_sensitive_values "$message")
filter_sensitive_values() {
    local msg="$1"
    local var val

    for var in "${SENSITIVE_VARS[@]}"; do
        val="${!var:-}"
        if [[ -n "$val" ]]; then
            msg="${msg//$val/[FILTERED]}"
        fi
    done
    echo "$msg"
}

# Send error events to Sentry with proper validation
# Usage: error_to_sentry "error message" "database_name" "status_code"
error_to_sentry() {
    local error_message="$1"
    local db_name="$2"
    local status_code="$3"

    # Filter sensitive data from error message
    error_message=$(filter_sensitive_values "$error_message")

    # Check if SENTRY_DSN is configured
    if [[ -z "${SENTRY_DSN:-}" ]]; then
        log "DEBUG" "Sentry logging skipped - SENTRY_DSN not configured"
        return 0
    fi

    # Validate SENTRY_DSN format (https://key@host/project_id)
    if ! [[ "${SENTRY_DSN}" =~ ^https://[^@]+@[^/]+/[0-9]+$ ]]; then
        log "WARN" "Invalid SENTRY_DSN format - Sentry logging will be skipped"
        return 0
    fi

    # Attempt to send event to Sentry
    if sentry-cli send-event \
        --message "${MYNAME}: ${error_message}" \
        --level error \
        --tag "database:${db_name}" \
        --tag "status:${status_code}"; then
        log "DEBUG" "Successfully sent error to Sentry - Message: ${error_message}, Database: ${db_name}, Status: ${status_code}"
    else
        log "WARN" "Failed to send error to Sentry, but continuing process"
    fi

    return 0
}

# Setup AWS credentials with backward compatibility for s3cmd variable names
# Usage: setup_aws_credentials
setup_aws_credentials() {
    export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-$AWS_ACCESS_KEY}"
    export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-$AWS_SECRET_KEY}"
}

# Fatal error handler - logs, reports to Sentry, and exits
# Usage: fatal_error "error message" "database_name" "exit_code"
fatal_error() {
    local error_message="$1"
    local db_name="$2"
    local exit_code="${3:-1}"

    log "ERROR" "FATAL: ${error_message}"
    error_to_sentry "${error_message}" "${db_name}" "${exit_code}"
    exit "$exit_code"
}
