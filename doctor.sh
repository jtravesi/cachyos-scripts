#!/usr/bin/env bash
# ============================================================
# doctor.sh
# Description : Full read-only system healthcheck. Runs a curated
#               set of checks across every category (boot, services,
#               packages, filesystems, SMART, security, network,
#               logs, memory, performance) and prints a per-check
#               OK/WARN/CRIT report plus an overall verdict.
#               Never modifies anything. Runs without root, but
#               root (sudo) unlocks SMART and a few extra checks.
# Dependencies: coreutils, systemctl, pacman, ss, ip, df, free,
#               journalctl; smartctl (optional, for SMART)
# Compatibility: CachyOS, Arch Linux (mostly any systemd Linux)
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=utils/common.sh
source "${SCRIPT_DIR}/utils/common.sh"

# --- Privilege detection (never prompts; degrades gracefully) ---
# RUNROOT is the prefix for root-only read commands, or "SKIP".
if [[ $EUID -eq 0 ]]; then
    RUNROOT=""
elif sudo -n true 2>/dev/null; then
    RUNROOT="sudo -n"
else
    RUNROOT="SKIP"
fi

# --- Tallies ---
T_OK=0; T_WARN=0; T_CRIT=0; T_SKIP=0

# --- Record + print one check result ---
# Usage: result OK|WARN|CRIT|INFO|SKIP "Label" "detail"
result() {
    local status="$1" label="$2" detail="${3:-}" sym
    case "$status" in
        OK)   sym="$OK";   T_OK=$((T_OK+1)) ;;
        WARN) sym="$WARN"; T_WARN=$((T_WARN+1)) ;;
        CRIT) sym="$ERR";  T_CRIT=$((T_CRIT+1)) ;;
        INFO) sym="$INFO" ;;
        SKIP) sym="[${YELLOW}-${RESET}]"; T_SKIP=$((T_SKIP+1)) ;;
    esac
    printf "  %b %-30s %s\n" "$sym" "$label" "$detail"
}

# True when root-only checks can run.
have_root() { [[ "$RUNROOT" != "SKIP" ]]; }
# Run a read-only command with root when possible.
asroot() { $RUNROOT "$@"; }

# ============================================================
# Checks
# ============================================================

check_system() {
    section "System & Boot"

    result INFO "Kernel" "$(uname -r)"
    result INFO "Uptime" "$(uptime -p 2>/dev/null | sed 's/^up //' || echo '?')"

    # Reboot needed: running kernel's module tree gone after an update.
    if [[ -d "/usr/lib/modules/$(uname -r)" ]]; then
        result OK "Running kernel" "module tree present (no reboot pending)"
    else
        result WARN "Running kernel" "modules for $(uname -r) missing — reboot likely needed"
    fi

    # Failed systemd units.
    local failed
    failed=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}')
    if [[ -z "$failed" ]]; then
        result OK "Failed services" "none"
    else
        local n; n=$(grep -c . <<< "$failed")
        result WARN "Failed services" "${n}: $(tr '\n' ' ' <<< "$failed")"
    fi

    # Load average vs logical CPUs.
    local load cpus
    load=$(awk '{print $1}' /proc/loadavg 2>/dev/null)
    cpus=$(nproc 2>/dev/null || echo 1)
    if [[ -n "$load" ]]; then
        if awk -v l="$load" -v c="$cpus" 'BEGIN{exit !(l > c*2)}'; then
            result WARN "Load (1m)" "${load} on ${cpus} CPUs — high"
        else
            result OK "Load (1m)" "${load} on ${cpus} CPUs"
        fi
    fi
}

check_packages() {
    section "Packages & Updates"
    command -v pacman &>/dev/null || { result SKIP "pacman" "not found"; return; }

    # Available updates per the local sync db (no network).
    local upd
    upd=$(pacman -Qu 2>/dev/null | grep -vc '\[ignored\]')
    [[ "$upd" =~ ^[0-9]+$ ]] || upd=0
    if (( upd == 0 )); then
        result OK "Available updates" "system up to date (per local db)"
    else
        result INFO "Available updates" "${upd} package(s) — run a sync to confirm"
    fi

    # Orphan packages.
    local orphans
    orphans=$(pacman -Qtdq 2>/dev/null | grep -c .)
    if (( orphans == 0 )); then
        result OK "Orphan packages" "none"
    else
        result INFO "Orphan packages" "${orphans} — review with: pacman -Qtdq"
    fi

    # Pacman cache size.
    local cache
    cache=$(du -sh /var/cache/pacman/pkg 2>/dev/null | awk '{print $1}')
    [[ -n "$cache" ]] && result INFO "Pacman cache" "${cache} (clean with paccache/clean-system.sh)"
}

