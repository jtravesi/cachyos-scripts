#!/usr/bin/env bash
# ============================================================
# scx-scheduler-switch.sh
# Description : Manage sched_ext (scx_*) schedulers through the
#               scx_loader daemon via its scxctl client. Lists
#               the schedulers supported on this system with a
#               short description of each, shows the active one,
#               and switches / starts / stops them — optionally
#               in a given mode (auto, gaming, lowlatency,
#               powersave, server). Stopping returns the system
#               to the in-kernel default scheduler.
# Dependencies: scxctl, scx_loader (package: scx-scheds), a kernel
#               with sched_ext support
# Compatibility: CachyOS
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

SCHED_EXT_SYSFS="/sys/kernel/sched_ext"
VALID_MODES=(auto gaming lowlatency powersave server)

# scxctl talks to scx_loader over the system bus; mutations need root.
SUDO=""
[[ $EUID -ne 0 ]] && SUDO="sudo"

# Set by parse_args
TARGET_SCHED=""
TARGET_MODE=""
ACTION="switch"      # switch | stop | restore | list

usage() {
    cat <<EOF
Usage: $(basename "$0") [SCHEDULER] [MODE] [options]

  SCHEDULER       Scheduler to switch to (short name, e.g. lavd, bpfland).
                  Omit for an interactive menu.
  MODE            Optional mode: ${VALID_MODES[*]}

Options:
  -m, --mode M    Mode to run the scheduler in (same as positional MODE).
      --stop      Stop the running scx scheduler (back to in-kernel default).
      --restore   Restore the default scheduler from scx_loader config.
  -l, --list      List supported schedulers and current status, then exit.
  -h, --help      Show this help.

Examples:
  $(basename "$0")                    # interactive
  $(basename "$0") lavd               # switch to scx_lavd (auto mode)
  $(basename "$0") bpfland gaming     # scx_bpfland in gaming mode
  $(basename "$0") --stop             # disable scx, use kernel default
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -m|--mode) shift; TARGET_MODE="${1:-}" ;;
            --stop)    ACTION="stop" ;;
            --restore) ACTION="restore" ;;
            -l|--list) ACTION="list" ;;
            -h|--help) usage; exit 0 ;;
            -*)        usage; fatal "Unknown option: $1" ;;
            *)
                if [[ -z "$TARGET_SCHED" ]]; then
                    TARGET_SCHED="$1"
                elif [[ -z "$TARGET_MODE" ]]; then
                    TARGET_MODE="$1"
                else
                    usage; fatal "Unexpected argument: $1"
                fi
                ;;
        esac
        shift
    done
}

# --- Human description for a known scheduler (best effort) ---
sched_desc() {
    case "$1" in
        bpfland)    echo "Interactive-focused; prioritizes latency-sensitive tasks (desktop/gaming)" ;;
        lavd)       echo "Latency-criticality Aware Virtual Deadline; tuned for gaming" ;;
        rusty)      echo "General-purpose multi-domain scheduler; solid all-rounder" ;;
        rustland)   echo "Userspace scheduling in Rust; flexible / experimental" ;;
        flash)      echo "EDF-based; low, predictable latency for multimedia" ;;
        p2dq)       echo "Scalable per-CPU design; mixed and server workloads" ;;
        tickless)   echo "Minimizes timer ticks; power saving and reduced jitter" ;;
        layered)    echo "Configurable layered policies for complex workloads" ;;
        cosmos)     echo "Hybrid simple scheduler" ;;
        central)    echo "Single-CPU dispatch; demo / experimental" ;;
        *)          echo "sched_ext scheduler" ;;
    esac
}

# --- True if $1 is a valid mode ---
is_valid_mode() {
    local m
    for m in "${VALID_MODES[@]}"; do [[ "$m" == "$1" ]] && return 0; done
    return 1
}

# --- Supported scheduler short names, one per line ---
list_supported() {
    scxctl list 2>/dev/null | grep -oE '"[a-z0-9_]+"' | tr -d '"'
}

# --- True if an scx scheduler is currently active ---
scx_running() {
    [[ "$(cat "${SCHED_EXT_SYSFS}/state" 2>/dev/null)" == "enabled" ]]
}

# --- Name of the running scheduler (empty if none) ---
running_sched() {
    cat "${SCHED_EXT_SYSFS}/root/ops" 2>/dev/null
}

