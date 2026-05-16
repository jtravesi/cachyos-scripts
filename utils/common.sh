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