check_filesystems() {
    section "Filesystems"

    local crit=0 warn=0
    while read -r pct target source; do
        local p="${pct%\%}"
        [[ "$p" =~ ^[0-9]+$ ]] || continue
        if   (( p >= 90 )); then result CRIT "Usage ${target}" "${pct} full (${source})"; crit=1
        elif (( p >= 75 )); then result WARN "Usage ${target}" "${pct} full (${source})"; warn=1
        fi
    done < <(df -hP --output=pcent,target,source -x tmpfs -x devtmpfs -x squashfs \
                -x overlay -x efivarfs 2>/dev/null | tail -n +2 | grep -v '/dev/loop')
    (( crit == 0 && warn == 0 )) && result OK "Disk usage" "all filesystems below 75%"

    # Inode pressure.
    local iwarn=0
    while read -r ipct target; do
        local p="${ipct%\%}"
        [[ "$p" =~ ^[0-9]+$ ]] || continue
        (( p >= 85 )) && { result WARN "Inodes ${target}" "${ipct} used"; iwarn=1; }
    done < <(df -iP --output=ipcent,target -x tmpfs -x devtmpfs 2>/dev/null | tail -n +2)
    (( iwarn == 0 )) && result OK "Inode usage" "all filesystems healthy"
}

check_smart() {
    section "Disk Health (SMART)"
    command -v smartctl &>/dev/null || { result SKIP "smartctl" "smartmontools not installed"; return; }
    if ! have_root; then
        result SKIP "SMART" "needs root — re-run with sudo for disk health"
        return
    fi

    local disks any=0
    mapfile -t disks < <(lsblk -dn -o NAME,TYPE 2>/dev/null \
        | awk '$2=="disk" && $1 !~ /^(zram|loop|sr|fd)/{print $1}')
    for d in "${disks[@]}"; do
        any=1
        local health
        health=$(asroot smartctl -H "/dev/$d" 2>/dev/null \
            | grep -iE 'overall-health|SMART Health Status' \
            | grep -oiE 'PASSED|FAILED|OK' | head -1)
        case "${health^^}" in
            PASSED|OK) result OK   "/dev/$d" "SMART health: PASSED" ;;
            FAILED)    result CRIT "/dev/$d" "SMART FAILED — back up now" ;;
            *)         result SKIP "/dev/$d" "SMART status unavailable" ;;
        esac
    done
    (( any == 0 )) && result SKIP "SMART" "no physical disks detected"
}

check_security() {
    section "Security"

    # SSH server exposure.
    if systemctl is-active sshd &>/dev/null || systemctl is-active ssh &>/dev/null; then
        local cfg permitroot passauth
        if have_root; then
            cfg=$(asroot sshd -T 2>/dev/null)
            permitroot=$(awk '/^permitrootlogin/{print $2}' <<< "$cfg")
            passauth=$(awk '/^passwordauthentication/{print $2}' <<< "$cfg")
        fi
        # Fall back to the on-disk config if sshd -T was unavailable.
        [[ -z "${permitroot:-}" ]] && permitroot=$(grep -ioP '^\s*PermitRootLogin\s+\K\S+' /etc/ssh/sshd_config 2>/dev/null | tail -1)
        [[ -z "${passauth:-}"   ]] && passauth=$(grep -ioP '^\s*PasswordAuthentication\s+\K\S+' /etc/ssh/sshd_config 2>/dev/null | tail -1)

        [[ "${permitroot,,}" == "yes" ]] \
            && result WARN "SSH root login" "PermitRootLogin yes" \
            || result OK   "SSH root login" "${permitroot:-default (prohibit-password)}"
        [[ "${passauth,,}" == "yes" ]] \
            && result WARN "SSH password auth" "enabled — prefer keys only" \
            || result OK   "SSH password auth" "${passauth:-disabled/default}"
    else
        result OK "SSH server" "not running"
    fi

    # Firewall presence.
    local fw=""
    for svc in ufw firewalld nftables iptables; do
        systemctl is-active "$svc" &>/dev/null && { fw="$svc"; break; }
    done
    if [[ -n "$fw" ]]; then
        result OK "Firewall" "active (${fw})"
    else
        result WARN "Firewall" "no firewall service active"
    fi

    # Public listening sockets (local address not on loopback).
    local pub
    pub=$(ss -tulnH 2>/dev/null \
        | awk '{print $5}' \
        | grep -vE '^(127\.0\.0\.1|\[::1\])' \
        | grep -cE ':[0-9]+$')
    [[ "$pub" =~ ^[0-9]+$ ]] || pub=0
    if (( pub == 0 )); then
        result OK "Listening ports" "none exposed beyond loopback"
    else
        result INFO "Listening ports" "${pub} non-loopback listener(s) — audit-open-ports.sh"
    fi

    # CVE scan, if arch-audit is around.
    if command -v arch-audit &>/dev/null; then
        local vuln
        vuln=$(arch-audit -q 2>/dev/null | grep -c .)
        if (( vuln == 0 )); then result OK "CVE (arch-audit)" "no vulnerable packages"
        else result WARN "CVE (arch-audit)" "${vuln} package(s) with advisories"; fi
    fi
}

