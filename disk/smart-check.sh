#!/usr/bin/env bash
# ============================================================
# smart-check.sh
# Description : SMART health report for every physical disk.
#               Reports overall health, key wear/error counters
#               and raises bad-sector alerts (reallocated /
#               pending / offline-uncorrectable) for SATA disks
#               and spare/wear/media-error alerts for NVMe.
#               Read-only — runs only SMART read commands.
# Dependencies: smartctl (smartmontools), lsblk
# Compatibility: Any Linux
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

# smartctl needs privileges; use sudo inline when not already root.
SUDO=""
[[ $EUID -ne 0 ]] && SUDO="sudo"

# NVMe wear thresholds
SPARE_WARN_PCT=20      # available spare below this → warning
LIFE_WARN_PCT=90       # percentage-used at/above this → warning

# Per-run tallies (for the final summary)
declare -a SUMMARY_LINES
GLOBAL_VERDICT="OK"

# --- True if value is an integer greater than zero ---
is_pos() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 > 0 )); }

# --- Raise the severity of a verdict variable by name ---
# Usage: bump <varname> WARN|CRIT
bump() {
    local -n _v="$1"
    case "$2" in
        CRIT) _v="CRIT" ;;
        WARN) [[ "$_v" != "CRIT" ]] && _v="WARN" ;;
    esac
}

# --- SATA attribute raw value (last column) by numeric ID ---
attr_raw() { awk -v id="$1" '$1==id{print $NF; exit}' <<< "$2"; }

# --- SATA attribute RAW_VALUE column (10th) — for fields with trailing junk ---
attr_col10() { awk -v id="$1" '$1==id{print $10; exit}' <<< "$2"; }

# --- Value after "Label:" in an NVMe health log ---
nvme_field() {
    grep -im1 "^${1}:" <<< "$2" | sed 's/^[^:]*:[[:space:]]*//' | xargs
}

# --- Detect the smartctl device-type args needed for a device ---
# Echoes "" (works directly), "-d sat" (stubborn USB bridge), or "UNAVAILABLE".
# The "INFORMATION SECTION" header is printed for ATA, NVMe and SCSI alike;
# the old ATA-only "SMART support is:" marker silently missed every NVMe disk.
detect_devtype() {
    local dev="$1" out
    out=$($SUDO smartctl -i "$dev" 2>/dev/null)
    if grep -qiE 'START OF INFORMATION SECTION|Model Number|Device Model' <<< "$out"; then
        echo ""
        return
    fi
    # Stubborn USB-SATA bridge: retry forcing SAT translation.
    out=$($SUDO smartctl -i -d sat "$dev" 2>/dev/null)
    if grep -qiE 'START OF INFORMATION SECTION|Model Number|Device Model' <<< "$out"; then
        echo "-d sat"
        return
    fi
    echo "UNAVAILABLE"
}

# --- Print one labelled line, optionally with a colored alert tag ---
# Usage: line "Label" "value" ["WARN"|"CRIT" "tag text"]
line() {
    local label="$1" value="$2" sev="${3:-}" tag="${4:-}"
    if [[ -n "$sev" ]]; then
        local color="$YELLOW"; [[ "$sev" == "CRIT" ]] && color="$RED"
        printf "    %-26s %s  ${color}← %s${RESET}\n" "$label" "$value" "$tag"
    else
        printf "    %-26s %s\n" "$label" "$value"
    fi
}

