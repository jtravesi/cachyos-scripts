#!/usr/bin/env bash
# ============================================================
# audit-open-ports.sh
# Description : Lists listening TCP/UDP ports with owning process,
#               user and package. Classifies each by exposure scope
#               (local / link-local / LAN / public) and cross-checks
#               against the active firewall when possible. Read-only.
# Dependencies: ss (iproute2), pacman, awk, readlink
# Compatibility: Arch-based
# ============================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

# --- Firewall detection ---

FW_NAME=""
FW_ACTIVE=0
FW_RULES=""
FW_DEFAULT_IN=""    # deny | allow | unknown — default INPUT policy

detect_firewall() {
    # ufw — frontend over iptables/nft, easy to parse
    if command -v ufw &>/dev/null; then
        local status
        status=$(ufw status verbose 2>/dev/null || ufw status 2>/dev/null || true)
        if echo "$status" | grep -q "Status: active"; then
            FW_NAME="ufw"
            FW_ACTIVE=1
            FW_RULES="$status"
            # "Default: deny (incoming), allow (outgoing), disabled (routed)"
            FW_DEFAULT_IN=$(echo "$status" | sed -nE 's/^Default: ([a-z]+) \(incoming\).*/\1/p')
            [[ -z "$FW_DEFAULT_IN" ]] && FW_DEFAULT_IN="unknown"
            return
        fi
    fi

    # firewalld
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        FW_NAME="firewalld"
        FW_ACTIVE=1
        local zone ports services target
        zone=$(firewall-cmd --get-default-zone 2>/dev/null || echo "")
        ports=$(firewall-cmd --list-ports 2>/dev/null || true)
        services=$(firewall-cmd --list-services 2>/dev/null || true)
        target=$(firewall-cmd --permanent --zone="$zone" --get-target 2>/dev/null || echo "default")
        FW_RULES="zone: ${zone}"$'\n'"ports: ${ports}"$'\n'"services: ${services}"
        case "$target" in
            ACCEPT|default)       FW_DEFAULT_IN="allow" ;;
            DROP|REJECT|"%%REJECT%%") FW_DEFAULT_IN="deny" ;;
            *)                    FW_DEFAULT_IN="unknown" ;;
        esac
        return
    fi

    # nftables — check for any non-empty ruleset
    if command -v nft &>/dev/null; then
        local nft_out
        nft_out=$(nft list ruleset 2>/dev/null || true)
        if echo "$nft_out" | grep -qE '\bchain\b'; then
            FW_NAME="nftables"
            FW_ACTIVE=1
            FW_RULES="$nft_out"
            # Look for input chain policy: "type filter hook input priority 0; policy drop;"
            if echo "$nft_out" | grep -E 'hook input' | grep -qi 'policy drop'; then
                FW_DEFAULT_IN="deny"
            elif echo "$nft_out" | grep -E 'hook input' | grep -qi 'policy accept'; then
                FW_DEFAULT_IN="allow"
            else
                FW_DEFAULT_IN="unknown"
            fi
            return
        fi
    fi

    # iptables — check for non-default rules
    if command -v iptables &>/dev/null; then
        local ipt_out
        ipt_out=$(iptables -L INPUT -n 2>/dev/null || true)
        local rule_count
        rule_count=$(echo "$ipt_out" | tail -n +3 | grep -cvE '^\s*$' || true)
        if [[ "$rule_count" -gt 0 ]]; then
            FW_NAME="iptables"
            FW_ACTIVE=1
            FW_RULES="$ipt_out"
            # "Chain INPUT (policy DROP)" or "(policy ACCEPT)"
            if echo "$ipt_out" | head -1 | grep -qi 'policy DROP'; then
                FW_DEFAULT_IN="deny"
            elif echo "$ipt_out" | head -1 | grep -qi 'policy ACCEPT'; then
                FW_DEFAULT_IN="allow"
            else
                FW_DEFAULT_IN="unknown"
            fi
            return
        fi
    fi

    FW_NAME="none"
    FW_ACTIVE=0
}

