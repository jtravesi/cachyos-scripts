#!/usr/bin/env bash
# ============================================================
# open-connections.sh
# Description : Lists active network connections with owning process
#               and user. Flags suspicious connections: unknown
#               processes, deleted executables, non-standard ports,
#               or connections owned by root to external IPs.
# Dependencies: ss, lsof, readlink
# Compatibility: Any Linux
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

# Ports considered standard/expected (extend as needed)
STANDARD_PORTS=(22 25 53 67 68 80 110 143 443 465 587 993 995 3306 5432 8080 8443)

# --- Helpers ---
is_standard_port() {
    local port="$1"
    for p in "${STANDARD_PORTS[@]}"; do
        [[ "$port" -eq "$p" ]] && return 0
    done
    return 1
}

is_external_ip() {
    local ip="$1"
    # Returns true if IP is NOT loopback, link-local or private
    [[ "$ip" =~ ^127\. ]]       && return 1
    [[ "$ip" =~ ^::1$ ]]        && return 1
    [[ "$ip" =~ ^10\. ]]        && return 1
    [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] && return 1
    [[ "$ip" =~ ^192\.168\. ]]  && return 1
    [[ "$ip" =~ ^fe80: ]]       && return 1
    return 0
}

exe_deleted() {
    local pid="$1"
    local exe
    exe=$(readlink /proc/"$pid"/exe 2>/dev/null)
    [[ "$exe" == *"(deleted)"* ]]
}

# --- Get connections via ss ---
get_connections() {
    # Format: state local_addr:port remote_addr:port pid/process
    ss -tunp state established state listen 2>/dev/null | tail -n +2
}

# --- Analyse and display ---
show_connections() {
    section "Active network connections"

    local suspicious=()
    local normal=()

    while IFS= read -r line; do
        local netid state local_addr remote_addr pid proc user reason flags

        netid=$(awk '{print $1}' <<< "$line")
        state=$(awk '{print $2}' <<< "$line")
        local_addr=$(awk '{print $5}' <<< "$line")
        remote_addr=$(awk '{print $6}' <<< "$line")

        # Extract PID and process name from users field
        local users_field
        users_field=$(grep -oP 'users:\(\("[^"]+",pid=\d+' <<< "$line" | head -1)
        proc=$(grep -oP '(?<=")[^"]+(?=",pid)' <<< "$users_field")
        pid=$(grep -oP '(?<=pid=)\d+' <<< "$users_field")

        # Get owning user
        if [[ -n "$pid" ]]; then
            user=$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ')
        else
            user="unknown"
            proc="unknown"
        fi

        # Extract remote port
        local remote_port
        remote_port=$(grep -oP '(?<=:)\d+$' <<< "$remote_addr")
        local remote_ip
        remote_ip=$(sed 's/:[0-9]*$//' <<< "$remote_addr" | tr -d '[]')

        # --- Suspicion checks ---
        flags=""
        reason=""

        if [[ "$proc" == "unknown" || -z "$proc" ]]; then
            flags="SUSPICIOUS"
            reason="no owning process identified"
        elif [[ -n "$pid" ]] && exe_deleted "$pid"; then
            flags="SUSPICIOUS"
            reason="executable deleted from disk"
        elif [[ "$user" == "root" ]] && [[ -n "$remote_ip" ]] && is_external_ip "$remote_ip" && [[ "$state" == "ESTAB" ]]; then
            flags="SUSPICIOUS"
            reason="root process connected to external IP"
        elif [[ -n "$remote_port" ]] && ! is_standard_port "$remote_port" && [[ "$state" == "ESTAB" ]]; then
            flags="UNUSUAL"
            reason="non-standard remote port ${remote_port}"
        fi

        local entry
        printf -v entry "  %-8s %-12s %-22s %-22s %-15s %-10s" \
            "$netid" "$state" "$local_addr" "$remote_addr" "${proc:-?}" "${user:-?}"

        if [[ -n "$flags" ]]; then
            suspicious+=("${flags}|${entry}|${reason}")
        else
            normal+=("$entry")
        fi

    done < <(get_connections)

    # Print header
    printf "\n  %-8s %-12s %-22s %-22s %-15s %-10s\n" \
        "PROTO" "STATE" "LOCAL" "REMOTE" "PROCESS" "USER"
    printf "  %s\n" "$(printf '%.0s─' {1..90})"

    # Normal connections
    for entry in "${normal[@]}"; do
        echo "$entry"
    done

    # Suspicious connections
    if [[ ${#suspicious[@]} -gt 0 ]]; then
        echo ""
        warn "${#suspicious[@]} suspicious/unusual connection(s) detected:"
        printf "\n  %-8s %-12s %-22s %-22s %-15s %-10s %-12s %s\n" \
            "PROTO" "STATE" "LOCAL" "REMOTE" "PROCESS" "USER" "FLAG" "REASON"
        printf "  %s\n" "$(printf '%.0s─' {1..110})"

        for entry in "${suspicious[@]}"; do
            IFS='|' read -r flag conn reason <<< "$entry"
            local color="$YELLOW"
            [[ "$flag" == "SUSPICIOUS" ]] && color="$RED"
            echo -e "${color}${conn}  ${flag}  ${reason}${RESET}"
        done
    else
        echo ""
        ok "No suspicious connections detected."
    fi
}

# --- Listening ports summary ---
show_listening() {
    section "Listening ports"

    printf "  %-8s %-20s %-25s %s\n" "PROTO" "ADDRESS" "PROCESS" "USER"
    printf "  %s\n" "$(printf '%.0s─' {1..70})"

    ss -tulnp 2>/dev/null | tail -n +2 | while IFS= read -r line; do
        local proto addr proc user pid

        proto=$(awk '{print $1}' <<< "$line")
        addr=$(awk '{print $5}' <<< "$line")

        local users_field
        users_field=$(grep -oP 'users:\(\("[^"]+",pid=\d+' <<< "$line" | head -1)
        proc=$(grep -oP '(?<=")[^"]+(?=",pid)' <<< "$users_field")
        pid=$(grep -oP '(?<=pid=)\d+' <<< "$users_field")

        [[ -n "$pid" ]] && user=$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ')

        printf "  %-8s %-20s %-25s %s\n" "$proto" "$addr" "${proc:-?}" "${user:-?}"
    done
}

# --- Main ---
main() {
    section "Open Connections"
    require_cmds ss

    show_listening
    show_connections
}

main "$@"
