#!/usr/bin/env bash
# ============================================================
# log-analyzer.sh
# Description : Detects anomalous patterns in journald logs:
#               crash/OOM events, authentication failures,
#               service restarts, segfaults, and sudden log
#               volume spikes. Results are summarised by unit.
# Dependencies: journalctl, awk
# Compatibility: Any systemd Linux
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

# Lookback window in hours (default: last 24h)
HOURS=24
# Threshold: how many occurrences of a pattern to flag as anomalous
SPIKE_THRESHOLD=10

# --- Parse args ---
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --hours|-H)
                HOURS="${2:?--hours requires a number}"; shift 2 ;;
            --threshold|-t)
                SPIKE_THRESHOLD="${2:?--threshold requires a number}"; shift 2 ;;
            --help|-h)
                echo "Usage: $(basename "$0") [--hours N] [--threshold N]"
                echo "  --hours N      Lookback window in hours (default: ${HOURS})"
                echo "  --threshold N  Occurrences before flagging a pattern (default: ${SPIKE_THRESHOLD})"
                exit 0 ;;
            *) warn "Unknown argument: $1"; shift ;;
        esac
    done
}

# --- Helpers ---
# Fetch journal for a time window, optionally grep a pattern
fetch_since() {
    local pattern="$1"
    journalctl --since "-${HOURS}h" --no-pager -q 2>/dev/null \
        | grep -iE "$pattern" 2>/dev/null
}

# Count occurrences of a pattern in the journal
count_pattern() {
    local pattern="$1"
    fetch_since "$pattern" | grep -c '.' || true
}

# Top-N units producing a pattern
# journalctl short format: MMM DD HH:MM:SS HOSTNAME UNIT[PID]: msg → field 5
top_units() {
    local pattern="$1"
    local n="${2:-5}"
    fetch_since "$pattern" \
        | awk '{print $5}' \
        | sed 's/\[.*//; s/://' \
        | sort | uniq -c | sort -rn \
        | head -"$n"
}

# Print a findings block
print_finding() {
    local title="$1"
    local count="$2"
    local pattern="$3"
    local severity="${4:-warn}"   # ok | warn | error

    echo ""
    if [[ "$severity" == "ok" ]]; then
        ok "${title}: ${count}"
    elif [[ "$severity" == "error" ]]; then
        error "${title}: ${count}"
    else
        warn "${title}: ${count}"
    fi

    if [[ "$count" -gt 0 ]]; then
        info "  Top sources:"
        top_units "$pattern" 5 | while read -r cnt unit; do
            printf "    %-6s  %s\n" "$cnt" "$unit"
        done

        info "  Last occurrence:"
        fetch_since "$pattern" | tail -1 | sed 's/^/    /'
    fi
}

# --- Analysis checks ---

check_crashes() {
    section "Crash & Core Dump Events"
    local count
    count=$(count_pattern 'segfault|segmentation fault|core dumped|dumped core|killed process')
    local sev="ok"
    [[ "$count" -gt 0 ]] && sev="error"
    print_finding "Crash/segfault/OOM-kill events" "$count" \
        'segfault|segmentation fault|core dumped|dumped core|killed process' "$sev"
}

check_oom() {
    section "Out-of-Memory Events"
    local count
    count=$(count_pattern 'out of memory|oom.kill|oom_kill|memory cgroup')
    local sev="ok"
    [[ "$count" -gt 0 ]] && sev="error"
    print_finding "OOM events" "$count" \
        'out of memory|oom.kill|oom_kill|memory cgroup' "$sev"
}

check_auth_failures() {
    section "Authentication Failures"
    local count
    count=$(count_pattern 'authentication failure|failed password|invalid user|failed login|pam_unix.*failure')
    local sev="ok"
    [[ "$count" -ge "$SPIKE_THRESHOLD" ]] && sev="error"
    [[ "$count" -gt 0 && "$count" -lt "$SPIKE_THRESHOLD" ]] && sev="warn"
    print_finding "Auth failures" "$count" \
        'authentication failure|failed password|invalid user|failed login|pam_unix.*failure' "$sev"
}