check_network() {
    section "Network"

    if ip route show default 2>/dev/null | grep -q .; then
        local gw; gw=$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}')
        result OK "Default route" "via ${gw}"
    else
        result WARN "Default route" "none — no internet gateway"
    fi

    if getent hosts archlinux.org &>/dev/null; then
        result OK "DNS resolution" "archlinux.org resolves"
    else
        result WARN "DNS resolution" "could not resolve archlinux.org"
    fi
}

check_logs() {
    section "Logs"
    command -v journalctl &>/dev/null || { result SKIP "journalctl" "not found"; return; }

    local errs
    errs=$(journalctl -b -p 3 -q --no-pager 2>/dev/null | grep -c .)
    if [[ ! "$errs" =~ ^[0-9]+$ ]]; then
        result SKIP "Boot errors" "journal not readable (try sudo)"
    elif (( errs == 0 )); then
        result OK "Boot errors" "no error-priority messages this boot"
    elif (( errs > 50 )); then
        result WARN "Boot errors" "${errs} error-priority messages — boot-errors.sh"
    else
        result INFO "Boot errors" "${errs} error-priority message(s) this boot"
    fi
}

check_memory() {
    section "Memory"
    local total used avail spct
    read -r total used avail < <(free -m 2>/dev/null | awk '/^Mem:/{print $2, $3, $7}')
    [[ -n "$total" ]] || { result SKIP "Memory" "free unavailable"; return; }

    local upct=$(( used * 100 / total ))
    if   (( upct >= 90 )); then result WARN "RAM usage" "${upct}% (${used}/${total} MB, ${avail} MB available)"
    else result OK "RAM usage" "${upct}% (${used}/${total} MB, ${avail} MB available)"; fi

    # Swap pressure.
    read -r stotal sused < <(free -m 2>/dev/null | awk '/^Swap:/{print $2, $3}')
    if [[ "${stotal:-0}" -gt 0 ]]; then
        spct=$(( sused * 100 / stotal ))
        if (( spct >= 50 )); then result WARN "Swap usage" "${spct}% (${sused}/${stotal} MB)"
        else result OK "Swap usage" "${spct}% (${sused}/${stotal} MB)"; fi
    fi
}

check_performance() {
    section "Performance"

    local gov
    gov=$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort -u | tr '\n' ' ' | xargs)
    [[ -n "$gov" ]] && result INFO "CPU governor" "$gov"

    if [[ -r /sys/kernel/sched_ext/state ]]; then
        local st; st=$(cat /sys/kernel/sched_ext/state 2>/dev/null)
        if [[ "$st" == "enabled" ]]; then
            result INFO "scx scheduler" "active: $(cat /sys/kernel/sched_ext/root/ops 2>/dev/null)"
        else
            result INFO "scx scheduler" "disabled (in-kernel default)"
        fi
    fi
}

# ============================================================
# Summary
# ============================================================
summary() {
    section "Summary"
    printf "  ${GREEN}%d OK${RESET}   ${YELLOW}%d warn${RESET}   ${RED}%d crit${RESET}   %d skipped\n" \
        "$T_OK" "$T_WARN" "$T_CRIT" "$T_SKIP"
    echo ""
    if   (( T_CRIT > 0 )); then
        error "Critical issues found — address the items marked ✗ above."
    elif (( T_WARN > 0 )); then
        warn "Some items need attention — review the ! warnings above."
    else
        ok "System looks healthy."
    fi
    [[ "$RUNROOT" == "SKIP" ]] && info "Run with ${BOLD}sudo${RESET} for SMART and other root-only checks."
}

# ============================================================
main() {
    section "CachyOS System Doctor"
    info "Read-only healthcheck — nothing will be modified."
    [[ "$RUNROOT" == "SKIP" ]] && info "Running as user; some checks need sudo for full coverage."

    check_system
    check_packages
    check_filesystems
    check_smart
    check_security
    check_network
    check_logs
    check_memory
    check_performance
    summary

    (( T_CRIT > 0 )) && exit 2
    (( T_WARN > 0 )) && exit 1
    exit 0
}

main "$@"
