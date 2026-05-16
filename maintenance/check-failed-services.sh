#!/usr/bin/env bash
# ============================================================
# check-failed-services.sh
# Description : Lists failed systemd services with status detail,
#               recent log tail, and optional restart/disable actions.
# Dependencies: systemctl, journalctl
# Compatibility: Any systemd Linux
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

LOG_LINES="${LOG_LINES:-20}"   # Lines of journald output to show per service

# --- List failed services ---
get_failed_services() {
    systemctl --failed --no-legend --no-pager 2>/dev/null | awk '{print $1}'
}

# --- Show detail for a single service ---
show_service_detail() {
    local svc="$1"

    echo ""
    echo -e "  ${BOLD}● ${svc}${RESET}"
    systemctl status "$svc" --no-pager -l 2>/dev/null \
        | grep -E "(Loaded|Active|Main PID|Status|Error)" \
        | sed 's/^/    /'

    echo ""
    info "Last ${LOG_LINES} log lines:"
    journalctl -u "$svc" -n "$LOG_LINES" --no-pager 2>/dev/null \
        | sed 's/^/    /' \
        | tail -n "$LOG_LINES"
}

# --- Action menu for a service ---
handle_service_action() {
    local svc="$1"

    echo ""
    echo -e "  What do you want to do with ${BOLD}${svc}${RESET}?"
    echo "    [1] Restart"
    echo "    [2] Disable (won't start on next boot)"
    echo "    [3] Mask (permanently disabled)"
    echo "    [4] Do nothing"
    echo -n "  Option [1-4]: "
    read -r choice

    case "$choice" in
        1)
            confirm "Restart ${svc}?" || return 0
            if sudo systemctl restart "$svc"; then
                ok "${svc} restarted successfully."
            else
                error "Could not restart ${svc}."
            fi
            ;;
        2)
            confirm_critical "Disable ${svc}? It won't start automatically anymore." || return 0
            sudo systemctl disable "$svc" && ok "${svc} disabled."
            ;;
        3)
            confirm_critical "Mask ${svc}? It won't be startable in any way." || return 0
            sudo systemctl mask "$svc" && ok "${svc} masked."
            ;;
        *)
            info "No changes made to ${svc}."
            ;;
    esac
}

# --- Main ---
main() {
    section "Failed systemd services"
    require_cmds systemctl journalctl

    local failed
    mapfile -t failed < <(get_failed_services)

    if [[ ${#failed[@]} -eq 0 ]]; then
        ok "No failed services found. System is clean."
        exit 0
    fi

    warn "${#failed[@]} failed service(s) found:"
    for svc in "${failed[@]}"; do
        echo "  - ${svc}"
    done

    echo ""
    confirm "Show details and options for each service?" || exit 0

    for svc in "${failed[@]}"; do
        section "Service: ${svc}"
        show_service_detail "$svc"
        handle_service_action "$svc"
    done

    # Final status
    section "Final status"
    local still_failed
    mapfile -t still_failed < <(get_failed_services)

    if [[ ${#still_failed[@]} -eq 0 ]]; then
        ok "All failed services have been resolved."
    else
        warn "${#still_failed[@]} service(s) still failing: ${still_failed[*]}"
    fi
}

main "$@"
