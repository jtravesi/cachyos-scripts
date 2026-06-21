#!/usr/bin/env bash
# ============================================================
# set-cpu-governor.sh
# Description : Switch the CPU frequency scaling governor across
#               all cores, reading the available governors and
#               scaling driver straight from sysfs (no hardcoded
#               lists). On intel_pstate / amd-pstate hardware it
#               also surfaces and can set the Energy Performance
#               Preference (EPP), the finer-grained knob those
#               drivers expose. Writes to sysfs (not persistent),
#               or with --persist installs a systemd unit that
#               re-applies the chosen governor/EPP on every boot.
# Dependencies: bash, coreutils; systemctl (only for --persist)
# Compatibility: Any Linux
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

CPU_BASE="/sys/devices/system/cpu"
CPU0="${CPU_BASE}/cpu0/cpufreq"
PERSIST_UNIT="/etc/systemd/system/cpu-governor.service"

# sysfs writes need privileges; use sudo inline when not already root.
SUDO=""
[[ $EUID -ne 0 ]] && SUDO="sudo"

# Set by parse_args
TARGET_GOV=""
TARGET_EPP=""
LIST_ONLY=0
PERSIST=0
UNPERSIST=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [GOVERNOR] [options]

  GOVERNOR        Governor to set on all cores (e.g. performance, powersave).
                  Omit for an interactive menu.

Options:
  -e, --epp PREF  Set the Energy Performance Preference (intel_pstate /
                  amd-pstate only). Can be combined with a governor.
  -p, --persist   After applying, install a systemd unit so the chosen
                  governor (and EPP) are re-applied on every boot.
      --unpersist Remove that systemd unit and stop persisting.
  -l, --list      Show driver, current state and available options, then exit.
  -h, --help      Show this help.

Note:
  On amd-pstate/intel_pstate the available EPP values depend on the active
  governor. Under the 'performance' governor the EPP is locked to
  'performance'; the full EPP list is only available under 'powersave'.

Examples:
  $(basename "$0")                       # interactive
  $(basename "$0") performance           # set governor on every core
  $(basename "$0") powersave -e balance_power --persist
  $(basename "$0") --unpersist           # remove boot persistence
  $(basename "$0") -l                    # read-only status
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -e|--epp)    shift; TARGET_EPP="${1:-}" ;;
            -p|--persist) PERSIST=1 ;;
            --unpersist) UNPERSIST=1 ;;
            -l|--list)   LIST_ONLY=1 ;;
            -h|--help)   usage; exit 0 ;;
            -*)          usage; fatal "Unknown option: $1" ;;
            *)           TARGET_GOV="$1" ;;
        esac
        shift
    done
}

# --- Read a single sysfs value, empty if unreadable ---
read_val() { cat "$1" 2>/dev/null; }

# --- Space-separated list of unique governors active across all cores ---
current_governors() {
    cat "${CPU_BASE}"/cpu*/cpufreq/scaling_governor 2>/dev/null | sort -u | tr '\n' ' '
}

# --- Same, for EPP ---
current_epps() {
    cat "${CPU_BASE}"/cpu*/cpufreq/energy_performance_preference 2>/dev/null \
        | sort -u | tr '\n' ' '
}

# --- True if EPP is supported (file exists on cpu0) ---
epp_supported() { [[ -f "${CPU0}/energy_performance_preference" ]]; }

# --- True if $1 is one of the space-separated words in $2 ---
in_list() {
    local needle="$1" word
    for word in $2; do [[ "$word" == "$needle" ]] && return 0; done
    return 1
}

# --- Print driver + current state + available options ---
show_status() {
    section "CPU Frequency Status"

    local driver avail cur
    driver=$(read_val "${CPU0}/scaling_driver")
    avail=$(read_val "${CPU0}/scaling_available_governors")
    cur=$(current_governors | xargs)

    printf "  %-24s %s\n" "Scaling driver:" "${driver:-unknown}"
    printf "  %-24s %s\n" "Available governors:" "${avail:-unknown}"
    printf "  %-24s ${BOLD}%s${RESET}\n" "Current governor:" "${cur:-unknown}"

    # Frequency range (MHz), if exposed
    local fmin fmax fcur
    fmin=$(read_val "${CPU0}/scaling_min_freq")
    fmax=$(read_val "${CPU0}/scaling_max_freq")
    fcur=$(read_val "${CPU0}/scaling_cur_freq")
    [[ -n "$fmin" && -n "$fmax" ]] && \
        printf "  %-24s %s–%s MHz\n" "Frequency range:" "$((fmin/1000))" "$((fmax/1000))"
    [[ -n "$fcur" ]] && printf "  %-24s %s MHz (cpu0)\n" "Current frequency:" "$((fcur/1000))"

    if epp_supported; then
        local epp_avail epp_cur
        epp_avail=$(read_val "${CPU0}/energy_performance_available_preferences")
        epp_cur=$(current_epps | xargs)
        echo ""
        printf "  %-24s %s\n" "Available EPP:" "${epp_avail:-unknown}"
        printf "  %-24s ${BOLD}%s${RESET}\n" "Current EPP:" "${epp_cur:-unknown}"
    fi
}

