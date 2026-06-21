#!/usr/bin/env bash
# ============================================================
# restore-snapshot.sh
# Description : Restore a Btrfs subvolume (root or home) from a
#               snapshot, keeping the current state as a backup
#               subvolume. It mounts the top-level subvolume,
#               renames the live subvolume to <name>.backup_<ts>,
#               and recreates it from the chosen snapshot. The
#               change takes effect after a reboot; the backup is
#               left in place so the restore can be undone.
#               DESTRUCTIVE — gated behind a type-to-confirm.
# Dependencies: btrfs (btrfs-progs), findmnt, mount, umount, mktemp
# Compatibility: Linux + Btrfs
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

SNAPSHOT_DIR="${SNAPSHOT_DIR:-/.snapshots}"

SUDO=""
[[ $EUID -ne 0 ]] && SUDO="sudo"

# Set by parse_args
SNAP_ARG=""
TARGET_OVERRIDE=""

# Mount bookkeeping (for cleanup trap)
TOP_MNT=""
TOP_MOUNTED=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [SNAPSHOT] [options]

  SNAPSHOT        Name (or path) of the snapshot to restore. Omit for an
                  interactive list of snapshots in ${SNAPSHOT_DIR}.

Options:
  -t, --target M  Mountpoint of the subvolume to restore onto (e.g. / or
                  /home). Default is inferred from the snapshot name prefix
                  (root_ -> /, home_ -> /home).
  -h, --help      Show this help.

How it works (no data is deleted):
  1. The top-level subvolume is mounted to a temporary directory.
  2. The live subvolume (e.g. @) is renamed to @.backup_<timestamp>.
  3. A fresh writable subvolume is created from the snapshot in its place.
  4. Reboot to boot into the restored subvolume.
  To undo, rename the backup subvolume back from the top-level mount.
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -t|--target) shift; TARGET_OVERRIDE="${1:-}" ;;
            -h|--help)   usage; exit 0 ;;
            -*)          usage; fatal "Unknown option: $1" ;;
            *)           SNAP_ARG="$1" ;;
        esac
        shift
    done
}

# --- Helpers ---
fstype_of()    { findmnt -no FSTYPE --target "$1" 2>/dev/null; }
btrfs_device() { findmnt -no SOURCE --target "$1" 2>/dev/null | sed 's/\[.*\]//'; }

# Top-level-relative path of the subvolume at/containing $1 (e.g. "@").
subvol_relpath() {
    $SUDO btrfs subvolume show "$1" 2>/dev/null | head -1 | xargs
}

cleanup() {
    # TOP_MOUNTED==2 means "leave mounted for manual recovery" — don't touch it.
    if [[ "$TOP_MOUNTED" == "1" && -n "$TOP_MNT" ]]; then
        $SUDO umount "$TOP_MNT" 2>/dev/null && TOP_MOUNTED=0
    fi
    [[ "$TOP_MOUNTED" != "2" && -n "$TOP_MNT" && -d "$TOP_MNT" ]] && rmdir "$TOP_MNT" 2>/dev/null
}
trap cleanup EXIT

