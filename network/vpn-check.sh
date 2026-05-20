#!/usr/bin/env bash
# ============================================================
# vpn-check.sh
# Description : Detects active VPN connections by inspecting
#               network interfaces, running daemons and routing
#               tables. Flags DNS leaks if system DNS resolvers
#               are not routed through the VPN interface.
# Dependencies: ip, ss, ps, systemctl (optional)
# Compatibility: Any Linux
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

# Known VPN interface prefixes
VPN_IFACE_PREFIXES=(tun tap wg ppp proton mullvad nordlynx)

# Known VPN daemon process names
VPN_DAEMONS=(
    openvpn wireguard-go wg
    nordvpnd nordvpn
    expressvpnd expressvpn
    mullvadd mullvad-daemon
    protonvpn protonvpnd
    openconnect vpnc
    strongswan charon
    xl2tpd pptpd
    tailscaled tailscale
)

# --- Detect VPN interfaces ---
detect_vpn_interfaces() {
    section "VPN Interfaces"

    local found=0

    while IFS= read -r iface; do
        for prefix in "${VPN_IFACE_PREFIXES[@]}"; do
            if [[ "$iface" == ${prefix}* ]]; then
                found=1
                local state addrs
                state=$(ip -br link show "$iface" 2>/dev/null | awk '{print $2}')
                addrs=$(ip -br addr show "$iface" 2>/dev/null | awk '{$1=$2=""; print $0}' | xargs)

                if [[ "$state" == "UP" ]]; then
                    ok "Active VPN interface: ${BOLD}${iface}${RESET}  state=${GREEN}${state}${RESET}  addr=${addrs:-none}"
                else
                    warn "VPN interface found but DOWN: ${BOLD}${iface}${RESET}  state=${state}"
                fi

                show_routes_for "$iface"
                break
            fi
        done
    done < <(ip -br link show 2>/dev/null | awk '{print $1}')

    [[ "$found" -eq 0 ]] && info "No VPN network interfaces detected."
    return "$found"
}

# Show routes that go through a given interface
show_routes_for() {
    local iface="$1"
    local routes
    routes=$(ip route show dev "$iface" 2>/dev/null)
    if [[ -n "$routes" ]]; then
        echo ""
        info "  Routes via ${iface}:"
        while IFS= read -r route; do
            echo "    ${route}"
        done <<< "$routes"
        echo ""
    fi
}

# --- Detect VPN daemon processes ---
detect_vpn_daemons() {
    section "VPN Daemon Processes"

    local found=0

    for daemon in "${VPN_DAEMONS[@]}"; do
        local pids
        pids=$(pgrep -x "$daemon" 2>/dev/null | tr '\n' ' ')
        if [[ -n "$pids" ]]; then
            found=1
            local user
            user=$(ps -o user= -p "$(pgrep -x "$daemon" | head -1)" 2>/dev/null | tr -d ' ')
            ok "Running: ${BOLD}${daemon}${RESET}  pid(s)=${pids% }  user=${user:-?}"
        fi
    done

    # Also check for VPN-related systemd units
    if command -v systemctl &>/dev/null; then
        local vpn_units
        vpn_units=$(systemctl list-units --type=service --state=active 2>/dev/null \
            | grep -iE 'vpn|wireguard|openvpn|nordvpn|mullvad|proton|tailscale|openconnect' \
            | awk '{print $1}')
        if [[ -n "$vpn_units" ]]; then
            found=1
            while IFS= read -r unit; do
                ok "Active systemd unit: ${BOLD}${unit}${RESET}"
            done <<< "$vpn_units"
        fi
    fi

    [[ "$found" -eq 0 ]] && info "No VPN daemon processes detected."
    return "$found"
}