# --- Write $1 to every per-core file named $2; report how many succeeded ---
# Usage: apply_to_all <value> <filename> <label>
apply_to_all() {
    local value="$1" file="$2" label="$3"
    local total=0 ok_count=0 path

    for path in "${CPU_BASE}"/cpu[0-9]*/cpufreq/"$file"; do
        [[ -w "$path" || $EUID -eq 0 || -n "$SUDO" ]] || continue
        [[ -e "$path" ]] || continue
        (( total++ ))
        if echo "$value" | $SUDO tee "$path" >/dev/null 2>&1; then
            (( ok_count++ ))
        fi
    done

    if (( total == 0 )); then
        error "No writable ${label} files found."
        return 1
    fi
    if (( ok_count == total )); then
        ok "${label} set to '${value}' on all ${total} core(s)."
    else
        warn "${label} set to '${value}' on ${ok_count}/${total} core(s) — some writes failed."
    fi
    return 0
}

# --- Interactive governor picker; sets TARGET_GOV ---
pick_governor() {
    local avail cur
    avail=$(read_val "${CPU0}/scaling_available_governors")
    cur=$(current_governors | xargs)   # trim

    [[ -z "$avail" ]] && fatal "No available governors reported by the driver."

    local -a govs
    read -r -a govs <<< "$avail"

    section "Select Governor"
    local i=1 g suffix
    for g in "${govs[@]}"; do
        suffix=""
        in_list "$g" "$cur" && suffix=" ${CYAN}[current]${RESET}"
        printf "  [${BOLD}%d${RESET}] %-14s%b\n" "$i" "$g" "$suffix"
        (( i++ ))
    done
    echo ""
    echo -n "  Select governor [1-${#govs[@]}] (Enter to keep current): "
    local choice
    read -r choice
    [[ -z "$choice" ]] && { info "Keeping current governor."; return 1; }
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#govs[@]} )); then
        fatal "Invalid selection: ${choice}"
    fi
    TARGET_GOV="${govs[$((choice - 1))]}"
    return 0
}

