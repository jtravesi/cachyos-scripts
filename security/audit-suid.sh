#!/usr/bin/env bash
# ============================================================
# audit-suid.sh
# Description : Audits SUID/SGID binaries on the system. Classifies
#               each finding as Expected (standard Arch baseline),
#               Unusual (owned by a package but not in baseline) or
#               Suspicious (orphan or located in user/temp paths).
#               Read-only — reports only, never modifies.
# Dependencies: find, pacman, stat
# Compatibility: Arch-based
# ============================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

# --- Config ---

# Paths to scan. Stays on root filesystem (-xdev).
SCAN_PATHS=(/usr /opt /home /tmp /var /srv /root)

# Paths to skip entirely (container/VM image storage). The SUID bits
# inside these are normal for guest rootfs and not operative on the host.
EXCLUDE_PATHS=(
    /var/lib/containerd
    /var/lib/docker
    /var/lib/podman
    /var/lib/containers
    /var/lib/libvirt
    /var/lib/machines
    /var/lib/lxc
    /var/lib/lxd
)

# Paths where SUID/SGID is *never* expected — auto-suspicious.
SUSPICIOUS_PATH_PREFIXES=(/home /tmp /var/tmp /dev/shm /root)

# Baseline of expected SUID/SGID binaries on a standard Arch/CachyOS system.
# Match by basename — simpler and resilient to /usr/bin vs /usr/sbin moves.
EXPECTED_BASELINE=(
    sudo su mount umount passwd chage gpasswd newgrp
    chfn chsh ping pkexec polkit-agent-helper-1
    fusermount fusermount3 unix_chkpwd write ssh-agent
    crontab expiry sg suexec
    mount.cifs mount.nfs umount.nfs
    wall
)

# --- Helpers ---

is_expected() {
    local name="$1"
    for e in "${EXPECTED_BASELINE[@]}"; do
        [[ "$name" == "$e" ]] && return 0
    done
    return 1
}

is_in_suspicious_path() {
    local path="$1"
    for prefix in "${SUSPICIOUS_PATH_PREFIXES[@]}"; do
        [[ "$path" == "$prefix"/* ]] && return 0
    done
    return 1
}

# Returns the package owning a path, or empty string if orphan.
pkg_owner() {
    local path="$1"
    pacman -Qo "$path" 2>/dev/null | awk '{print $(NF-1)}'
}

# Returns "SUID", "SGID" or "SUID+SGID".
bit_type() {
    local path="$1"
    local mode
    mode=$(stat -c '%a' "$path" 2>/dev/null) || { echo "?"; return; }
    # Pad to 4 chars
    while [[ ${#mode} -lt 4 ]]; do mode="0$mode"; done
    local special="${mode:0:1}"
    case "$special" in
        4) echo "SUID" ;;
        2) echo "SGID" ;;
        6) echo "SUID+SGID" ;;
        7) echo "SUID+SGID+sticky" ;;
        *) echo "?" ;;
    esac
}

# --- Main ---

usage() {
    cat <<EOF
Usage: $(basename "$0") [-h|--help]

Audits SUID/SGID binaries on the root filesystem and classifies each
finding as Expected, Unusual or Suspicious. Read-only.

Run as root to also scan /root.
EOF
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac

require_cmds find pacman stat

if [[ "$EUID" -ne 0 ]]; then
    warn "Running without root — /root will be skipped and some files may be unreadable."
fi

section "SUID/SGID audit"

info "Scanning: ${SCAN_PATHS[*]}"
info "Building baseline of ${#EXPECTED_BASELINE[@]} expected binaries..."
echo ""

# Buckets
declare -a EXPECTED=()
declare -a UNUSUAL=()
declare -a SUSPICIOUS=()

# Build a list of existing scan paths (skip /root if not readable)
existing_paths=()
for p in "${SCAN_PATHS[@]}"; do
    [[ -d "$p" && -r "$p" ]] && existing_paths+=("$p")
done

# Build find prune expression for excluded paths
prune_args=()
for ex in "${EXCLUDE_PATHS[@]}"; do
    prune_args+=( -path "$ex" -o )
done
# Trim trailing -o
[[ ${#prune_args[@]} -gt 0 ]] && unset 'prune_args[${#prune_args[@]}-1]'

# Single find pass, NUL-delimited for safety with weird filenames.
while IFS= read -r -d '' file; do
    name=$(basename "$file")
    pkg=$(pkg_owner "$file")
    bits=$(bit_type "$file")

    if is_in_suspicious_path "$file"; then
        # Anything SUID in /home, /tmp, /root, etc. is suspicious regardless of package
        SUSPICIOUS+=("${file}|${pkg:-orphan}|${bits}|path")
    elif is_expected "$name"; then
        EXPECTED+=("${file}|${pkg:-orphan}|${bits}")
    elif [[ -z "$pkg" ]]; then
        SUSPICIOUS+=("${file}|orphan|${bits}|orphan")
    else
        UNUSUAL+=("${file}|${pkg}|${bits}")
    fi
done < <(find "${existing_paths[@]}" -xdev \
    \( "${prune_args[@]}" \) -prune -o \
    -type f \( -perm -4000 -o -perm -2000 \) -print0 2>/dev/null)

# --- Report ---

print_bucket() {
    local symbol="$1"
    local color="$2"
    local title="$3"
    shift 3
    local items=("$@")

    echo -e "\n${BOLD}${title}${RESET} (${#items[@]})"
    if [[ ${#items[@]} -eq 0 ]]; then
        echo "    (none)"
        return
    fi
    for item in "${items[@]}"; do
        IFS='|' read -r path pkg bits reason <<<"$item"
        local line
        line=$(printf "    %s %-50s %-10s [%s]" "$symbol" "$path" "$bits" "$pkg")
        echo -e "${color}${line}${RESET}"
        [[ -n "${reason:-}" ]] && echo -e "        ${YELLOW}↳ flagged: ${reason}${RESET}"
    done
}

print_bucket "✓" "$GREEN"  "Expected"             "${EXPECTED[@]}"
print_bucket "!" "$YELLOW" "Unusual (packaged)"   "${UNUSUAL[@]}"
print_bucket "✗" "$RED"    "Suspicious"           "${SUSPICIOUS[@]}"

# --- Summary ---

total=$(( ${#EXPECTED[@]} + ${#UNUSUAL[@]} + ${#SUSPICIOUS[@]} ))

section "Summary"
echo "    Total SUID/SGID binaries: ${total}"
echo -e "      ${GREEN}Expected:${RESET}    ${#EXPECTED[@]}"
echo -e "      ${YELLOW}Unusual:${RESET}     ${#UNUSUAL[@]}"
echo -e "      ${RED}Suspicious:${RESET}  ${#SUSPICIOUS[@]}"

if [[ ${#SUSPICIOUS[@]} -gt 0 ]]; then
    echo ""
    warn "Review suspicious entries manually. Orphan SUID binaries or SUID files in user-writable paths can indicate compromise or misconfiguration."
    exit 1
fi

if [[ ${#UNUSUAL[@]} -gt 0 ]]; then
    echo ""
    info "Unusual entries are owned by packages — likely legitimate (sandbox helpers, etc.) but worth knowing they exist."
fi

exit 0
