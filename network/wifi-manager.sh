#!/usr/bin/env bash
# ============================================================
# wifi-manager.sh
# Description : WiFi network management from CLI via nmcli.
#               Scan available networks with signal strength,
#               connect, disconnect and list saved connections.
# Dependencies: nmcli
# Compatibility: Any Linux with NetworkManager
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

require_cmds nmcli

# --- Parse nmcli -t (terse) line into US-separated fields on stdout ---
# nmcli -t uses ':' as separator and escapes embedded ':' as '\:' (and '\' as '\\').
# We emit ASCII US (0x1f) between fields: non-whitespace so `read` preserves
# empty fields (tab/space would collapse consecutive separators).
NM_SEP=$'\x1f'
nm_parse() {
    sed -e 's/\\\\/\x02/g' -e 's/\\:/\x01/g' -e $'s/:/\x1f/g' \
        -e 's/\x01/:/g' -e 's/\x02/\\\\/g'
}

# --- Signal strength to bar indicator (always 4 visual cols + label) ---
signal_bars() {
    local strength
    strength=$(tr -dc '0-9' <<< "$1")
    strength="${strength:-0}"
    # 10# forces base-10 (avoids "value too great for base" on leading zeros)
    if   (( 10#$strength >= 80 )); then echo "▂▄▆█ excellent"
    elif (( 10#$strength >= 60 )); then echo "▂▄▆  good"
    elif (( 10#$strength >= 40 )); then echo "▂▄   fair"
    elif (( 10#$strength >= 20 )); then echo "▂    weak"
    else                                echo "     none"
    fi
}

# --- Current connection status ---
show_status() {
    section "Current WiFi status"

    local active_iface
    active_iface=$(nmcli --color no -t -f device,type dev 2>/dev/null \
        | awk -F: '$2=="wifi"{print $1; exit}')

    local active_line
    active_line=$(nmcli --color no -t -f active,ssid,signal dev wifi 2>/dev/null \
        | grep '^yes:' | head -1)

    if [[ -z "$active_line" ]]; then
        warn "Not connected to any WiFi network."
        return 0
    fi

    local _active active_ssid signal
    IFS="$NM_SEP" read -r _active active_ssid signal \
        < <(printf '%s\n' "$active_line" | nm_parse)
    signal=$(tr -dc '0-9' <<< "$signal")

    local active_ip
    active_ip=$(ip -4 addr show "$active_iface" 2>/dev/null \
        | awk '/inet /{print $2; exit}')

    printf "  %-15s %s\n" "SSID:"      "${active_ssid:-(unknown)}"
    printf "  %-15s %s\n" "Interface:" "${active_iface:-unknown}"
    printf "  %-15s %s\n" "IP:"        "${active_ip:-unknown}"
    printf "  %-15s %s%% %s\n" "Signal:" "$signal" "$(signal_bars "$signal")"
}

# --- Scan available networks ---
scan_networks() {
    section "Available networks"

    info "Scanning... (this may take a few seconds)"
    nmcli dev wifi rescan 2>/dev/null
    sleep 2

    local raw
    mapfile -t raw < <(nmcli --color no -t \
        -f in-use,ssid,bssid,chan,signal,security dev wifi list 2>/dev/null)

    if [[ ${#raw[@]} -eq 0 ]]; then
        warn "No networks found."
        return 0
    fi

    local ssids=()

    printf "\n  %-2s %-4s %-28s %-19s %-4s %-7s %-4s %s\n" \
        "" "#" "SSID" "BSSID" "CH" "SIGNAL" "BARS" "SECURITY"
    printf "  %s\n" "$(printf '%.0s─' {1..95})"

    local i=1
    for line in "${raw[@]}"; do
        local in_use ssid bssid chan signal security bars marker ssid_disp
        IFS="$NM_SEP" read -r in_use ssid bssid chan signal security \
            < <(printf '%s\n' "$line" | nm_parse)
        signal=$(tr -dc '0-9' <<< "$signal")

        [[ -z "$ssid" ]] && ssid="(hidden)"
        bars=$(signal_bars "${signal:-0}" | awk '{print $1}')
        ssids+=("$ssid")

        # Mark the currently connected network with an asterisk
        marker=" "
        [[ "$in_use" == "*" ]] && marker="*"

        # Truncate long SSIDs so columns stay aligned
        ssid_disp="$ssid"
        if (( ${#ssid_disp} > 28 )); then
            ssid_disp="${ssid_disp:0:25}..."
        fi

        # $bars is always 4 visual columns but variable bytes (unicode),
        # so we print it without %Ns padding and follow with a fixed gap.
        printf "  %-2s %-4s %-28s %-19s %-4s %-7s %s  %s\n" \
            "$marker" "[$i]" "$ssid_disp" "$bssid" "$chan" \
            "${signal}%" "$bars" "${security:-none}"
        ((i++))
    done

    echo ""
    echo -n "  Connect to a network? Enter number or press Enter to skip: "
    read -r choice

    [[ -z "$choice" ]] && return 0

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < i )); then
        connect_network "${ssids[$((choice - 1))]}"
    else
        warn "Invalid selection."
    fi
}

# --- Connect to a network ---
connect_network() {
    local ssid="${1}"

    if [[ -z "$ssid" ]]; then
        echo -n "  Enter SSID to connect: "
        read -r ssid
    fi

    # Check if we have a saved connection
    local saved
    saved=$(nmcli -t -f name con show 2>/dev/null | grep -Fx "$ssid")

    if [[ -n "$saved" ]]; then
        info "Saved connection found for '${ssid}'. Connecting..."
        if nmcli con up "$ssid"; then
            ok "Connected to '${ssid}'."
        else
            error "Could not connect to '${ssid}'."
        fi
    else
        info "No saved connection for '${ssid}'. Enter password (leave empty if open):"
        echo -n "  Password: "
        read -rs password
        echo ""

        if [[ -z "$password" ]]; then
            if nmcli dev wifi connect "$ssid"; then
                ok "Connected to '${ssid}'."
            else
                error "Could not connect to '${ssid}'."
            fi
        else
            if nmcli dev wifi connect "$ssid" password "$password"; then
                ok "Connected to '${ssid}'."
            else
                error "Could not connect to '${ssid}'. Check the password."
            fi
        fi
    fi
}

# --- Disconnect ---
disconnect_network() {
    section "Disconnect"

    local iface
    iface=$(nmcli -t -f device,type dev 2>/dev/null \
        | awk -F: '/wifi/{print $1}' | head -1)

    if [[ -z "$iface" ]]; then
        warn "No WiFi interface found."
        return 0
    fi

    confirm "Disconnect WiFi interface ${iface}?" || return 0

    if nmcli dev disconnect "$iface"; then
        ok "Disconnected from WiFi."
    else
        error "Could not disconnect."
    fi
}

# --- List saved connections ---
list_saved() {
    section "Saved WiFi connections"

    local saved
    mapfile -t saved < <(nmcli -t -f name,type con show 2>/dev/null \
        | awk -F: '/wifi/{print $1}')

    if [[ ${#saved[@]} -eq 0 ]]; then
        info "No saved WiFi connections."
        return 0
    fi

    local i=1
    for conn in "${saved[@]}"; do
        printf "  [%d] %s\n" "$i" "$conn"
        ((i++))
    done

    echo ""
    echo "  [d] Delete a saved connection"
    echo "  [Enter] Go back"
    echo -n "  Option: "
    read -r opt

    if [[ "$opt" == "d" ]]; then
        echo -n "  Enter number to delete: "
        read -r del_idx
        if [[ "$del_idx" =~ ^[0-9]+$ ]] && (( del_idx >= 1 && del_idx < i )); then
            local to_delete="${saved[$((del_idx - 1))]}"
            confirm_critical "Delete saved connection '${to_delete}'?" || return 0
            nmcli con delete "$to_delete" && ok "Connection '${to_delete}' deleted."
        else
            warn "Invalid selection."
        fi
    fi
}

# --- Main menu ---
main() {
    section "WiFi Manager"

    show_status

    echo ""
    echo "  [1] Scan and connect to a network"
    echo "  [2] Disconnect"
    echo "  [3] List saved connections"
    echo "  [4] Exit"
    echo ""
    echo -n "  Option [1-4]: "
    read -r opt

    case "$opt" in
        1) scan_networks ;;
        2) disconnect_network ;;
        3) list_saved ;;
        4) exit 0 ;;
        *) warn "Invalid option." ;;
    esac
}

main "$@"
