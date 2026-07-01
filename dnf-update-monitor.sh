#!/bin/bash
# Source      : https://github.com/nocturnalismee/dnf-update-monitor
# Version     : 1.1
# License     : MIT
# Description : This bash script is for checking updates via dnf and can send messages to telegram after checking.

set -uo pipefail

# CONFIGURATION
readonly BOT_TOKEN="" # BOT TOKEN TELEGRAM
readonly CHAT_ID=""   # CHAT ID TELEGRAM
readonly THREAD_ID="" # Leave empty if not using a group thread/topic

readonly LOG_DIR="" # Log directory update, example /tmp/dnf-update-checker
readonly LOG_RETENTION_DAYS=30 # Delete logs older than N days (0 = disabled)

# INITIALIZATION
HOSTNAME=$(hostname)
START_TIME=$(date '+%Y-%m-%d %H:%M:%S')
LOG_FILE="${LOG_DIR}/update-$(date +%F-%H%M%S).log"

mkdir -p "$LOG_DIR"
# Logging
log() {
    echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Validate configuration
validate_config() {
    local errors=0

    if [[ -z "$BOT_TOKEN" ]]; then
        echo "ERROR: BOT_TOKEN is empty." >&2
        errors=$((errors + 1))
    fi
    if [[ -z "$CHAT_ID" ]]; then
        echo "ERROR: CHAT_ID is empty." >&2
        errors=$((errors + 1))
    fi

    if (( errors > 0 )); then
        exit 1
    fi
}

# Send Telegram notification
send_telegram() {
    local message="$1"
    local max_length=4000
    local retries=3
    local delay=5

    if (( ${#message} > max_length )); then
        message="${message:0:$max_length}"$'\n\n<i>... [message truncated]</i>'
    fi

    local curl_args=(
        -s
        --max-time 15
        --retry "$retries"
        --retry-delay "$delay"
        -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"
        --data-urlencode "chat_id=${CHAT_ID}"
        --data-urlencode "text=${message}"
        --data-urlencode "parse_mode=HTML"
        --data-urlencode "disable_web_page_preview=true"
    )

    if [[ -n "$THREAD_ID" ]]; then
        curl_args+=(--data-urlencode "message_thread_id=${THREAD_ID}")
    fi

    local http_code
    http_code=$(curl "${curl_args[@]}" -o /dev/null -w "%{http_code}")

    if [[ "$http_code" != "200" ]]; then
        echo "WARNING: Failed to send Telegram notification (HTTP ${http_code})" >&2
        return 1
    fi

    return 0
}

# Rotate / delete old logs
rotate_logs() {
    if (( LOG_RETENTION_DAYS > 0 )); then
        find "$LOG_DIR" -name "update-*.log" \
            -mtime +"$LOG_RETENTION_DAYS" \
            -delete 2>/dev/null || true
        log "Logs older than ${LOG_RETENTION_DAYS} days have been deleted."
    fi
}

# Extract package summary from dnf log
get_package_summary() {
    local logfile="$1"
    local summary

    # Extract the 'Transaction Summary' section (Install / Upgrade / Remove etc.) neatly
    summary=$(grep -A 5 -i "Transaction Summary" "$logfile" | grep -E -i "(Install|Upgrade|Remove|Downgrade)" | sed 's/^[ \t]*//')

    if [[ -z "$summary" ]]; then
        # If parsing fails, provide a neat message instead of dumping raw logs
        summary="Please check the log file for package details."
    fi

    echo "${summary}"
}

# Check if a reboot is required after the update
check_reboot_required() {
    if ! command -v needs-restarting &>/dev/null; then
        echo "Unable to check (needs-restarting not available)"
        return
    fi

    if needs-restarting -r &>/dev/null; then
        echo "Not required"
    else
        # Extract the details of packages requiring a reboot and format as a comma-separated string
        local details
        details=$(needs-restarting -r 2>&1 | awk '/^\s+\*/ {print $2}' | paste -sd, - | sed 's/,/, /g')

        if [[ -n "$details" ]]; then
            echo "REQUIRED (${details})"
        else
            echo "REQUIRED"
        fi
    fi
}

# MAIN
main() {
    validate_config
    rotate_logs

    log "---------------------------------------------"
    log "  DNF Auto Update - ${START_TIME}"
    log "  Host: ${HOSTNAME}"
    log "---------------------------------------------"

    # STEP 1 — CHECK FOR UPDATES
    # dnf check-update: 0 = no updates, 100 = updates available, other = error
    log "STEP 1/2 - Checking for available updates..."

    dnf check-update -q >> "$LOG_FILE" 2>&1
    local check_status=$?

    if (( check_status == 0 )); then
        log "No updates available. Finished."

        send_telegram "✅ <b>${HOSTNAME} - DNF UPDATE REPORT</b>
<pre>
Time      : ${START_TIME}

Status    : No updates available.

Log       : ${LOG_FILE}
</pre>"

        exit 0

    elif (( check_status != 100 )); then
        log "ERROR: Failed to run 'dnf check-update' (exit code: ${check_status})."

        send_telegram "⚠️ <b>${HOSTNAME} - DNF CHECK UPDATE ERROR</b>
<pre>
Time      : ${START_TIME}

Exit Code : ${check_status}

Log       : ${LOG_FILE}
</pre>"

        exit 1
    fi

    # STEP 2 — RUN UPDATE
    log "STEP 2/2 - Updates available. Starting the update process..."

    dnf -y update >> "$LOG_FILE" 2>&1
    local update_status=$?

    local end_time
    end_time=$(date '+%Y-%m-%d %H:%M:%S')

    # UPDATE SUCCESSFUL
    if (( update_status == 0 )); then
        local pkg_summary
        pkg_summary=$(get_package_summary "$LOG_FILE")

        local reboot_status
        reboot_status=$(check_reboot_required)
        log "Reboot check: ${reboot_status}"

        log "Update completed successfully."

        send_telegram "✅<b>${HOSTNAME} - DNF UPDATE SUCCESSFUL</b>
<pre>
Started   : ${START_TIME}
Finished  : ${end_time}

Package Summary:
${pkg_summary}

Reboot    : ${reboot_status}

Log       : ${LOG_FILE}
</pre>"

    # UPDATE FAILED
    else
        local error_tail
        error_tail=$(tail -n 20 "$LOG_FILE")

        log "ERROR: Update failed (exit code: ${update_status})."

        send_telegram "❌ <b>${HOSTNAME} - DNF UPDATE FAILED</b>
<pre>
Started   : ${START_TIME}
Finished  : ${end_time}
Exit Code : ${update_status}

Last Log Output:
${error_tail}

Log       : ${LOG_FILE}
</pre>"

        exit 1
    fi
}

main "$@"