# Best-effort: how is this port handled by the firewall?
# Returns: allow | deny | default-deny | default-allow | unknown | n/a
firewall_check_port() {
    local port="$1" proto="$2"
    [[ "$FW_ACTIVE" -eq 0 ]] && { echo "n/a"; return; }

    local explicit=""
    case "$FW_NAME" in
        ufw)
            # Lines look like: "22/tcp   ALLOW IN    Anywhere"
            local match
            match=$(echo "$FW_RULES" | grep -E "(^|[^0-9])${port}(/${proto})?\b" | grep -iE "ALLOW|DENY|REJECT" | head -1)
            if [[ -n "$match" ]]; then
                if echo "$match" | grep -qi "ALLOW"; then explicit="allow"
                else explicit="deny"
                fi
            fi
            ;;
        firewalld)
            if echo "$FW_RULES" | grep -qw "${port}/${proto}"; then
                explicit="allow"
            fi
            ;;
        nftables|iptables)
            local match
            match=$(echo "$FW_RULES" | grep -E "dport[s]?[[:space:]]+(\{[[:space:]]*)?${port}([,[:space:]}]|$)" | head -1)
            if [[ -n "$match" ]]; then
                if echo "$match" | grep -qiE "accept"; then explicit="allow"
                elif echo "$match" | grep -qiE "drop|reject"; then explicit="deny"
                fi
            fi
            ;;
    esac

    if [[ -n "$explicit" ]]; then
        echo "$explicit"
        return
    fi

    # No explicit rule — fall back to default policy
    case "$FW_DEFAULT_IN" in
        deny|reject) echo "default-deny" ;;
        allow)       echo "default-allow" ;;
        *)           echo "unknown" ;;
    esac
}

# --- Bind address classification ---
# Echoes: local | linklocal | lan | public
classify_bind() {
    local bind="$1"
    case "$bind" in
        127.*|::1|::ffff:127.*)            echo local ;;
        169.254.*|fe80:*|fe80::*)          echo linklocal ;;
        10.*|192.168.*)                    echo lan ;;
        172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) echo lan ;;
        fc*:*|fd*:*)                       echo lan ;;  # ULA IPv6
        0.0.0.0|::|*)                      echo public ;;
    esac
}

# --- Process resolution ---

# Given a pid, echo "exe_path|user|package|deleted_flag"
resolve_process() {
    local pid="$1"
    local exe pkg user deleted=0

    exe=$(readlink "/proc/${pid}/exe" 2>/dev/null || echo "")
    if [[ "$exe" == *" (deleted)" ]]; then
        deleted=1
        exe="${exe% (deleted)}"
    fi

    # User
    local uid
    uid=$(awk '/^Uid:/ {print $2; exit}' "/proc/${pid}/status" 2>/dev/null || echo "")
    if [[ -n "$uid" ]]; then
        user=$(getent passwd "$uid" 2>/dev/null | cut -d: -f1)
        [[ -z "$user" ]] && user="uid=$uid"
    else
        user="?"
    fi

    # Package
    if [[ -n "$exe" ]]; then
        pkg=$(pacman -Qo "$exe" 2>/dev/null | awk '{print $(NF-1)}')
        [[ -z "$pkg" ]] && pkg="orphan"
    else
        pkg="?"
    fi

    echo "${exe}|${user}|${pkg}|${deleted}"
}

# --- Main ---

usage() {
    cat <<EOF
Usage: $(basename "$0") [-h|--help]

Lists all listening TCP/UDP sockets and classifies each by network
exposure (local / LAN / public). Cross-checks against the active
firewall (ufw, firewalld, nftables, iptables) on a best-effort basis.

Run as root to resolve all process owners.
EOF
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac

require_cmds ss awk readlink

if [[ "$EUID" -ne 0 ]]; then
    warn "Running without root — some process owners may not be resolvable."
fi

section "Listening ports audit"

detect_firewall
if [[ "$FW_ACTIVE" -eq 1 ]]; then
    info "Active firewall detected: ${BOLD}${FW_NAME}${RESET}"
else
    warn "No active firewall detected (checked ufw, firewalld, nftables, iptables)"
fi
echo ""

# Collect listening sockets
# Output format from ss -H -tulnp:
#   tcp   LISTEN 0 128  0.0.0.0:22        0.0.0.0:*  users:(("sshd",pid=1234,fd=3))
#   udp   UNCONN 0 0    127.0.0.1:323     0.0.0.0:*  users:(("chronyd",pid=567,fd=5))

declare -a LOCAL=() LINKLOCAL=() LAN=() PUBLIC=()

while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    proto=$(echo "$line" | awk '{print $1}')
    bind_port=$(echo "$line" | awk '{print $5}')
    proc_field=$(echo "$line" | awk '{for(i=6;i<=NF;i++) if($i ~ /^users:/) print $i}')

    # Split bind:port. IPv6 binds come bracketed as [addr]:port or
    # [addr]%zone:port; IPv4 is plain addr:port.
    if [[ "$bind_port" == \[* ]]; then
        bind="${bind_port#[}"
        bind="${bind%%]*}"
        suffix="${bind_port##*]}"
        port="${suffix##*:}"
    else
        bind="${bind_port%:*}"
        port="${bind_port##*:}"
    fi

    # Extract process name and pid
    proc_name=""
    pid=""
    if [[ -n "$proc_field" ]]; then
        proc_name=$(echo "$proc_field" | sed -nE 's/.*"([^"]+)".*/\1/p' | head -1)
        pid=$(echo "$proc_field" | sed -nE 's/.*pid=([0-9]+).*/\1/p' | head -1)
    fi

    # Resolve owner / package / deleted
    user="?"; pkg="?"; deleted=0; exe=""
    if [[ -n "$pid" ]]; then
        IFS='|' read -r exe user pkg deleted <<<"$(resolve_process "$pid")"
    fi

    class=$(classify_bind "$bind")
    fw_state=$(firewall_check_port "$port" "$proto")

    # Pack record: bind|port|proto|proc|pid|user|pkg|deleted|fw_state
    record="${bind}|${port}|${proto}|${proc_name:-?}|${pid:-?}|${user}|${pkg}|${deleted}|${fw_state}"

    case "$class" in
        local)     LOCAL+=("$record") ;;
        linklocal) LINKLOCAL+=("$record") ;;
        lan)       LAN+=("$record") ;;
        public)    PUBLIC+=("$record") ;;
    esac
