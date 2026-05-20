#!/usr/bin/env bash
# ============================================================
# switch-kernel.sh
# Description : Sets the default boot kernel by updating
#               GRUB_TOP_LEVEL in /etc/default/grub and
#               regenerating grub.cfg, or by updating the
#               default entry in systemd-boot's loader.conf.
# Dependencies: pacman, uname, grub-mkconfig (GRUB) or
#               bootctl (systemd-boot)
# Compatibility: CachyOS, Arch Linux
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

GRUB_DEFAULT_CFG="/etc/default/grub"
GRUB_CFG="/boot/grub/grub.cfg"
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

# --- Get installed kernels from vmlinuz files ---
get_kernels() {
    for vmlinuz in /boot/vmlinuz-*; do
        [[ -f "$vmlinuz" ]] || continue
        local pkg
        pkg=$(basename "$vmlinuz" | sed 's/^vmlinuz-//')
        local version
        version=$(pacman -Q "$pkg" 2>/dev/null | awk '{print $2}')
        printf '%s\t%s\t%s\n' "$pkg" "${version:-unknown}" "$vmlinuz"
    done
}

# --- Let user pick a kernel ---
pick_kernel() {
    local running
    running=$(uname -r)

    local -a pkgs versions vmlinuzes
    local i=1

    section "Available Kernels"
    printf "  %-5s %-30s %-20s %s\n" "NUM" "PACKAGE" "VERSION" "VMLINUZ"
    printf "  %s\n" "$(printf '%.0s─' {1..75})"

    while IFS=$'\t' read -r pkg version vmlinuz; do
        pkgs+=("$pkg")
        versions+=("$version")
        vmlinuzes+=("$vmlinuz")

        local suffix=""
        [[ "$running" == *"${pkg#linux-}"* || "$running" == *"$pkg"* ]] \
            && suffix=" ${CYAN}[running]${RESET}"

        printf "  [${BOLD}%d${RESET}] %-30s %-20s %s%b\n" \
            "$i" "$pkg" "$version" "$vmlinuz" "$suffix"
        (( i++ ))
    done < <(get_kernels)

    echo ""
    local count=${#pkgs[@]}
    [[ "$count" -eq 0 ]] && fatal "No kernel vmlinuz files found in /boot."

    echo -n "  Select kernel [1-${count}]: "
    read -r choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > count )); then
        fatal "Invalid selection: ${choice}"
    fi

    SELECTED_PKG="${pkgs[$((choice - 1))]}"
    SELECTED_VERSION="${versions[$((choice - 1))]}"
    SELECTED_VMLINUZ="${vmlinuzes[$((choice - 1))]}"
}

# --- GRUB switch ---
switch_grub() {
    require_cmds grub-mkconfig

    local current_top
    current_top=$(grep -oP '^GRUB_TOP_LEVEL=\K.*' "$GRUB_DEFAULT_CFG" 2>/dev/null \
        | tr -d '"' | xargs)

    if [[ "$current_top" == "$SELECTED_VMLINUZ" ]]; then
        ok "${SELECTED_PKG} is already the default boot kernel."
        return 0
    fi

    info "Updating GRUB_TOP_LEVEL in ${GRUB_DEFAULT_CFG}…"

    if grep -q '^GRUB_TOP_LEVEL=' "$GRUB_DEFAULT_CFG" 2>/dev/null; then
        sudo sed -i "s|^GRUB_TOP_LEVEL=.*|GRUB_TOP_LEVEL=\"${SELECTED_VMLINUZ}\"|" \
            "$GRUB_DEFAULT_CFG"
    else
        echo "GRUB_TOP_LEVEL=\"${SELECTED_VMLINUZ}\"" \
            | sudo tee -a "$GRUB_DEFAULT_CFG" > /dev/null
    fi

    ok "GRUB_TOP_LEVEL set to: ${SELECTED_VMLINUZ}"

    info "Regenerating ${GRUB_CFG}…"
    if sudo grub-mkconfig -o "$GRUB_CFG"; then
        ok "GRUB config regenerated."
    else
        error "grub-mkconfig failed. Check output above."
        exit 1
    fi
}

# --- systemd-boot switch ---
switch_systemd_boot() {
    require_cmds bootctl

    # Find entry file matching selected kernel
    local entry_file
    entry_file=$(grep -rl "vmlinuz-${SELECTED_PKG}\|linux ${SELECTED_PKG}" \
        "$SYSTEMD_BOOT_ENTRIES" 2>/dev/null | head -1)

    if [[ -z "$entry_file" ]]; then
        error "Could not find a systemd-boot entry for ${SELECTED_PKG}."
        info "Entries in ${SYSTEMD_BOOT_ENTRIES}:"
        ls "$SYSTEMD_BOOT_ENTRIES" 2>/dev/null | sed 's/^/  /'
        exit 1
    fi

    local entry_name
    entry_name=$(basename "$entry_file")
    info "Matching entry: ${entry_name}"

    if grep -q "^default" "$SYSTEMD_BOOT_LOADER" 2>/dev/null; then
        sudo sed -i "s|^default.*|default ${entry_name}|" "$SYSTEMD_BOOT_LOADER"
    else
        echo "default ${entry_name}" | sudo tee -a "$SYSTEMD_BOOT_LOADER" > /dev/null
    fi

    ok "systemd-boot default set to: ${entry_name}"
}

# --- Main ---
main() {
    section "Kernel Switch"
    require_cmds pacman uname

    local bootloader
    bootloader=$(detect_bootloader)

    if [[ "$bootloader" == "unknown" ]]; then
        fatal "Could not detect bootloader (no GRUB or systemd-boot config found)."
    fi

    info "Detected bootloader: ${BOLD}${bootloader}${RESET}"
    info "Running kernel: ${BOLD}$(uname -r)${RESET}"
    echo ""

    pick_kernel

    echo ""
    warn "This will set ${BOLD}${SELECTED_PKG} (${SELECTED_VERSION})${RESET} as the default boot kernel."
    confirm "Proceed?" || { info "Cancelled."; exit 0; }
    echo ""

    case "$bootloader" in
        grub)         switch_grub ;;
        systemd-boot) switch_systemd_boot ;;
    esac

    echo ""
    ok "Done. ${SELECTED_PKG} will be the default kernel on next boot."
    info "Reboot to apply: ${BOLD}systemctl reboot${RESET}"
}

main "$@"
