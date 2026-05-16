#!/usr/bin/env bash
# ============================================================
# full-upgrade.sh
# Description : Full system upgrade with optional pre-upgrade
#               snapshot (Btrfs only) and keyring refresh.
#               Detects package manager automatically.
# Dependencies: pacman, paru or yay (optional), btrfs-progs (optional)
# Compatibility: CachyOS, Arch Linux
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

SNAPSHOT_SUBVOL="${SNAPSHOT_SUBVOL:-/}"
SNAPSHOT_DIR="${SNAPSHOT_DIR:-/.snapshots}"

# --- Btrfs snapshot ---
try_snapshot() {
    local fs
    fs=$(detect_fs "$SNAPSHOT_SUBVOL")

    if [[ "$fs" != "btrfs" ]]; then
        info "Filesystem at ${SNAPSHOT_SUBVOL} is ${fs} — snapshot skipped (Btrfs only)."
        return 0
    fi

    require_cmds btrfs

    if [[ ! -d "$SNAPSHOT_DIR" ]]; then
        warn "Snapshot directory ${SNAPSHOT_DIR} does not exist."
        confirm "Create it now?" || { info "Snapshot skipped."; return 0; }
        mkdir -p "$SNAPSHOT_DIR" || fatal "Could not create ${SNAPSHOT_DIR}."
    fi

    local snap_name
    snap_name="pre-upgrade_$(date +%Y%m%d_%H%M%S)"
    local snap_path="${SNAPSHOT_DIR}/${snap_name}"

    info "Creating Btrfs snapshot: ${snap_path}"
    if btrfs subvolume snapshot "$SNAPSHOT_SUBVOL" "$snap_path"; then
        ok "Snapshot created: ${snap_path}"
    else
        warn "Could not create snapshot."
        confirm "Continue without snapshot?" || exit 1
    fi
}

# --- Keyring refresh ---
refresh_keyring() {
    info "Refreshing archlinux-keyring..."
    if sudo pacman -Sy --noconfirm archlinux-keyring &>/dev/null; then
        ok "Keyring updated."
    else
        warn "Could not update keyring. Continuing anyway."
    fi
}

# --- Upgrade ---
run_upgrade() {
    section "Upgrading system with ${PKG_MANAGER}"

    local cmd
    case "$PKG_MANAGER" in
        paru)   cmd="paru -Syu" ;;
        yay)    cmd="yay -Syu" ;;
        pacman) cmd="sudo pacman -Syu" ;;
    esac

    info "Command: ${cmd}"
    confirm "Start upgrade now?" || { info "Upgrade cancelled."; exit 0; }

    if $cmd; then
        ok "System upgraded successfully."
    else
        error "Upgrade finished with errors. Check the output above."
        exit 1
    fi
}

# --- Main ---
main() {
    section "CachyOS Full Upgrade"
    detect_pkg_manager
    try_snapshot
    refresh_keyring
    run_upgrade
}

main "$@"
