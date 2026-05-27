#!/usr/bin/env bash
# ============================================================
# audit-firewall.sh
# Description : Audits the active firewall configuration (ufw,
#               firewalld, nftables or iptables). Reports status,
#               default policies, parsed rules, stale rules (no
#               listener behind them), IPv6 parity and common
#               anti-patterns (SSH/DB exposed to the world, etc.).
#               Read-only — never modifies the firewall.
# Dependencies: ss, awk, grep. Backend-specific tools as detected.
# Compatibility: Any Linux
# ============================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

VERBOSE=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
    -v, --verbose    Show full ruleset (raw)
    -h, --help       Show this help

Audits the active firewall and reports stale rules, IPv6 parity and
anti-patterns. Read-only. Run as root for full visibility.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--verbose) VERBOSE=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *) error "Unknown option: $1"; usage; exit 2 ;;
    esac
done

require_cmds ss awk grep

[[ "$EUID" -ne 0 ]] && warn "Running without root — most firewall backends will return partial or no data."

# --- Sensitive ports for anti-pattern detection ---
# Format: "port/proto:label:severity" where severity is HIGH or WARN
# Public-facing services (80/443) are OK from anywhere — not listed.
SENSITIVE_PORTS=(
    "22/tcp:SSH:WARN"
    "23/tcp:Telnet:HIGH"
    "3306/tcp:MySQL/MariaDB:HIGH"
    "5432/tcp:PostgreSQL:HIGH"
    "27017/tcp:MongoDB:HIGH"
    "6379/tcp:Redis:HIGH"
    "9200/tcp:Elasticsearch:HIGH"
    "11211/tcp:Memcached:HIGH"
    "445/tcp:SMB:HIGH"
    "139/tcp:NetBIOS:HIGH"
    "2049/tcp:NFS:HIGH"
    "3389/tcp:RDP:HIGH"
    "5900/tcp:VNC:HIGH"
    "5984/tcp:CouchDB:HIGH"
    "8086/tcp:InfluxDB:WARN"
    "5601/tcp:Kibana:WARN"
)

# --- Backend detection ---

FW_NAME=""
FW_ACTIVE=0
FW_DEFAULT_IN=""
FW_DEFAULT_OUT=""
FW_DEFAULT_ROUTED=""
FW_RAW=""

detect_backend() {
    if command -v ufw &>/dev/null; then
        local status
        status=$(ufw status verbose 2>/dev/null || true)
        if echo "$status" | grep -q "Status: active"; then
            FW_NAME="ufw"; FW_ACTIVE=1; FW_RAW="$status"
            FW_DEFAULT_IN=$(echo "$status"     | sed -nE 's/^Default: ([a-z]+) \(incoming\).*/\1/p')
            FW_DEFAULT_OUT=$(echo "$status"    | sed -nE 's/.* ([a-z]+) \(outgoing\).*/\1/p')
            FW_DEFAULT_ROUTED=$(echo "$status" | sed -nE 's/.* ([a-z]+) \(routed\).*/\1/p')
            return
        fi
    fi

    if systemctl is-active --quiet firewalld 2>/dev/null; then
        FW_NAME="firewalld"; FW_ACTIVE=1
        FW_RAW=$(firewall-cmd --list-all-zones 2>/dev/null || true)
        FW_DEFAULT_IN="zone-based"
        return
    fi

    if command -v nft &>/dev/null; then
        local nft_out
        nft_out=$(nft list ruleset 2>/dev/null || true)
        if echo "$nft_out" | grep -qE '\bchain\b'; then
            FW_NAME="nftables"; FW_ACTIVE=1; FW_RAW="$nft_out"
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

    if command -v iptables &>/dev/null; then
        local ipt_out rule_count
        ipt_out=$(iptables -L -n 2>/dev/null || true)
        rule_count=$(echo "$ipt_out" | grep -cE '^(ACCEPT|DROP|REJECT)' || true)
        if [[ "$rule_count" -gt 0 ]]; then
            FW_NAME="iptables"; FW_ACTIVE=1; FW_RAW="$ipt_out"
            FW_DEFAULT_IN=$(iptables -L INPUT -n 2>/dev/null | head -1 | sed -nE 's/.*policy ([A-Z]+).*/\1/p' | tr '[:upper:]' '[:lower:]')
            [[ "$FW_DEFAULT_IN" == "drop" ]] && FW_DEFAULT_IN="deny"
            [[ "$FW_DEFAULT_IN" == "accept" ]] && FW_DEFAULT_IN="allow"
            return
        fi
    fi

    FW_NAME="none"; FW_ACTIVE=0
}

