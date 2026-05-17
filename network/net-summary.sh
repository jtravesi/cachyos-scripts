#!/usr/bin/env bash
# ============================================================
# net-summary.sh
# Description : Summary of active interfaces, IPs, gateway, DNS
#               and connection manager. Auto-detects NetworkManager,
#               systemd-networkd or none.
# Dependencies: ip, ss, resolvectl or /etc/resolv.conf
# Compatibility: Any Linux
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

# --- Detect network manager ---
detect_network_manager() {
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        echo "NetworkManager"
    elif systemctl is-active --quiet systemd-networkd 2>/dev/null; then
        echo "systemd-networkd"
    elif systemctl is-active --quiet connman 2>/dev/null; then
        echo "connman"
    else
        echo "unknown"
    fi
}

# --- Interfaces and IPs ---
show_interfaces() {
    section "Network interfaces"

    local ifaces
    mapfile -t ifaces < <(ip -br link show | awk '{print $1}' | grep -v '^lo$')

    for iface in "${ifaces[@]}"; do
        local state mac ipv4 ipv6
        state=$(ip -br link show "$iface" | awk '{print $2}')
        mac=$(ip link show "$iface" | awk '/link\/ether/{print $2}')
        ipv4=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet /{print $2}' | paste -sd ', ')
        ipv6=$(ip -6 addr show "$iface" 2>/dev/null | awk '/inet6 /{print $2}' | grep -v '^fe80' | paste -sd ', ')

        local state_color="$GREEN"
        [[ "$state" != "UP" ]] && state_color="$RED"

        printf "\n  ${BOLD}%-15s${RESET} ${state_color}%-10s${RESET}\n" "$iface" "$state"
        [[ -n "$mac"  ]] && printf "    %-12s %s\n" "MAC:"  "$mac"
        [[ -n "$ipv4" ]] && printf "    %-12s %s\n" "IPv4:" "$ipv4"
        [[ -n "$ipv6" ]] && printf "    %-12s %s\n" "IPv6:" "$ipv6"
    done
}

# --- Default gateway ---
show_gateway() {
    section "Default gateway"

    local gw_ipv4 gw_ipv6 gw_iface
    gw_ipv4=$(ip -4 route show default 2>/dev/null | awk '/default/{print $3; exit}')
    gw_ipv6=$(ip -6 route show default 2>/dev/null | awk '/default/{print $3; exit}')
    gw_iface=$(ip -4 route show default 2>/dev/null | awk '/default/{print $5; exit}')

    if [[ -z "$gw_ipv4" && -z "$gw_ipv6" ]]; then
        warn "No default gateway found."
        return 0
    fi

    [[ -n "$gw_ipv4"  ]] && printf "  %-12s %s\n" "IPv4:" "$gw_ipv4"
    [[ -n "$gw_ipv6"  ]] && printf "  %-12s %s\n" "IPv6:" "$gw_ipv6"
    [[ -n "$gw_iface" ]] && printf "  %-12s %s\n" "Interface:" "$gw_iface"
}

# --- DNS ---
show_dns() {
    section "DNS servers"

    if command -v resolvectl &>/dev/null; then
        local dns_servers
        dns_servers=$(resolvectl status 2>/dev/null \
            | awk '/DNS Servers:/{found=1} found && /[0-9a-f.:]+/{print "  "$0; found=0} found{print "  "$0}' \
            | grep -v "^$" | head -10)

        if [[ -n "$dns_servers" ]]; then
            echo "$dns_servers"
        else
            # Fallback: global DNS from resolvectl
            resolvectl dns 2>/dev/null | sed 's/^/  /' | head -5
        fi
    elif [[ -f /etc/resolv.conf ]]; then
        grep "^nameserver" /etc/resolv.conf | awk '{printf "  nameserver: %s\n", $2}'
    else
        warn "Could not determine DNS configuration."
    fi
}

# --- Public IP ---
show_public_ip() {
    section "Public IP"

    local pub_ip
    pub_ip=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null)

    if [[ -n "$pub_ip" ]]; then
        printf "  %-12s %s\n" "Public IP:" "$pub_ip"
    else
        warn "Could not retrieve public IP (no internet or timeout)."
    fi
}

# --- Active connections summary ---
show_connections_summary() {
    section "Active connections summary"

    local established time_wait
    established=$(ss -tn state established 2>/dev/null | tail -n +2 | wc -l)
    time_wait=$(ss -tn state time-wait 2>/dev/null | tail -n +2 | wc -l)

    printf "  %-20s %s\n" "Established:" "$established"
    printf "  %-20s %s\n" "Time-wait:" "$time_wait"
}

# --- Main ---
main() {
    section "Network Summary"

    local nm
    nm=$(detect_network_manager)
    printf "  %-20s %s\n" "Network manager:" "$nm"

    show_interfaces
    show_gateway
    show_dns
    show_public_ip
    show_connections_summary
}

main "$@"