# --- Build the list of snapshots and let the user pick one ---
# Sets SNAP_PATH.
pick_snapshot() {
    [[ -d "$SNAPSHOT_DIR" ]] || fatal "Snapshot directory ${SNAPSHOT_DIR} does not exist."

    local -a paths names
    local entry
    shopt -s nullglob
    for entry in "${SNAPSHOT_DIR%/}"/*; do
        [[ -d "$entry" ]] || continue
        $SUDO btrfs subvolume show "$entry" &>/dev/null || continue
        paths+=("$entry")
        names+=("$(basename "$entry")")
    done
    shopt -u nullglob

    [[ ${#paths[@]} -eq 0 ]] && fatal "No snapshots found in ${SNAPSHOT_DIR}."

    section "Available snapshots"
    local i
    for i in "${!names[@]}"; do
        printf "  [${BOLD}%d${RESET}] %s\n" "$((i + 1))" "${names[i]}"
    done
    echo ""
    echo -n "  Select snapshot to restore [1-${#paths[@]}] (Enter to cancel): "
    local choice
    read -r choice
    [[ -z "$choice" ]] && { info "Cancelled."; exit 0; }
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#paths[@]} )); then
        fatal "Invalid selection: ${choice}"
    fi
    SNAP_PATH="${paths[$((choice - 1))]}"
}

# --- Infer the restore target mountpoint from a snapshot name ---
infer_target() {
    local name="$1"
    case "$name" in
        root_*) echo "/" ;;
        home_*) echo "/home" ;;
        *)      echo "" ;;
    esac
}

# --- Main ---
main() {
    parse_args "$@"
    require_cmds btrfs findmnt mount umount mktemp

    section "Restore Btrfs Snapshot"

    # Fail fast on non-Btrfs systems before asking for a password.
    local rootfs
    rootfs=$(fstype_of "$SNAPSHOT_DIR"); [[ -z "$rootfs" ]] && rootfs=$(fstype_of "/")
    [[ "$rootfs" == "btrfs" ]] || fatal "No Btrfs filesystem at ${SNAPSHOT_DIR} \
(detected: ${rootfs:-unknown}). These tools require Btrfs."

    if [[ $EUID -ne 0 ]]; then
        info "Restoring requires root. You may be prompted for your password."
        sudo -v || fatal "sudo authentication failed."
    fi

    # Resolve the snapshot path.
    local SNAP_PATH
    if [[ -n "$SNAP_ARG" ]]; then
        if [[ -d "$SNAP_ARG" ]]; then
            SNAP_PATH="$(realpath "$SNAP_ARG")"
        elif [[ -d "${SNAPSHOT_DIR%/}/${SNAP_ARG}" ]]; then
            SNAP_PATH="${SNAPSHOT_DIR%/}/${SNAP_ARG}"
        else
            fatal "Snapshot not found: ${SNAP_ARG}"
        fi
        $SUDO btrfs subvolume show "$SNAP_PATH" &>/dev/null \
            || fatal "${SNAP_PATH} is not a Btrfs subvolume."
    else
        pick_snapshot
    fi

    local snap_name
    snap_name="$(basename "$SNAP_PATH")"

    # Determine the target mountpoint to restore onto.
    local target="$TARGET_OVERRIDE"
    [[ -z "$target" ]] && target="$(infer_target "$snap_name")"
    [[ -z "$target" ]] && fatal "Could not infer the target subvolume from '${snap_name}'. \
Pass it explicitly with --target /  (or --target /home)."
    [[ -d "$target" ]] || fatal "Target mountpoint does not exist: ${target}"

    # Both must be Btrfs and on the same filesystem.
    [[ "$(fstype_of "$target")" == "btrfs" ]] || fatal "${target} is not Btrfs."
    local snap_dev target_dev
    snap_dev=$(btrfs_device "$SNAP_PATH")
    target_dev=$(btrfs_device "$target")
    [[ "$snap_dev" == "$target_dev" ]] \
        || fatal "Snapshot (${snap_dev}) and target (${target_dev}) are on different filesystems."

    # Relative paths inside the top-level subvolume.
    local src_rel snap_rel
    src_rel=$(subvol_relpath "$target")
    snap_rel=$(subvol_relpath "$SNAP_PATH")
    [[ -n "$src_rel" && "$src_rel" != "/" && "$src_rel" != "<FS_TREE>" ]] \
        || fatal "Unsupported layout: ${target} is the top-level subvolume."
    [[ -n "$snap_rel" ]] || fatal "Could not resolve the snapshot's subvolume path."

    local timestamp backup_rel
    timestamp=$(date +%Y%m%d_%H%M%S)
    backup_rel="${src_rel}.backup_${timestamp}"

    section "Restore plan"
    printf "  %-16s %s\n" "Snapshot:" "$snap_name"
    printf "  %-16s %s\n" "Restore onto:"   "${target}  (subvolume '${src_rel}')"
    printf "  %-16s %s\n" "Device:"         "$target_dev"
    printf "  %-16s %s\n" "Current backup:" "$backup_rel"
    echo ""
    warn "The live subvolume '${src_rel}' will be replaced by the snapshot."
    warn "Your current state is preserved as '${backup_rel}' (nothing is deleted)."
    warn "The change takes effect after a ${BOLD}reboot${RESET}${YELLOW}."
    echo ""
    warn "Type the target mountpoint '${BOLD}${target}${RESET}${YELLOW}' to confirm:"
    echo -n "    > "
    local typed; read -r typed
    [[ "$typed" == "$target" ]] || { info "Cancelled (input did not match)."; exit 0; }

    # Mount the top-level subvolume (subvolid=5) to a temp dir.
    TOP_MNT=$(mktemp -d /tmp/btrfs-top.XXXXXX)
    info "Mounting top-level subvolume of ${target_dev}…"
    $SUDO mount -o subvolid=5 "$target_dev" "$TOP_MNT" \
        || fatal "Could not mount the top-level subvolume."
    TOP_MOUNTED=1

    local src_abs snap_abs
    src_abs="${TOP_MNT}/${src_rel}"
    snap_abs="${TOP_MNT}/${snap_rel}"

    [[ -e "$src_abs" ]]  || fatal "Live subvolume not found at ${src_abs}."
    [[ -e "$snap_abs" ]] || fatal "Snapshot not found at ${snap_abs}."

    # Step 1: rename the live subvolume out of the way (instant, reversible).
    info "Backing up current '${src_rel}' -> '${backup_rel}'…"
    if ! $SUDO mv "$src_abs" "${TOP_MNT}/${backup_rel}"; then
        fatal "Failed to rename the live subvolume. Nothing was changed."
    fi

    # If the snapshot lived *inside* the subvolume we just renamed, follow it.
    if [[ "$snap_rel" == "${src_rel}/"* ]]; then
        snap_abs="${TOP_MNT}/${backup_rel}/${snap_rel#"${src_rel}/"}"
    fi

    # Step 2: recreate the subvolume from the snapshot.
    info "Creating '${src_rel}' from snapshot…"
    if ! $SUDO btrfs subvolume snapshot "$snap_abs" "$src_abs"; then
        error "Failed to create the new subvolume — rolling back."
        if $SUDO mv "${TOP_MNT}/${backup_rel}" "$src_abs"; then
            ok "Rolled back: '${src_rel}' restored to its original state."
        else
            error "ROLLBACK FAILED. Recover manually from the mounted top-level at ${TOP_MNT}"
            error "  (rename '${backup_rel}' back to '${src_rel}'). Do NOT reboot yet."
            TOP_MOUNTED=2   # leave it mounted for manual recovery
        fi
        exit 1
    fi

    # Done — unmount happens via the cleanup trap.
    echo ""
    ok "Restore staged successfully."
    info "Current state saved as subvolume: ${BOLD}${backup_rel}${RESET}"
    info "Reboot to boot into the restored '${src_rel}': ${BOLD}systemctl reboot${RESET}"
    echo ""
    warn "This takes effect only if fstab mounts '${src_rel}' by name (subvol=…),"
    warn "not by subvolid=. Check with: findmnt -no OPTIONS --target ${target}"
    echo ""
    info "To undo before/after reboot: mount the top-level (mount -o subvolid=5 ${target_dev} /mnt),"
    info "then swap '${backup_rel}' back into '${src_rel}'."
    info "To discard the backup later: btrfs subvolume delete <top-level>/${backup_rel}"
}

main "$@"