# --- DNS leak check ---
check_dns_leak() {
    section "DNS Leak Check"

    # Get active VPN interfaces
    local vpn_ifaces=()
    while IFS= read -r iface; do
        for prefix in "${VPN_IFACE_PREFIXES[@]}"; do
            [[ "$iface" == ${prefix}* ]] && vpn_ifaces+=("$iface") && break
        done
    done < <(ip -br link show up 2>/dev/null | awk '{print $1}')

    if [[ ${#vpn_ifaces[@]} -eq 0 ]]; then
        info "No active VPN interfaces — DNS leak check skipped."
        return
    fi

    # Collect configured DNS resolvers
    local resolvers=()
    if [[ -f /etc/resolv.conf ]]; then
        while IFS= read -r line; do
            [[ "$line" =~ ^nameserver[[:space:]]+(.*) ]] && resolvers+=("${BASH_REMATCH[1]}")
        done < /etc/resolv.conf
    fi

    if command -v ss &>/dev/null; then
        # Check if any DNS (port 53) traffic is going through a non-VPN interface
        local dns_conns
        dns_conns=$(ss -tunp 2>/dev/null | awk '$5 ~ /:53$/ || $6 ~ /:53$/ {print}')
        if [[ -n "$dns_conns" ]]; then
            info "Active DNS connections:"
            while IFS= read -r conn; do
                echo "    ${conn}"
            done <<< "$dns_conns"
        fi
    fi

    if [[ ${#resolvers[@]} -eq 0 ]]; then
        warn "No DNS resolvers found in /etc/resolv.conf"
        return
    fi

    info "Configured DNS resolvers: ${resolvers[*]}"

    local leak_detected=0
    for resolver in "${resolvers[@]}"; do
        # Check if resolver is reachable through VPN interface
        local route_iface
        route_iface=$(ip route get "$resolver" 2>/dev/null | grep -oP 'dev \K\S+' | head -1)

        local is_vpn_route=0
        for viface in "${vpn_ifaces[@]}"; do
            [[ "$route_iface" == "$viface" ]] && is_vpn_route=1 && break
        done

        if [[ "$is_vpn_route" -eq 1 ]]; then
            ok "DNS ${resolver} routes via VPN (${route_iface}) — no leak"
        else
            warn "DNS ${resolver} routes via ${route_iface:-?} — possible leak"
            leak_detected=1
        fi
    done

    if [[ "$leak_detected" -eq 1 ]]; then
        echo ""
        warn "DNS leak risk: resolver(s) not routing through VPN interface."
        info "Consider setting DNS inside your VPN client or using a private resolver."
    fi
}

# --- Summary ---
show_summary() {
    section "VPN Status Summary"

    local iface_active=0 daemon_active=0

    # Re-check silently
    for iface in $(ip -br link show up 2>/dev/null | awk '{print $1}'); do
        for prefix in "${VPN_IFACE_PREFIXES[@]}"; do
            [[ "$iface" == ${prefix}* ]] && iface_active=1 && break
        done
    done

    for daemon in "${VPN_DAEMONS[@]}"; do
        pgrep -x "$daemon" &>/dev/null && daemon_active=1 && break
    done

    # Also check systemd VPN units
    if [[ "$daemon_active" -eq 0 ]] && command -v systemctl &>/dev/null; then
        systemctl list-units --type=service --state=active 2>/dev/null \
            | grep -qiE 'vpn|wireguard|openvpn|nordvpn|mullvad|proton|tailscale|openconnect' \
            && daemon_active=1
    fi

    if [[ "$iface_active" -eq 1 && "$daemon_active" -eq 1 ]]; then
        ok "${GREEN}${BOLD}VPN is ACTIVE${RESET} — interface and daemon both detected."
    elif [[ "$iface_active" -eq 1 ]]; then
        warn "VPN interface is up but no matching daemon found. May be a manual tunnel."
    elif [[ "$daemon_active" -eq 1 ]]; then
        warn "VPN daemon is running but no tunnel interface is up. VPN may not be connected."
    else
        info "No VPN detected. System is using a direct connection."
    fi
}

# --- Main ---
main() {
    section "VPN Check"
    require_cmds ip ps

    detect_vpn_interfaces
    detect_vpn_daemons
    check_dns_leak
    show_summary
}

main "$@"