done < <(ss -H -tulnp 2>/dev/null)

# --- Report ---

print_record() {
    local color="$1" symbol="$2" tag="$3" rec="$4"
    IFS='|' read -r bind port proto proc pid user pkg deleted fw_state <<<"$rec"

    local flags=""
    [[ "$deleted" == "1" ]] && flags+=" ${RED}[DELETED EXE]${RESET}"
    [[ "$pkg" == "orphan" ]] && flags+=" ${RED}[orphan]${RESET}"

    local fw_marker=""
    case "$fw_state" in
        allow)         fw_marker="${YELLOW}fw:allow${RESET}" ;;
        deny)          fw_marker="${GREEN}fw:deny${RESET}" ;;
        default-deny)  fw_marker="${GREEN}fw:default-deny${RESET}" ;;
        default-allow) fw_marker="${RED}fw:default-allow${RESET}" ;;
        unknown)       fw_marker="${YELLOW}fw:unknown${RESET}" ;;
        n/a)           fw_marker="" ;;
    esac

    printf "    ${color}%s${RESET} %-5s %-22s %-15s %-10s %-18s" \
        "$symbol" "$proto" "${bind}:${port}" "$proc" "$user" "[${pkg}]"

    if [[ -n "$tag" ]]; then
        printf " ${color}%s${RESET}" "$tag"
    fi
    if [[ -n "$fw_marker" ]]; then
        printf " %b" "$fw_marker"
    fi
    if [[ -n "$flags" ]]; then
        printf " %b" "$flags"
    fi
    echo ""
}

print_section() {
    local color="$1" symbol="$2" tag="$3" title="$4"
    shift 4
    local items=("$@")
    echo -e "\n${BOLD}${title}${RESET} (${#items[@]})"
    if [[ ${#items[@]} -eq 0 ]]; then
        echo "    (none)"
        return
    fi
    for r in "${items[@]}"; do
        print_record "$color" "$symbol" "$tag" "$r"
    done
}

print_section "$GREEN"  "✓" ""        "Local only"        "${LOCAL[@]}"
print_section "$GREEN"  "✓" "(LAN)"   "LAN exposure"      "${LAN[@]}"
print_section "$CYAN"   "i" "(link)"  "Link-local"        "${LINKLOCAL[@]}"
print_section "$RED"    "✗" "PUBLIC"  "Public exposure"   "${PUBLIC[@]}"

# --- Summary ---

section "Summary"
total=$(( ${#LOCAL[@]} + ${#LINKLOCAL[@]} + ${#LAN[@]} + ${#PUBLIC[@]} ))
echo "    Total listening sockets: ${total}"
echo -e "      ${GREEN}Local:${RESET}       ${#LOCAL[@]}"
echo -e "      ${GREEN}LAN:${RESET}         ${#LAN[@]}"
echo    "      Link-local:  ${#LINKLOCAL[@]}"
echo -e "      ${RED}Public:${RESET}      ${#PUBLIC[@]}"

echo ""
if [[ "$FW_ACTIVE" -eq 1 ]]; then
    case "$FW_DEFAULT_IN" in
        deny|reject) policy_str="${GREEN}default-deny${RESET}" ;;
        allow)       policy_str="${RED}default-allow${RESET}" ;;
        *)           policy_str="${YELLOW}policy unknown${RESET}" ;;
    esac
    echo -e "    Firewall:    ${GREEN}${FW_NAME} (active)${RESET} — incoming: ${policy_str}"
else
    echo -e "    Firewall:    ${RED}none active${RESET}"
fi

# Exit code: 0 if only local, 1 if any LAN/Public
if [[ ${#PUBLIC[@]} -gt 0 || ${#LAN[@]} -gt 0 ]]; then
    if [[ ${#PUBLIC[@]} -gt 0 && "$FW_ACTIVE" -eq 0 ]]; then
        echo ""
        warn "Public-facing ports with no active firewall — high risk."
    fi
    exit 1
fi

exit 0