# --- Report a single SATA / ATA disk ---
report_sata() {
    local dev="$1" dt="$2"
    local A H verdict="OK"
    A=$($SUDO smartctl $dt -A "$dev" 2>/dev/null)
    H=$($SUDO smartctl $dt -H "$dev" 2>/dev/null)

    # Overall health
    local health
    health=$(grep -i 'overall-health' <<< "$H" | grep -oiE 'PASSED|FAILED' | head -1)
    health="${health:-UNKNOWN}"
    [[ "$health" == "FAILED" ]] && bump verdict CRIT
    local hcolor="$GREEN"
    [[ "$health" != "PASSED" ]] && hcolor="$RED"
    line "Overall health:" "$(echo -e "${hcolor}${health}${RESET}")"

    # Context
    local poh pcc temp
    poh=$(attr_raw 9 "$A")
    pcc=$(attr_raw 12 "$A")
    temp=$(attr_col10 194 "$A"); [[ -z "$temp" ]] && temp=$(attr_col10 190 "$A")
    [[ -n "$poh"  ]] && line "Power-on hours:" "$poh"
    [[ -n "$pcc"  ]] && line "Power cycles:" "$pcc"
    [[ -n "$temp" ]] && line "Temperature:" "${temp} °C"

    # SSD life remaining (vendor-specific normalized VALUE 0-100), if present
    local life
    for id in 231 177 233 202; do
        life=$(awk -v id="$id" '$1==id{print $4; exit}' <<< "$A")
        [[ -n "$life" ]] && break
    done
    # Strip zero-padding (e.g. "099" -> 99) without tripping on non-numerics
    [[ "$life" =~ ^[0-9]+$ ]] && life=$(( 10#$life ))
    [[ -n "$life" ]] && line "SSD life remaining:" "${life}%"

    # --- Bad-sector / error counters ---
    local realloc pending offline reported crc
    realloc=$(attr_raw 5 "$A")
    pending=$(attr_raw 197 "$A")
    offline=$(attr_raw 198 "$A")
    reported=$(attr_raw 187 "$A")
    crc=$(attr_raw 199 "$A")

    if is_pos "$realloc"; then
        line "Reallocated sectors:" "$realloc" WARN "remapped — monitor closely"
        bump verdict WARN
    else
        [[ -n "$realloc" ]] && line "Reallocated sectors:" "0"
    fi
    if is_pos "$pending"; then
        line "Pending sectors:" "$pending" CRIT "unstable — failure likely"
        bump verdict CRIT
    fi
    if is_pos "$offline"; then
        line "Offline uncorrectable:" "$offline" CRIT "unreadable sectors"
        bump verdict CRIT
    fi
    if is_pos "$reported"; then
        line "Reported uncorrect:" "$reported" WARN "uncorrected errors"
        bump verdict WARN
    fi
    if is_pos "$crc"; then
        line "UDMA CRC errors:" "$crc" WARN "cable/connection issue"
        bump verdict WARN
    fi

    DISK_VERDICT="$verdict"
}

# --- Report a single NVMe disk ---
report_nvme() {
    local dev="$1" dt="$2"
    local A H verdict="OK"
    A=$($SUDO smartctl $dt -A "$dev" 2>/dev/null)
    H=$($SUDO smartctl $dt -H "$dev" 2>/dev/null)

    # Overall health
    local health
    health=$(grep -i 'overall-health' <<< "$H" | grep -oiE 'PASSED|FAILED' | head -1)
    [[ -z "$health" ]] && health=$(grep -i 'SMART Health Status' <<< "$H" | awk -F': ' '{print $2}')
    health="${health:-UNKNOWN}"
    [[ "$health" =~ ^(FAILED|.*[Ff]ail.*)$ ]] && bump verdict CRIT
    local hcolor="$GREEN"
    [[ "$health" != "PASSED" && "$health" != "OK" ]] && hcolor="$RED"
    line "Overall health:" "$(echo -e "${hcolor}${health}${RESET}")"

    # Critical warning bitfield
    local cwarn
    cwarn=$(nvme_field "Critical Warning" "$A")
    if [[ -n "$cwarn" && "$cwarn" != "0x00" ]]; then
        line "Critical warning:" "$cwarn" CRIT "controller flagged a problem"
        bump verdict CRIT
    elif [[ -n "$cwarn" ]]; then
        line "Critical warning:" "$cwarn"
    fi

    # Context
    local temp poh pcc
    temp=$(nvme_field "Temperature" "$A" | grep -oE '[0-9]+' | head -1)
    poh=$(nvme_field "Power On Hours" "$A" | tr -d ',')
    pcc=$(nvme_field "Power Cycles" "$A" | tr -d ',')
    [[ -n "$temp" ]] && line "Temperature:" "${temp} °C"
    [[ -n "$poh"  ]] && line "Power-on hours:" "$poh"
    [[ -n "$pcc"  ]] && line "Power cycles:" "$pcc"

    # Wear & spare
    local spare spare_thr used
    spare=$(nvme_field "Available Spare" "$A" | tr -dc '0-9')
    spare_thr=$(nvme_field "Available Spare Threshold" "$A" | tr -dc '0-9')
    used=$(nvme_field "Percentage Used" "$A" | tr -dc '0-9')

    if [[ -n "$spare" ]]; then
        if [[ -n "$spare_thr" ]] && (( spare < spare_thr )); then
            line "Available spare:" "${spare}%" CRIT "below threshold (${spare_thr}%)"
            bump verdict CRIT
        elif (( spare < SPARE_WARN_PCT )); then
            line "Available spare:" "${spare}%" WARN "running low"
            bump verdict WARN
        else
            line "Available spare:" "${spare}%"
        fi
    fi
    if [[ -n "$used" ]]; then
        if (( used >= LIFE_WARN_PCT )); then
            line "Percentage used:" "${used}%" WARN "near end of rated life"
            bump verdict WARN
        else
            line "Percentage used:" "${used}%"
        fi
    fi

    # Media / data integrity errors
    local media
    media=$(nvme_field "Media and Data Integrity Errors" "$A" | tr -d ',')
    if is_pos "$media"; then
        line "Media/data errors:" "$media" WARN "integrity errors logged"
        bump verdict WARN
    elif [[ -n "$media" ]]; then
        line "Media/data errors:" "0"
    fi

    DISK_VERDICT="$verdict"
}

# --- Report one disk (dispatch SATA vs NVMe) ---
report_disk() {
    local dev="$1"

    local dt
    dt=$(detect_devtype "$dev")

    local idata model serial size rota
    if [[ "$dt" == "UNAVAILABLE" ]]; then
        section "$dev"
        warn "SMART not available for this device (USB bridge or unsupported)."
        SUMMARY_LINES+=("$(printf '%s|%s|%s' "$dev" "N/A" "SMART unavailable")")
        return 0
    fi

    idata=$($SUDO smartctl $dt -i "$dev" 2>/dev/null)
    model=$(awk -F': +' '/Device Model|Model Number/{print $2; exit}' <<< "$idata" | xargs)
    serial=$(awk -F': +' '/Serial Number/{print $2; exit}' <<< "$idata" | xargs)
    size=$(awk -F': +' '/User Capacity|Total NVM Capacity|Namespace 1 Size/{print $2; exit}' <<< "$idata" \
            | grep -oE '\[[^]]+\]' | tr -d '[]' | xargs)
    rota=$(awk -F': +' '/Rotation Rate/{print $2; exit}' <<< "$idata" | xargs)

    local kind="HDD"
    [[ "$dev" == *nvme* ]] && kind="NVMe"
    [[ "$rota" == *"Solid State"* ]] && kind="SSD"

    section "$dev  —  ${model:-unknown}"
    printf "    %-26s %s\n" "Type:" "${kind}${size:+, ${size}}"
    [[ -n "$serial" ]] && printf "    %-26s %s\n" "Serial:" "$serial"

    DISK_VERDICT="OK"
    if [[ "$dev" == *nvme* ]]; then
        report_nvme "$dev" "$dt"
    else
        report_sata "$dev" "$dt"
    fi

    # Per-disk verdict line + record for summary
    local vcolor="$GREEN" vtext="healthy"
    case "$DISK_VERDICT" in
        WARN) vcolor="$YELLOW"; vtext="needs attention" ;;
        CRIT) vcolor="$RED";    vtext="FAILING — back up now" ;;
    esac
    echo ""
    printf "    %-26s ${vcolor}%s${RESET}\n" "Verdict:" "$vtext"
    bump GLOBAL_VERDICT "$DISK_VERDICT"
    SUMMARY_LINES+=("$(printf '%s|%s|%s' "$dev" "${model:-unknown}" "$DISK_VERDICT")")
}