# --- Interactive EPP picker; sets TARGET_EPP ---
pick_epp() {
    epp_supported || return 1

    local avail cur
    avail=$(read_val "${CPU0}/energy_performance_available_preferences")
    cur=$(current_epps | xargs)
    [[ -z "$avail" ]] && return 1

    local -a epps
    read -r -a epps <<< "$avail"

    # Under some governors (e.g. amd-pstate 'performance') the driver exposes
    # a single fixed EPP — nothing to choose, so just say so and skip.
    if (( ${#epps[@]} <= 1 )); then
        echo ""
        info "EPP is fixed to '${cur:-${epps[0]:-unknown}}' under the current governor — nothing to select."
        return 1
    fi

    echo ""
    confirm "Also set the Energy Performance Preference (EPP)?" || return 1

    section "Select EPP"
    local i=1 e suffix
    for e in "${epps[@]}"; do
        suffix=""
        in_list "$e" "$cur" && suffix=" ${CYAN}[current]${RESET}"
        printf "  [${BOLD}%d${RESET}] %-20s%b\n" "$i" "$e" "$suffix"
        (( i++ ))
    done
    echo ""
    echo -n "  Select EPP [1-${#epps[@]}] (Enter to skip): "
    local choice
    read -r choice
    [[ -z "$choice" ]] && return 1
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#epps[@]} )); then
        fatal "Invalid selection: ${choice}"
    fi
    TARGET_EPP="${epps[$((choice - 1))]}"
    return 0
}

# --- Validate + apply governor ---
do_governor() {
    local avail
    avail=$(read_val "${CPU0}/scaling_available_governors")
    if ! in_list "$TARGET_GOV" "$avail"; then
        error "'${TARGET_GOV}' is not an available governor."
        info "Available: ${avail:-unknown}"
        return 1
    fi
    apply_to_all "$TARGET_GOV" "scaling_governor" "Governor"
}

# --- Validate + apply EPP ---
do_epp() {
    if ! epp_supported; then
        error "Energy Performance Preference is not supported by this driver."
        return 1
    fi
    local avail
    avail=$(read_val "${CPU0}/energy_performance_available_preferences")
    if ! in_list "$TARGET_EPP" "$avail"; then
        error "'${TARGET_EPP}' is not an available EPP."
        info "Available (under the current governor): ${avail:-unknown}"
        # The most common cause: 'performance' governor locks EPP to 'performance'.
        local gov; gov=$(current_governors | xargs)
        [[ "$gov" == *performance* ]] && \
            info "Tip: the '${gov}' governor restricts EPP. Use 'powersave' for the full EPP range."
        return 1
    fi
    apply_to_all "$TARGET_EPP" "energy_performance_preference" "EPP"
}

# --- Authenticate up front for actions that need root ---
need_root() {
    [[ $EUID -eq 0 ]] && return 0
    info "This requires root. You may be prompted for your password."
    sudo -v || fatal "sudo authentication failed."
}

# --- Install a systemd unit re-applying governor/EPP at boot ---
# Persists the explicit targets when given, otherwise the current state.
write_persist() {
    require_cmds systemctl

    local gov epp
    gov="${TARGET_GOV:-$(current_governors | xargs | awk '{print $1}')}"
    epp=""
    if epp_supported; then
        epp="${TARGET_EPP:-$(current_epps | xargs | awk '{print $1}')}"
    fi
    [[ -z "$gov" ]] && { error "Could not determine a governor to persist."; return 1; }

    local desc="governor='${gov}'"
    [[ -n "$epp" ]] && desc+=", EPP='${epp}'"
    info "Installing ${PERSIST_UNIT} (${desc})…"

    # \$f stays literal in the unit; ${gov}/${epp}/${CPU_BASE} are expanded now.
    {
        cat <<UNIT
[Unit]
Description=Apply CPU governor and EPP (cachyos-scripts)

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for f in ${CPU_BASE}/cpu[0-9]*/cpufreq/scaling_governor; do echo ${gov} > "\$f"; done'
UNIT
        [[ -n "$epp" ]] && cat <<UNIT
ExecStart=/bin/sh -c 'for f in ${CPU_BASE}/cpu[0-9]*/cpufreq/energy_performance_preference; do echo ${epp} > "\$f" 2>/dev/null || true; done'
UNIT
        cat <<'UNIT'

[Install]
WantedBy=multi-user.target
UNIT
    } | $SUDO tee "$PERSIST_UNIT" >/dev/null || { error "Failed to write ${PERSIST_UNIT}."; return 1; }

    $SUDO systemctl daemon-reload
    if $SUDO systemctl enable cpu-governor.service >/dev/null 2>&1; then
        ok "Persistence enabled — settings will be re-applied on every boot."
        info "Remove later with: ${BOLD}$(basename "$0") --unpersist${RESET}"
    else
        error "Failed to enable cpu-governor.service."
        return 1
    fi
}

# --- Remove the persistence unit ---
remove_persist() {
    require_cmds systemctl
    if [[ ! -f "$PERSIST_UNIT" ]]; then
        info "No persistence unit found (${PERSIST_UNIT}). Nothing to remove."
        return 0
    fi
    $SUDO systemctl disable cpu-governor.service >/dev/null 2>&1
    $SUDO rm -f "$PERSIST_UNIT"
    $SUDO systemctl daemon-reload
    ok "Persistence removed — boot-time governor/EPP unit deleted."
}

# --- Main ---
main() {
    parse_args "$@"

    section "CPU Governor"

    [[ -d "$CPU0" ]] || fatal "No cpufreq sysfs found (${CPU0}). \
CPU frequency scaling is unavailable (VM, or driver not loaded)."

    # Standalone action: just remove persistence and exit.
    if (( UNPERSIST )); then
        need_root
        remove_persist
        exit 0
    fi

    if (( LIST_ONLY )); then
        show_status
        exit 0
    fi

    show_status

    # Interactive mode when no governor/EPP requested on the command line.
    local interactive=0
    [[ -z "$TARGET_GOV" && -z "$TARGET_EPP" ]] && interactive=1
    (( interactive )) && { pick_governor || true; }

    # Nothing to apply and not persisting → done.
    if [[ -z "$TARGET_GOV" && -z "$TARGET_EPP" ]] && (( ! PERSIST )); then
        info "Nothing to do."
        exit 0
    fi

    need_root

    echo ""
    local rc=0
    # Governor first: on amd-pstate/intel_pstate it changes which EPP values
    # the driver exposes, so the EPP menu below must reflect the new state.
    [[ -n "$TARGET_GOV" ]] && { do_governor || rc=1; }

    # In interactive mode, choose EPP now — against the post-governor list.
    (( interactive )) && { pick_epp || true; }
    [[ -n "$TARGET_EPP" ]] && { do_epp || rc=1; }

    # Persistence: prompt in interactive mode if something was applied.
    if (( interactive && ! PERSIST )) && [[ -n "$TARGET_GOV" || -n "$TARGET_EPP" ]]; then
        echo ""
        confirm "Make this persistent across reboot (systemd unit)?" && PERSIST=1
    fi
    if (( PERSIST )); then
        echo ""
        write_persist || rc=1
    fi

    echo ""
    show_status

    if (( ! PERSIST )); then
        echo ""
        info "Note: sysfs changes do ${BOLD}not${RESET} persist across reboot."
        info "Re-run with ${BOLD}--persist${RESET} to apply them automatically on boot."
    fi

    exit "$rc"
}

main "$@"
