#!/usr/bin/env bash
# ============================================================
# clean-logs.sh
# Description : Intelligent log cleanup: vacuums journald by
#               size and time, rotates/deletes old logfiles in
#               /var/log. Defaults to a safe dry-run; requires
#               --confirm to apply changes.
# Dependencies: journalctl, find, du
# Compatibility: Any systemd Linux
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

# Defaults — all configurable via flags
MAX_JOURNAL_SIZE="500M"   # keep at most this much journal data
MAX_JOURNAL_DAYS=30       # keep at most this many days of journal
MAX_LOG_AGE_DAYS=60       # delete /var/log files older than this
DRY_RUN=true

# --- Parse args ---
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --confirm)
                DRY_RUN=false; shift ;;
            --journal-size|-s)
                MAX_JOURNAL_SIZE="${2:?--journal-size requires a value (e.g. 200M)}"; shift 2 ;;
            --journal-days|-d)
                MAX_JOURNAL_DAYS="${2:?--journal-days requires a number}"; shift 2 ;;
            --log-age|-a)
                MAX_LOG_AGE_DAYS="${2:?--log-age requires a number}"; shift 2 ;;
            --help|-h)
                echo "Usage: $(basename "$0") [--confirm] [OPTIONS]"
                echo ""
                echo "  --confirm             Apply changes (default: dry-run only)"
                echo "  --journal-size SIZE   Max journald size to retain (default: ${MAX_JOURNAL_SIZE})"
                echo "  --journal-days N      Max journal age in days (default: ${MAX_JOURNAL_DAYS})"
                echo "  --log-age N           Delete /var/log files older than N days (default: ${MAX_LOG_AGE_DAYS})"
                exit 0 ;;
            *) warn "Unknown argument: $1"; shift ;;
        esac
    done
}

# --- Current journal disk usage ---
show_journal_usage() {
    section "Current Journal Usage"

    local journal_dir="/var/log/journal"
    if [[ -d "$journal_dir" ]]; then
        local size
        size=$(du -sh "$journal_dir" 2>/dev/null | awk '{print $1}')
        info "Persistent journal at ${journal_dir}: ${BOLD}${size}${RESET}"
    else
        info "Volatile journal only (no persistent storage at /var/log/journal)"
    fi

    journalctl --disk-usage 2>/dev/null | sed 's/^/  /'
    echo ""
}

# --- Current /var/log usage ---
show_varlog_usage() {
    section "Current /var/log Usage"

    du -sh /var/log/* 2>/dev/null \
        | sort -rh \
        | head -15 \
        | awk '{printf "  %-10s  %s\n", $1, $2}'

    echo ""
    local total
    total=$(du -sh /var/log 2>/dev/null | awk '{print $1}')
    info "Total /var/log: ${BOLD}${total}${RESET}"
    echo ""
}

# --- Preview what journald vacuum would free ---
preview_journal_vacuum() {
    section "Journal Vacuum Preview"

    info "Would vacuum journal to: size ≤ ${MAX_JOURNAL_SIZE}, age ≤ ${MAX_JOURNAL_DAYS} days"

    # journalctl --vacuum-size and --vacuum-time with --dry-run is not universally
    # supported, so we derive an estimate from current usage vs target
    local current_bytes target_bytes
    current_bytes=$(journalctl --disk-usage 2>/dev/null \
        | grep -oP '\d+(\.\d+)?\s*(B|K|M|G)' | head -1)
    info "Current usage: ${current_bytes:-unknown}"

    # Show oldest and newest entries
    local oldest newest
    oldest=$(journalctl --no-pager -q -n 1 --output=short 2>/dev/null \
        | head -1 | awk '{print $1, $2, $3}')
    newest=$(journalctl --no-pager -q -n 1 --output=short -r 2>/dev/null \
        | head -1 | awk '{print $1, $2, $3}')
    info "Journal spans: ${oldest} → ${newest}"
    echo ""
}

# --- Preview old /var/log files ---
preview_varlog_cleanup() {
    section "/var/log Cleanup Preview"

    info "Files older than ${MAX_LOG_AGE_DAYS} days that would be removed:"
    echo ""

    local found=0
    while IFS= read -r f; do
        local size
        size=$(du -sh "$f" 2>/dev/null | awk '{print $1}')
        printf "  ${YELLOW}%-12s${RESET}  %s\n" "$size" "$f"
        found=1
    done < <(find /var/log -type f -mtime +"$MAX_LOG_AGE_DAYS" \
        ! -name "*.gz.tmp" 2>/dev/null | sort)

    [[ "$found" -eq 0 ]] && ok "No files older than ${MAX_LOG_AGE_DAYS} days found."
    echo ""
}

# --- Apply journal vacuum ---
do_journal_vacuum() {
    section "Vacuuming Journal"
    require_root

    info "Vacuuming to size ≤ ${MAX_JOURNAL_SIZE} …"
    journalctl --vacuum-size="$MAX_JOURNAL_SIZE" 2>&1 | sed 's/^/  /'

    info "Vacuuming entries older than ${MAX_JOURNAL_DAYS} days …"
    journalctl --vacuum-time="${MAX_JOURNAL_DAYS}d" 2>&1 | sed 's/^/  /'

    ok "Journal vacuum complete."
    echo ""
    journalctl --disk-usage 2>/dev/null | sed 's/^/  /'
}

# --- Apply /var/log cleanup ---
do_varlog_cleanup() {
    section "Cleaning Old Log Files"
    require_root

    local removed=0
    while IFS= read -r f; do
        rm -f "$f" 2>/dev/null && (( removed++ ))
        info "Removed: ${f}"
    done < <(find /var/log -type f -mtime +"$MAX_LOG_AGE_DAYS" \
        ! -name "*.gz.tmp" 2>/dev/null | sort)

    if [[ "$removed" -gt 0 ]]; then
        ok "${removed} file(s) removed from /var/log."
    else
        ok "Nothing to remove."
    fi
}

# --- Main ---
main() {
    section "Log Cleanup"
    require_cmds journalctl find du

    parse_args "$@"

    show_journal_usage
    show_varlog_usage

    if "$DRY_RUN"; then
        warn "DRY-RUN mode — no changes will be made."
        info "Re-run with ${BOLD}--confirm${RESET} to apply."
        echo ""
        preview_journal_vacuum
        preview_varlog_cleanup
    else
        warn "LIVE mode — changes will be applied."
        echo ""
        confirm_critical "Proceed with log cleanup?" || { info "Aborted."; exit 0; }
        do_journal_vacuum
        do_varlog_cleanup
        echo ""
        ok "Cleanup complete."
    fi
}

main "$@"
