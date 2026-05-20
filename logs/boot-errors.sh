#!/usr/bin/env bash
# ============================================================
# boot-errors.sh
# Description : Shows errors and warnings from the current and
#               previous boot using journalctl. Groups entries
#               by unit/source, highlights critical messages,
#               and summarises counts per severity level.
# Dependencies: journalctl
# Compatibility: Any systemd Linux
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

MAX_BOOTS=2
DEFAULT_PRIORITY=4   # 4=warning and above; lower = more severe only

# Patterns to suppress — high-volume noise that is not actionable
NOISE_PATTERNS=(
    '\[UFW BLOCK\]'
    'audit:'
)

# --- Parse args ---
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --boots|-b)
                MAX_BOOTS="${2:?--boots requires a number}"; shift 2 ;;
            --priority|-p)
                DEFAULT_PRIORITY="${2:?--priority requires a number}"; shift 2 ;;
            --help|-h)
                echo "Usage: $(basename "$0") [--boots N] [--priority 0-4]"
                echo "  --boots N      Number of boots to inspect (default: ${MAX_BOOTS})"
                echo "  --priority N   Max priority: 4=warning 3=err 2=crit (default: ${DEFAULT_PRIORITY})"
                exit 0 ;;
            *) warn "Unknown argument: $1"; shift ;;
        esac
    done
}

# --- Filter noise ---
filter_noise() {
    local pattern_args=()
    for p in "${NOISE_PATTERNS[@]}"; do
        pattern_args+=(-e "$p")
    done
    grep -v "${pattern_args[@]}"
}

# --- Show entries for one boot ---
show_boot() {
    local boot_idx="$1"
    local boot_label="$2"

    local first_entry
    first_entry=$(journalctl --list-boots 2>/dev/null \
        | awk -v idx="$boot_idx" '$1 == idx {print $3, $4}')

    if [[ -z "$first_entry" ]]; then
        info "Boot ${boot_label}: no journal data available."
        return
    fi

    section "Boot ${boot_label}  [started: ${first_entry}]"

    # Fetch all entries for this boot at the requested priority
    # Format: short-iso gives: TIMESTAMP HOSTNAME UNIT[PID]: MESSAGE
    local raw_entries
    raw_entries=$(journalctl -b "$boot_idx" -p "$DEFAULT_PRIORITY" \
        --no-pager --output=short-iso 2>/dev/null | filter_noise)

    local total
    total=$(echo "$raw_entries" | grep -c '.' || true)

    if [[ "$total" -eq 0 ]]; then
        ok "No errors or warnings recorded for this boot."
        return
    fi

    # Severity summary (filter noise for each count too)
    local n_warn n_err n_crit
    n_warn=$(journalctl -b "$boot_idx" -p 4 --no-pager -q 2>/dev/null \
        | filter_noise | grep -c '.' || true)
    n_err=$(journalctl -b "$boot_idx" -p 3 --no-pager -q 2>/dev/null \
        | filter_noise | grep -c '.' || true)
    n_crit=$(journalctl -b "$boot_idx" -p 2 --no-pager -q 2>/dev/null \
        | filter_noise | grep -c '.' || true)

    echo ""
    printf "  Severity counts — "
    [[ "$n_crit" -gt 0 ]] \
        && printf "${RED}CRIT/ALERT/EMERG: %d${RESET}  " "$n_crit"
    printf "${RED}ERR: %d${RESET}  " "$n_err"
    printf "${YELLOW}WARNING: %d${RESET}\n\n" "$n_warn"

    # Group lines by unit name (field 3 in short-iso: UNIT[pid]: or UNIT:)
    declare -A unit_lines
    declare -a unit_order

    while IFS= read -r line; do
        [[ -z "$line" || "$line" == --* ]] && continue

        # Extract unit: 3rd space-separated token, strip [pid]: suffix
        local unit
        unit=$(awk '{print $3}' <<< "$line" | sed 's/\[.*//; s/://')
        [[ -z "$unit" ]] && unit="unknown"

        if [[ -z "${unit_lines[$unit]+_}" ]]; then
            unit_order+=("$unit")
        fi
        unit_lines[$unit]+="${line}"$'\n'
    done <<< "$raw_entries"

    # Print grouped output
    for unit in "${unit_order[@]}"; do
        local count
        count=$(echo "${unit_lines[$unit]}" | grep -c '.' || true)
        printf "  ${BOLD}${CYAN}%-30s${RESET}  %d message(s)\n" "${unit}" "$count"

        local shown=0
        while IFS= read -r msg_line; do
            [[ -z "$msg_line" ]] && continue
            (( shown >= 5 )) && break

            local color="$YELLOW"
            echo "$msg_line" | grep -qiE '\b(error|err|crit|emerg|alert)\b' \
                && color="$RED"
            echo -e "    ${color}${msg_line}${RESET}"
            (( shown++ ))
        done <<< "${unit_lines[$unit]}"

        local remaining=$(( count - shown ))
        [[ "$remaining" -gt 0 ]] && \
            echo -e "    ${CYAN}… ${remaining} more — journalctl -b ${boot_idx} -u ${unit} -p ${DEFAULT_PRIORITY}${RESET}"

        echo ""
    done
}

# --- Main ---
main() {
    section "Boot Error Report"
    require_cmds journalctl

    parse_args "$@"

    local available_boots
    available_boots=$(journalctl --list-boots 2>/dev/null | grep -c '.' || true)
    available_boots=$(( available_boots - 1 ))

    info "Journal has ${available_boots} boot(s) recorded. Showing last ${MAX_BOOTS}."
    info "Priority threshold: ${DEFAULT_PRIORITY} (warning=4, err=3, crit=2). Noise filters active."

    local shown=0
    for (( idx=0; idx > -MAX_BOOTS; idx-- )); do
        local label
        [[ "$idx" -eq 0 ]] && label="current (${idx})" || label="previous (${idx})"
        show_boot "$idx" "$label"
        (( shown++ ))
        [[ "$shown" -ge "$MAX_BOOTS" ]] && break
    done
}

main "$@"
