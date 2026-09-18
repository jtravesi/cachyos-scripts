#!/usr/bin/env bash
# ============================================================
# utils/common.sh
# Description : Shared functions used across all scripts.
#               Source this file, do not execute it directly.
# Dependencies: bash
# Compatibility: Any Linux
# ============================================================

# --- Colors & symbols ---
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

OK="[${GREEN}✓${RESET}]"
WARN="[${YELLOW}!${RESET}]"
ERR="[${RED}✗${RESET}]"
INFO="[${CYAN}*${RESET}]"

# --- Output helpers ---
info()    { echo -e "${INFO} $*"; }
ok()      { echo -e "${OK} $*"; }
warn()    { echo -e "${WARN} ${YELLOW}$*${RESET}"; }
error()   { echo -e "${ERR} ${RED}$*${RESET}" >&2; }
fatal()   { error "$*"; exit 1; }
section() { echo -e "\n${BOLD}=== $* ===${RESET}"; }

# --- Confirmation prompt ---
# Usage: confirm "Message" && do_something
# For critical actions, use: confirm_critical "Message" && do_something
confirm() {
    local msg="${1:-Continue?}"
    echo -en "${WARN} ${msg} [y/N] "
    read -r reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

confirm_critical() {
    local msg="${1:-This action may be destructive. Continue?}"
    warn "WARNING: This operation cannot be easily undone."
    echo -en "    ${RED}${msg}${RESET} [y/N] "
    read -r reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

# --- Package manager detection ---
# Detects all available AUR helpers and pacman, then asks the user
# which one to use if more than one is found.
# Sets global AUR_HELPER and PKG_MANAGER.
detect_pkg_manager() {
    local available=()

    command -v paru   &>/dev/null && available+=("paru")
    command -v yay    &>/dev/null && available+=("yay")
    command -v pacman &>/dev/null && available+=("pacman")

    if [[ ${#available[@]} -eq 0 ]]; then
        fatal "No compatible package manager found (paru, yay, pacman)."
    fi

    if [[ ${#available[@]} -eq 1 ]]; then
        PKG_MANAGER="${available[0]}"
    else
        echo ""
        info "Multiple package managers found: ${available[*]}"
        echo ""
        local i=1
        for pm in "${available[@]}"; do
            echo "    [${i}] ${pm}"
            ((i++))
        done
        echo ""
        echo -n "  Which one do you want to use? [1-${#available[@]}] (default: 1): "
        read -r choice

        # Default to first if empty or invalid
        if [[ -z "$choice" || "$choice" -lt 1 || "$choice" -gt ${#available[@]} ]] 2>/dev/null; then
            choice=1
        fi

        PKG_MANAGER="${available[$((choice - 1))]}"
    fi

    if [[ "$PKG_MANAGER" == "pacman" ]]; then
        AUR_HELPER=""
    else
        AUR_HELPER="$PKG_MANAGER"
    fi

    ok "Using package manager: ${BOLD}${PKG_MANAGER}${RESET}"
}

# --- Filesystem detection ---
# Usage: detect_fs /mount/point
# Returns filesystem type as string
detect_fs() {
    local mount="${1:-/}"
    findmnt -n -o FSTYPE "$mount" 2>/dev/null || echo "unknown"
}

# --- AUR helper cache directories ---
# Prints each existing AUR helper cache directory, one per line: yay's buildDir
# and paru's CloneDir, read from their config files or falling back to their
# defaults. Under sudo $HOME is root's, so the invoking user's home is used.
aur_cache_dirs() {
    local home="$HOME" cache config dir file seen=""
    local -a found=()

    if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
        home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    fi
    cache="${XDG_CACHE_HOME:-${home}/.cache}"
    config="${XDG_CONFIG_HOME:-${home}/.config}"

    # yay: "buildDir" in config.json, default <cache>/yay.
    dir=""
    file="${config}/yay/config.json"
    [[ -r "$file" ]] && dir=$(sed -n 's/.*"buildDir"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -n 1)
    found+=("${dir:-${cache}/yay}")

    # paru: CloneDir from the first paru.conf found (paru reads only one),
    # default <cache>/paru/clone.
    dir=""
    for file in "${config}/paru/paru.conf" /etc/paru.conf; do
        [[ -r "$file" ]] || continue
        dir=$(sed -n 's/^[[:space:]]*CloneDir[[:space:]]*=[[:space:]]*//p' "$file" | tail -n 1)
        break
    done
    dir="${dir/#\~/$home}"
    found+=("${dir:-${cache}/paru/clone}")

    for dir in "${found[@]}"; do
        dir="${dir%/}"
        [[ -d "$dir" && "$seen" != *"|${dir}|"* ]] || continue
        seen+="|${dir}|"
        printf '%s\n' "$dir"
    done
}

# --- Patch level ---
# Prints the days since the last full system upgrade logged in pacman.log,
# or nothing if none is logged.
last_upgrade_days() {
    local ts epoch
    ts=$(grep -F 'starting full system upgrade' /var/log/pacman.log 2>/dev/null \
        | tail -n 1 | sed -n 's/^\[\([^]]*\)\].*/\1/p')
    [[ -n "$ts" ]] || return 0
    epoch=$(date -d "$ts" +%s 2>/dev/null) || return 0
    echo $(( ($(date +%s) - epoch) / 86400 ))
}

# Prints one line per visible process still running code that an upgrade
# replaced on disk: its binary, or a shared library it mapped, under /usr is
# now "(deleted)". Such a process stays on the old code until restarted.
# Prints the systemd unit for system services, otherwise the command name.
# Without root, only the caller's own processes are visible.
stale_procs() {
    local dir exe unit
    for dir in /proc/[0-9]*; do
        exe=$(readlink "${dir}/exe" 2>/dev/null) || continue
        [[ "$exe" == /usr/*" (deleted)" ]] \
            || grep -qE ' /usr/[^ ]*\.so[.0-9]* \(deleted\)$' "${dir}/maps" 2>/dev/null \
            || continue
        unit=$(sed -nE 's#^0::/system\.slice/(.*/)?([^/]+\.service)$#\2#p' "${dir}/cgroup" 2>/dev/null)
        if [[ -n "$unit" ]]; then echo "$unit"; else cat "${dir}/comm" 2>/dev/null; fi
    done
}

# --- Root check ---
require_root() {
    [[ "$EUID" -eq 0 ]] || fatal "This script must be run as root (sudo)."
}

# --- Dependency check ---
# Usage: require_cmds cmd1 cmd2 cmd3
require_cmds() {
    local missing=()
    for cmd in "$@"; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        fatal "Missing dependencies: ${missing[*]}"
    fi
}
