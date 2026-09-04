#!/usr/bin/env bash
# ============================================================
# full-upgrade.sh
# Description : Full system upgrade with optional pre-upgrade Btrfs
#               snapshot, package list snapshot and keyring refresh.
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
# Delegates to create-snapshot.sh, which already handles privilege escalation,
# the subvolume/same-filesystem checks and the shared <source>_<name>_<timestamp>
# naming that list-snapshots.sh and restore-snapshot.sh expect.
try_snapshot() {
    local fs
    fs=$(detect_fs "$SNAPSHOT_SUBVOL")

    if [[ "$fs" != "btrfs" ]]; then
        info "Filesystem at ${SNAPSHOT_SUBVOL} is ${fs} — snapshot skipped (Btrfs only)."
        return 0
    fi

    if ! command -v btrfs &>/dev/null; then
        warn "btrfs-progs is not installed — snapshot skipped."
        confirm "Continue without snapshot?" || exit 1
        return 0
    fi

    local create_script="${SCRIPT_DIR}/../snapshots/create-snapshot.sh"
    if [[ ! -x "$create_script" ]]; then
        warn "create-snapshot.sh not found — snapshot skipped."
        confirm "Continue without snapshot?" || exit 1
        return 0
    fi

    if SNAPSHOT_DIR="$SNAPSHOT_DIR" bash "$create_script" "$SNAPSHOT_SUBVOL" -n pre-upgrade; then
        return 0
    fi

    warn "Could not create snapshot."
    confirm "Continue without snapshot?" || exit 1
}

# --- Package list snapshot ---
try_pkg_snapshot() {
    local export_script="${SCRIPT_DIR}/../packages/export-pkglist.sh"

    if [[ ! -x "$export_script" ]]; then
        return 0
    fi

    confirm "Save a package list snapshot before upgrading?" || {
        info "Package snapshot skipped."
        return 0
    }

    info "Collecting package list…"

    local output rc snap_file
    output=$(bash "$export_script" --format json 2>&1)
    rc=$?

    # export-pkglist.sh announces the path on a colored line; drop the ANSI
    # escapes before reading it back, or the path will not resolve.
    snap_file=$(printf '%s\n' "$output" \
        | sed 's/\x1b\[[0-9;]*m//g' \
        | grep -oP '(?<=Snapshot saved to: ).*' \
        | tail -n 1)

    if (( rc == 0 )) && [[ -n "$snap_file" && -f "$snap_file" ]]; then
        ok "Package snapshot saved: ${snap_file}"
        # Store path for optional post-upgrade diff
        PKG_SNAPSHOT_FILE="$snap_file"
    else
        warn "Package snapshot failed — continuing without it."
        printf '%s\n' "$output" | tail -n 5 >&2
    fi
}

# --- Post-upgrade diff ---
try_pkg_diff() {
    local diff_script="${SCRIPT_DIR}/../packages/diff-pkglist.sh"

    [[ -z "${PKG_SNAPSHOT_FILE:-}" ]] && return 0
    [[ ! -x "$diff_script" ]] && return 0

    confirm "Show package diff (what changed during the upgrade)?" || return 0

    bash "$diff_script" "$PKG_SNAPSHOT_FILE" --summary
    info "Full diff: ${diff_script} ${PKG_SNAPSHOT_FILE}"
}

# --- Keyring refresh ---
# Uses -Sy, which leaves the sync databases newer than the installed packages.
# That is only safe if a full -Syu follows immediately, so this runs after the
# upgrade has already been confirmed — never before.
refresh_keyring() {
    info "Refreshing archlinux-keyring..."
    if sudo pacman -Sy --noconfirm archlinux-keyring &>/dev/null; then
        ok "Keyring updated."
    else
        warn "Could not update keyring. Continuing anyway."
    fi
}

# --- Partial upgrade warning ---
# Reached when the databases are already synced but the upgrade did not finish.
warn_partial_upgrade() {
    warn "Package databases are synced but the system was NOT upgraded."
    warn "This is a partial upgrade state — do not install individual packages."
    warn "Re-run this script (or '${PKG_MANAGER} -Syu') to finish."
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

    # Only now that the upgrade is going ahead is it safe to sync the databases.
    refresh_keyring

    if $cmd; then
        ok "System upgraded successfully."
    else
        error "Upgrade finished with errors. Check the output above."
        warn_partial_upgrade
        exit 1
    fi
}

# --- Main ---
main() {
    section "CachyOS Full Upgrade"
    detect_pkg_manager
    try_snapshot
    try_pkg_snapshot
    run_upgrade
    try_pkg_diff
}

main "$@"