# --- ufw rule parsing ---
# Outputs one rule per line: action|port|proto|target|source|family
# family: v4 | v6
# port  : numeric port, or "any" (when target is a name like "Anywhere" or "OpenSSH")
# target: the full "To" field (e.g. "22/tcp", "Anywhere on virbr0", "OpenSSH")
# source: the full "From" field
ufw_rules() {
    # Rules table starts after the "To ... Action ... From" header.
    echo "$FW_RAW" | awk '
        /^To[[:space:]]+Action[[:space:]]+From/ { capture=1; next }
        capture && NF>0 && $1 !~ /^-+/ { print }
    ' | while IFS= read -r line; do
        local family="v4"
        [[ "$line" == *"(v6)"* ]] && family="v6"

        # Split the line on the ACTION token. Action format: (ALLOW|DENY|REJECT|LIMIT) (IN|OUT|FWD)
        # Whatever precedes the action is the target; whatever follows is the source.
        local target action source
        if [[ "$line" =~ ^(.+[[:space:]]+)((ALLOW|DENY|REJECT|LIMIT)[[:space:]]+(IN|OUT|FWD))[[:space:]]+(.+)$ ]]; then
            target="${BASH_REMATCH[1]}"
            action="${BASH_REMATCH[2]}"
            source="${BASH_REMATCH[5]}"
        else
            continue
        fi

        # Strip (v6) markers and trim whitespace
        target=$(echo "$target" | sed -E 's/\(v6\)//g' | awk '{$1=$1; print}')
        source=$(echo "$source" | sed -E 's/\(v6\)//g' | awk '{$1=$1; print}')

        # Parse port/proto from target
        local port proto
        if [[ "$target" =~ ^([0-9]+)/(tcp|udp)$ ]]; then
            port="${BASH_REMATCH[1]}"
            proto="${BASH_REMATCH[2]}"
        elif [[ "$target" =~ ^([0-9]+)$ ]]; then
            port="${BASH_REMATCH[1]}"
            proto="any"
        else
            # "Anywhere", "Anywhere on virbr0", app profile name, etc.
            port="any"
            proto="any"
        fi

        echo "${action}|${port}|${proto}|${target}|${source}|${family}"
    done
}

# --- Listening sockets snapshot ---
LISTENING_PORTS=""
collect_listening() {
    # Output: "port/proto" per line, deduped
    LISTENING_PORTS=$(ss -H -tulnp 2>/dev/null | awk '{print $1, $5}' | while read -r proto bp; do
        local port
        if [[ "$bp" == \[* ]]; then
            local suffix="${bp##*]}"
            port="${suffix##*:}"
        else
            port="${bp##*:}"
        fi
        echo "${port}/${proto}"
    done | sort -u)
}

is_listening() {
    local port="$1" proto="$2"
    if [[ "$proto" == "any" ]]; then
        echo "$LISTENING_PORTS" | grep -qE "^${port}/(tcp|udp)$"
    else
        echo "$LISTENING_PORTS" | grep -qE "^${port}/${proto}$"
    fi
}

# --- Anti-pattern checks ---
# Returns "HIGH|label" or "WARN|label" or "" if not sensitive.
sensitivity_of() {
    local port="$1" proto="$2"
    local entry
    for entry in "${SENSITIVE_PORTS[@]}"; do
        local key="${entry%%:*}"
        local rest="${entry#*:}"
        local label="${rest%:*}"
        local sev="${rest##*:}"
        if [[ "$key" == "${port}/${proto}" ]]; then
            echo "${sev}|${label}"
            return
        fi
    done
}

# Is a source string "from anywhere" (truly wide open, not interface-scoped)?
# "Anywhere on virbr0" is NOT wide open — it's scoped to that interface.
is_wide_open() {
    local src="$1"
    case "$src" in
        Anywhere|""|0.0.0.0/0|"::/0") return 0 ;;
        *) return 1 ;;
    esac
}