# --- Show kernel support, current status and supported schedulers ---
show_status() {
    section "sched_ext Status"

    local state running
    state=$(cat "${SCHED_EXT_SYSFS}/state" 2>/dev/null || echo "unknown")
    if scx_running; then
        running=$(running_sched)
        printf "  %-20s ${GREEN}%s${RESET}\n" "State:" "enabled"
        printf "  %-20s ${BOLD}%s${RESET}\n" "Active scheduler:" "${running:-unknown}"
    else
        printf "  %-20s %s\n" "State:" "$state"
        printf "  %-20s %s\n" "Active scheduler:" "none (in-kernel default)"
    fi
    # scxctl's own view (includes mode when running)
    local info
    info=$(scxctl get 2>/dev/null)
    [[ -n "$info" ]] && printf "  %-20s %s\n" "scxctl:" "$info"

    section "Supported Schedulers"
    local -a scheds
    mapfile -t scheds < <(list_supported)
    if [[ ${#scheds[@]} -eq 0 ]]; then
        warn "scxctl reported no supported schedulers."
        return
    fi
    local s active
    active=$(running_sched)
    for s in "${scheds[@]}"; do
        local suffix=""
        [[ -n "$active" && "$s" == "$active" ]] && suffix=" ${CYAN}[active]${RESET}"
        printf "  ${BOLD}%-12s${RESET} %s%b\n" "$s" "$(sched_desc "$s")" "$suffix"
    done
}

# --- Interactive scheduler picker; sets TARGET_SCHED ---
pick_scheduler() {
    local -a scheds
    mapfile -t scheds < <(list_supported)
    [[ ${#scheds[@]} -eq 0 ]] && fatal "No supported schedulers reported by scxctl."

    local active
    active=$(running_sched)

    section "Select Scheduler"
    local i=1 s suffix
    for s in "${scheds[@]}"; do
        suffix=""
        [[ -n "$active" && "$s" == "$active" ]] && suffix=" ${CYAN}[active]${RESET}"
        printf "  [${BOLD}%2d${RESET}] %-12s %s%b\n" "$i" "$s" "$(sched_desc "$s")" "$suffix"
        (( i++ ))
    done
    printf "  [${BOLD} 0${RESET}] %-12s %s\n" "stop" "disable scx, use the in-kernel default"
    echo ""
    echo -n "  Select [0-${#scheds[@]}] (Enter to cancel): "
    local choice
    read -r choice
    [[ -z "$choice" ]] && { info "Cancelled."; exit 0; }
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 0 || choice > ${#scheds[@]} )); then
        fatal "Invalid selection: ${choice}"
    fi
    if (( choice == 0 )); then
        ACTION="stop"
        return
    fi
    TARGET_SCHED="${scheds[$((choice - 1))]}"

    # Offer a mode (default: auto)
    echo ""
    echo "  Modes: ${VALID_MODES[*]}"
    echo -n "  Mode (Enter for 'auto'): "
    local m
    read -r m
    [[ -n "$m" ]] && TARGET_MODE="$m"
}

# --- Apply: start or switch to TARGET_SCHED [TARGET_MODE] ---
do_switch() {
    # Validate scheduler against the supported list.
    local supported
    supported=$(list_supported)
    if ! grep -qx "$TARGET_SCHED" <<< "$supported"; then
        error "'${TARGET_SCHED}' is not a supported scheduler."
        info "Supported: $(tr '\n' ' ' <<< "$supported")"
        return 1
    fi

    # Validate mode if given.
    local -a mode_args=()
    if [[ -n "$TARGET_MODE" ]]; then
        if ! is_valid_mode "$TARGET_MODE"; then
            error "Invalid mode: ${TARGET_MODE}"
            info "Valid modes: ${VALID_MODES[*]}"
            return 1
        fi
        mode_args=(--mode "$TARGET_MODE")
    fi

    # start if nothing is running, switch otherwise.
    local verb="start"
    scx_running && verb="switch"

    info "Running: scxctl ${verb} --sched ${TARGET_SCHED} ${mode_args[*]}"
    if $SUDO scxctl "$verb" --sched "$TARGET_SCHED" "${mode_args[@]}"; then
        ok "scx scheduler '${TARGET_SCHED}'${TARGET_MODE:+ (${TARGET_MODE})} is now active."
    else
        error "scxctl ${verb} failed."
        return 1
    fi
}

do_stop() {
    if ! scx_running; then
        ok "No scx scheduler is running — already on the in-kernel default."
        return 0
    fi
    info "Running: scxctl stop"
    if $SUDO scxctl stop; then
        ok "scx stopped — back to the in-kernel default scheduler."
    else
        error "scxctl stop failed."
        return 1
    fi
}

do_restore() {
    info "Running: scxctl restore"
    if $SUDO scxctl restore; then
        ok "Default scheduler restored from scx_loader configuration."
    else
        error "scxctl restore failed."
        return 1
    fi
}

# --- Authenticate up front for mutating actions ---
need_root() {
    [[ $EUID -eq 0 ]] && return 0
    info "This action requires root. You may be prompted for your password."
    sudo -v || fatal "sudo authentication failed."
}

# --- Main ---
main() {
    parse_args "$@"

    section "scx Scheduler Switch"

    [[ -d "$SCHED_EXT_SYSFS" ]] || fatal "This kernel has no sched_ext support (${SCHED_EXT_SYSFS} missing)."
    require_cmds scxctl

    if [[ "$ACTION" == "list" ]]; then
        show_status
        exit 0
    fi

    show_status

    # Interactive selection when no scheduler / explicit action given.
    if [[ "$ACTION" == "switch" && -z "$TARGET_SCHED" ]]; then
        pick_scheduler   # may set ACTION=stop
    fi

    local rc=0
    case "$ACTION" in
        switch)  need_root; echo ""; do_switch  || rc=1 ;;
        stop)    need_root; echo ""; do_stop    || rc=1 ;;
        restore) need_root; echo ""; do_restore || rc=1 ;;
    esac

    echo ""
    section "Result"
    if scx_running; then
        ok "Active: ${BOLD}$(running_sched)${RESET}    ($(scxctl get 2>/dev/null))"
    else
        info "No scx scheduler running (in-kernel default)."
    fi

    echo ""
    info "Runtime change only. To auto-start at boot: ${BOLD}systemctl enable --now scx_loader.service${RESET}"

    exit "$rc"
}

main "$@"