check_service_restarts() {
    section "Service Restarts & Failures"

    local restart_count failed_count
    restart_count=$(count_pattern 'start request repeated too quickly|service entered failed state|start-limit-hit|restarting')
    failed_count=$(count_pattern 'systemd.*failed\.|entered.*failed state|unit.*failed')

    local sev="ok"
    [[ "$restart_count" -gt 0 || "$failed_count" -gt 0 ]] && sev="warn"
    [[ "$restart_count" -ge "$SPIKE_THRESHOLD" || "$failed_count" -ge "$SPIKE_THRESHOLD" ]] && sev="error"

    print_finding "Rapid restarts / start-limit hits" "$restart_count" \
        'start request repeated too quickly|start-limit-hit|restarting' "$sev"
    print_finding "Units entering failed state" "$failed_count" \
        'systemd.*failed\.|entered.*failed state|unit.*failed' "$sev"
}

check_disk_errors() {
    section "Disk & Filesystem Errors"
    local count
    count=$(count_pattern 'I/O error|ata.*error|blk_update_request|EXT4-fs error|XFS.*error|btrfs.*error|bad sector|reallocated sector|smart.*error')
    local sev="ok"
    [[ "$count" -gt 0 ]] && sev="error"
    print_finding "Disk/FS errors" "$count" \
        'I/O error|ata.*error|blk_update_request|EXT4-fs error|XFS.*error|btrfs.*error|bad sector' "$sev"
}

check_network_errors() {
    section "Network Errors"
    local count
    count=$(count_pattern 'link is not ready|no carrier|network unreachable|connection refused|DHCP.*failed|dns.*failed|nss-lookup')
    local sev="ok"
    [[ "$count" -ge "$SPIKE_THRESHOLD" ]] && sev="warn"
    print_finding "Network errors/drops" "$count" \
        'link is not ready|no carrier|network unreachable|connection refused|DHCP.*failed' "$sev"
}

check_log_volume_spike() {
    section "Log Volume Spike Detection"

    info "Messages per hour (last ${HOURS}h):"
    echo ""

    # Count messages per hour using journalctl with short output
    journalctl --since "-${HOURS}h" --no-pager -q --output=short-iso 2>/dev/null \
        | grep -oP '^\d{4}-\d{2}-\d{2}T\d{2}' \
        | sort | uniq -c \
        | awk '{printf "    %s:00  %d messages\n", $2, $1}' \
        | while IFS= read -r line; do
            local count
            count=$(awk '{print $2}' <<< "$line")
            if [[ "$count" -ge "$((SPIKE_THRESHOLD * 100))" ]]; then
                echo -e "  ${RED}${line}  ← SPIKE${RESET}"
            elif [[ "$count" -ge "$((SPIKE_THRESHOLD * 20))" ]]; then
                echo -e "  ${YELLOW}${line}${RESET}"
            else
                echo "  ${line}"
            fi
        done

    echo ""
}

# --- Summary ---
show_summary() {
    section "Analysis Summary"

    local total
    total=$(journalctl --since "-${HOURS}h" --no-pager -q 2>/dev/null | grep -c '.' || true)
    info "Total journal entries in the last ${HOURS}h: ${total}"

    local errors warnings
    errors=$(journalctl --since "-${HOURS}h" -p 3 --no-pager -q 2>/dev/null | grep -c '.' || true)
    warnings=$(journalctl --since "-${HOURS}h" -p 4 --no-pager -q 2>/dev/null | grep -c '.' || true)

    printf "  ${RED}Errors (p≤3):${RESET}    %d\n" "$errors"
    printf "  ${YELLOW}Warnings (p=4):${RESET}  %d\n" "$warnings"
    echo ""
    info "Run with --hours N to change the lookback window."
}

# --- Main ---
main() {
    section "Log Anomaly Analyzer"
    require_cmds journalctl awk

    parse_args "$@"

    info "Analyzing journal from the last ${HOURS}h (threshold: ${SPIKE_THRESHOLD} occurrences)."

    check_crashes
    check_oom
    check_auth_failures
    check_service_restarts
    check_disk_errors
    check_network_errors
    check_log_volume_spike
    show_summary
}

main "$@"