# --- Final summary table ---
show_summary() {
    section "Summary"

    local entry dev model verdict color symbol
    for entry in "${SUMMARY_LINES[@]}"; do
        IFS='|' read -r dev model verdict <<< "$entry"
        case "$verdict" in
            OK)   color="$GREEN";  symbol="✓" ;;
            WARN) color="$YELLOW"; symbol="!" ;;
            CRIT) color="$RED";    symbol="✗" ;;
            *)    color="$CYAN";   symbol="*" ;;
        esac
        printf "  ${color}%s${RESET}  %-14s %-28s ${color}%s${RESET}\n" \
            "$symbol" "$dev" "$model" "$verdict"
    done

    echo ""
    case "$GLOBAL_VERDICT" in
        OK)   ok   "All disks report healthy SMART status." ;;
        WARN) warn "One or more disks need attention — review the alerts above." ;;
        CRIT) error "One or more disks are failing. Back up critical data immediately." ;;
    esac
}

# --- Main ---
main() {
    require_cmds smartctl lsblk

    section "SMART Check"

    if [[ $EUID -ne 0 ]]; then
        info "SMART queries require root. You may be prompted for your password."
        sudo -v || fatal "sudo authentication failed."
    fi

    # Physical disks only — skip RAM/zram, loop, optical and floppy devices.
    local -a disks
    mapfile -t disks < <(lsblk -dn -o NAME,TYPE 2>/dev/null \
        | awk '$2=="disk" && $1 !~ /^(zram|loop|sr|fd)/{print $1}')

    if [[ ${#disks[@]} -eq 0 ]]; then
        fatal "No physical disks found."
    fi

    local name
    for name in "${disks[@]}"; do
        report_disk "/dev/${name}"
    done

    show_summary

    # Exit non-zero if any disk is failing (useful for scripting / doctor.sh)
    [[ "$GLOBAL_VERDICT" == "CRIT" ]] && exit 2
    [[ "$GLOBAL_VERDICT" == "WARN" ]] && exit 1
    exit 0
}

main "$@"