# Is a target an interface-scoped destination (e.g. "Anywhere on virbr0")?
is_interface_scoped() {
    [[ "$1" =~ \ on\ [a-zA-Z0-9._-]+$ ]]
}

# --- Report sections ---

print_status() {
    section "Status"
    if [[ "$FW_ACTIVE" -eq 1 ]]; then
        ok "Backend: ${BOLD}${FW_NAME}${RESET} (active)"
    else
        error "No active firewall detected"
        return
    fi

    case "$FW_DEFAULT_IN" in
        deny|reject) ok "Default incoming: ${GREEN}${FW_DEFAULT_IN}${RESET}" ;;
        allow)       error "Default incoming: ${RED}allow${RESET} — every port is open unless explicitly blocked" ;;
        zone-based)  info "Default incoming: zone-based (firewalld)" ;;
        unknown|"")  warn "Default incoming: unknown" ;;
        *)           info "Default incoming: ${FW_DEFAULT_IN}" ;;
    esac

    [[ -n "$FW_DEFAULT_OUT" ]]    && info "Default outgoing: ${FW_DEFAULT_OUT}"
    [[ -n "$FW_DEFAULT_ROUTED" ]] && info "Default routed:   ${FW_DEFAULT_ROUTED}"
}

print_rules() {
    section "Rules"

    case "$FW_NAME" in
        ufw)
            local rules
            rules=$(ufw_rules)
            if [[ -z "$rules" ]]; then
                info "No explicit rules — only the default policy applies."
                return
            fi
            printf "    %-10s %-25s %-25s %s\n" "ACTION"   "TO"   "FROM" "FAMILY"
            printf "    %-10s %-25s %-25s %s\n" "------"   "--"   "----" "------"
            local action port proto target source family
            while IFS='|' read -r action port proto target source family; do
                local color="$CYAN"
                case "$action" in
                    *DENY*|*REJECT*) color="$RED" ;;
                    *ALLOW*)         color="$GREEN" ;;
                    *LIMIT*)         color="$YELLOW" ;;
                esac
                printf "    ${color}%-10s${RESET} %-25s %-25s %s\n" "$action" "$target" "$source" "$family"
            done <<<"$rules"
            ;;
        firewalld)
            echo "$FW_RAW" | sed 's/^/    /'
            ;;
        nftables|iptables)
            if [[ "$VERBOSE" -eq 1 ]]; then
                echo "$FW_RAW" | sed 's/^/    /'
            else
                info "Use --verbose to dump the full ${FW_NAME} ruleset."
                echo "$FW_RAW" | head -20 | sed 's/^/    /'
                local total
                total=$(echo "$FW_RAW" | wc -l)
                [[ "$total" -gt 20 ]] && echo -e "    ${CYAN}... (${total} lines total — use --verbose)${RESET}"
            fi
            ;;
    esac
}

