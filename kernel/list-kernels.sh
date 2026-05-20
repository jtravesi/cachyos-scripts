#!/usr/bin/env bash
# ============================================================
# list-kernels.sh
# Description : Lists installed kernels, highlights the active
#               (running) kernel and the one set as default
#               boot target in GRUB or systemd-boot.
# Dependencies: pacman, uname
# Compatibility: CachyOS, Arch Linux
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

GRUB_DEFAULT_CFG="/etc/default/grub"
SYSTEMD_BOOT_LOADER="/boot/loader/loader.conf"
SYSTEMD_BOOT_ENTRIES="/boot/loader/entries"

# --- Detect bootloader ---
detect_bootloader() {
    if [[ -f "$SYSTEMD_BOOT_LOADER" ]]; then
        echo "systemd-boot"
    elif [[ -f "$GRUB_DEFAULT_CFG" ]]; then
        echo "grub"
    else
        echo "unknown"
    fi
}

# --- Get default kernel vmlinuz path from GRUB ---
grub_default_vmlinuz() {
    grep -oP '^GRUB_TOP_LEVEL=\K.*' "$GRUB_DEFAULT_CFG" 2>/dev/null \
        | tr -d '"' \
        | xargs
}

# --- Get default kernel from systemd-boot ---
systemd_boot_default() {
    grep -oP '^default\s+\K\S+' "$SYSTEMD_BOOT_LOADER" 2>/dev/null \
        | sed 's/\.conf$//'
}

# --- Find installed kernel packages ---
# A kernel package installs a vmlinuz in /boot — cross-reference with pacman
get_installed_kernels() {
    # Collect vmlinuz files; derive package name from filename convention
    # /boot/vmlinuz-linux-cachyos → linux-cachyos
    for vmlinuz in /boot/vmlinuz-*; do
        [[ -f "$vmlinuz" ]] || continue
        local pkg
        pkg=$(basename "$vmlinuz" | sed 's/^vmlinuz-//')
        local version
        version=$(pacman -Q "$pkg" 2>/dev/null | awk '{print $2}')
        local size
        size=$(du -sh "$vmlinuz" 2>/dev/null | awk '{print $1}')
        printf '%s\t%s\t%s\t%s\n' "$pkg" "${version:-unknown}" "$vmlinuz" "${size:-?}"
    done
}

# --- Main ---
main() {
    section "Installed Kernels"
    require_cmds pacman uname

    local running
    running=$(uname -r)

    local bootloader
    bootloader=$(detect_bootloader)
    info "Bootloader: ${bootloader}"

    local default_vmlinuz=""
    case "$bootloader" in
        grub)
            default_vmlinuz=$(grub_default_vmlinuz)
            [[ -z "$default_vmlinuz" ]] && \
                info "GRUB_TOP_LEVEL not set — default is first menuentry (index 0)"
            ;;
        systemd-boot)
            local default_entry
            default_entry=$(systemd_boot_default)
            info "Default entry: ${default_entry:-not set}"
            ;;
    esac

    echo ""
    printf "  %-30s %-20s %-10s %s\n" "PACKAGE" "VERSION" "SIZE" "VMLINUZ"
    printf "  %s\n" "$(printf '%.0s─' {1..80})"

    local found=0
    while IFS=$'\t' read -r pkg version vmlinuz size; do
        found=1

        local is_running=false is_default=false
        # Check if running: uname -r matches the vmlinuz package name
        [[ "$running" == *"${pkg#linux-}"* || "$running" == *"${pkg}"* ]] && is_running=true
        # Check if default boot target
        [[ -n "$default_vmlinuz" && "$default_vmlinuz" == "$vmlinuz" ]] && is_default=true

        # Pick label and color
        local label="" color="$RESET"
        if "$is_running" && "$is_default"; then
            label=" [running + default]"
            color="$GREEN"
        elif "$is_running"; then
            label=" [running]"
            color="$CYAN"
        elif "$is_default"; then
            label=" [default boot]"
            color="$YELLOW"
        fi

        printf "  ${color}%-30s %-20s %-10s %s%s${RESET}\n" \
            "$pkg" "$version" "$size" "$vmlinuz" "$label"
    done < <(get_installed_kernels)

    [[ "$found" -eq 0 ]] && warn "No kernel vmlinuz files found in /boot."

    echo ""
    info "Running kernel : ${BOLD}${running}${RESET}"
    [[ -n "$default_vmlinuz" ]] && \
        info "Default boot   : ${BOLD}${default_vmlinuz}${RESET}"

    echo ""
    info "Use switch-kernel.sh to change the default boot kernel."
}

main "$@"