print_stale() {
    section "Stale rules"

    if [[ "$FW_NAME" != "ufw" ]]; then
        info "Stale-rule detection only implemented for ufw."
        return
    fi

    local stale=()
    local rules
    rules=$(ufw_rules)
    [[ -z "$rules" ]] && { ok "No rules to check."; return; }

    local seen=""   # dedupe by port/proto across v4/v6
    local action port proto target source family
    while IFS='|' read -r action port proto target source family; do
        [[ "$action" != *"ALLOW IN"* ]] && continue
        [[ "$port" =~ ^[0-9]+$ ]] || continue
        local key="${port}/${proto}"
        [[ ",$seen," == *",${key},"* ]] && continue
        seen="${seen},${key}"

        if ! is_listening "$port" "$proto"; then
            stale+=("${port}/${proto}|${source}")
        fi
    done <<<"$rules"

    if [[ ${#stale[@]} -eq 0 ]]; then
        ok "All allowed ports have a listening socket."
        return
    fi

    warn "${#stale[@]} allow rule(s) have no matching listener:"
    local entry
    for entry in "${stale[@]}"; do
        IFS='|' read -r portproto source <<<"$entry"
        printf "    ${YELLOW}!${RESET} %-12s from %s\n" "$portproto" "$source"
    done
    echo -e "    ${CYAN}↳ Consider removing if the service is no longer in use: ufw delete allow <port>${RESET}"
}

print_ipv6_parity() {
    section "IPv6 parity"

    if [[ "$FW_NAME" != "ufw" ]]; then
        info "IPv6 parity check only implemented for ufw (other backends manage v4/v6 jointly or require separate review)."
        return
    fi

    local v4=() v6=()
    local action port proto target source family
    while IFS='|' read -r action port proto target source family; do
        [[ "$action" != *ALLOW* ]] && continue
        # Skip non-numeric ports — IPv6 parity check is per-port only
        [[ "$port" =~ ^[0-9]+$ ]] || continue
        local key="${port}/${proto}"
        if [[ "$family" == "v4" ]]; then
            v4+=("$key")
        else
            v6+=("$key")
        fi
    done < <(ufw_rules)

    local missing=()
    local k
    for k in "${v4[@]}"; do
        local found=0
        local k6
        for k6 in "${v6[@]}"; do
            [[ "$k" == "$k6" ]] && { found=1; break; }
        done
        [[ "$found" -eq 0 ]] && missing+=("$k")
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        ok "All IPv4 allow rules have an IPv6 counterpart."
    else
        warn "${#missing[@]} IPv4 rule(s) without IPv6 counterpart:"
        for k in "${missing[@]}"; do
            echo -e "    ${YELLOW}!${RESET} ${k}"
        done
    fi
}

ANTI_FAIL=0

print_antipatterns() {
    section "Anti-patterns"

    if [[ "$FW_NAME" != "ufw" ]]; then
        info "Anti-pattern detection only implemented for ufw."
        return
    fi

    local issues=0
    local action port proto target source family
    while IFS='|' read -r action port proto target source family; do
        [[ "$action" != *"ALLOW IN"* ]] && continue

        # Interface-scoped rules ("Anywhere on virbr0") are not wide open
        is_interface_scoped "$target" && continue

        # Sensitive port + wide-open source = anti-pattern
        local sens
        sens=$(sensitivity_of "$port" "$proto")
        if [[ -n "$sens" && $(is_wide_open "$source" && echo 1) == "1" ]]; then
            local sev="${sens%%|*}"
            local label="${sens##*|}"
            if [[ "$sev" == "HIGH" ]]; then
                error "${port}/${proto} (${label}) allowed from anywhere — HIGH risk"
                ANTI_FAIL=1
            else
                warn "${port}/${proto} (${label}) allowed from anywhere — consider restricting source"
            fi
            issues=$((issues + 1))
        fi
    done < <(ufw_rules)

    # Duplicate rules — include action in dedup key so OUT and FWD with same
    # target/source don't appear as dupes of each other.
    local dupes
    dupes=$(ufw_rules | awk -F'|' '{print $1"|"$4"|"$5"|"$6}' | sort | uniq -d)
    if [[ -n "$dupes" ]]; then
        warn "Duplicate rules detected:"
        echo "$dupes" | sed 's/^/    ! /'
        issues=$((issues + 1))
    fi

    [[ "$issues" -eq 0 ]] && ok "No anti-patterns detected."
}

# --- Main ---

section "Firewall audit"

detect_backend

if [[ "$FW_ACTIVE" -eq 0 ]]; then
    error "No active firewall detected (checked ufw, firewalld, nftables, iptables)."
    error "Your system is relying solely on listening daemon binds — recommended to enable a firewall."
    exit 1
fi

collect_listening

print_status
print_rules
print_stale
print_ipv6_parity
print_antipatterns

# --- Summary ---

section "Summary"
echo -e "    Backend:        ${BOLD}${FW_NAME}${RESET} (active)"
echo -e "    Default in:     ${FW_DEFAULT_IN:-unknown}"
[[ -n "$FW_DEFAULT_OUT" ]]    && echo -e "    Default out:    ${FW_DEFAULT_OUT}"
[[ -n "$FW_DEFAULT_ROUTED" ]] && echo -e "    Default routed: ${FW_DEFAULT_ROUTED}"

if [[ "$ANTI_FAIL" -eq 1 ]]; then
    echo ""
    error "HIGH-risk anti-patterns detected — review above."
    exit 1
fi

exit 0
