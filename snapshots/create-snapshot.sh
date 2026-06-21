#!/usr/bin/env bash
# ============================================================
# create-snapshot.sh
# Description : Create a named, timestamped Btrfs snapshot of a
#               subvolume (root or home by default, or any given
#               mountpoint). Snapshots are read-only by default —
#               immutable restore points — and stored under the
#               snapshot directory (default /.snapshots), which
#               must live on the same Btrfs filesystem as the
#               source.
# Dependencies: btrfs (btrfs-progs), findmnt
# Compatibility: Linux + Btrfs
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

SNAPSHOT_DIR="${SNAPSHOT_DIR:-/.snapshots}"

# btrfs subvolume snapshot needs privileges; use sudo inline when not root.
SUDO=""
[[ $EUID -ne 0 ]] && SUDO="sudo"

# Set by parse_args
SRC_ARG=""
SNAP_NAME="manual"
READONLY=1

usage() {
    cat <<EOF
Usage: $(basename "$0") [root|home|MOUNTPOINT] [options]

  Source (default: root):
    root          Snapshot the root subvolume (/)
    home          Snapshot the home subvolume (/home)
    MOUNTPOINT    Snapshot an arbitrary Btrfs subvolume mountpoint

Options:
  -n, --name NAME Label for the snapshot (default: ${SNAP_NAME}).
      --rw        Create a writable snapshot instead of read-only.
  -h, --help      Show this help.

The snapshot is stored as:
  ${SNAPSHOT_DIR}/<source>_<name>_<YYYYmmdd_HHMMSS>

Examples:
  $(basename "$0")                       # read-only snapshot of /
  $(basename "$0") home -n before-clean
  $(basename "$0") root -n pre-test --rw
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--name) shift; SNAP_NAME="${1:-}" ;;
            --rw)      READONLY=0 ;;
            -h|--help) usage; exit 0 ;;
            -*)        usage; fatal "Unknown option: $1" ;;
            *)         SRC_ARG="$1" ;;
        esac
        shift
    done
    # A label must be filesystem- and parser-friendly (no slashes/underscores
    # that would confuse the <source>_<name>_<timestamp> scheme).
    [[ "$SNAP_NAME" =~ ^[A-Za-z0-9.-]+$ ]] || \
        fatal "Invalid name '${SNAP_NAME}'. Use letters, digits, '.', '-' only."
}

# --- Filesystem type at a path (resolves to the containing mount) ---
fstype_of() { findmnt -no FSTYPE --target "$1" 2>/dev/null; }

# --- Underlying device of a path, with any [subvol] suffix stripped ---
btrfs_device() { findmnt -no SOURCE --target "$1" 2>/dev/null | sed 's/\[.*\]//'; }

# --- Resolve SRC_ARG into SRC_MNT (mountpoint) and SRC_LABEL ---
resolve_source() {
    case "$SRC_ARG" in
        ""|root) SRC_MNT="/";     SRC_LABEL="root" ;;
        home)    SRC_MNT="/home"; SRC_LABEL="home" ;;
        *)
            [[ -d "$SRC_ARG" ]] || fatal "Not a directory: ${SRC_ARG}"
            SRC_MNT="$(realpath "$SRC_ARG")"
            if [[ "$SRC_MNT" == "/" ]]; then SRC_LABEL="root"
            else SRC_LABEL="$(basename "$SRC_MNT")"; fi
            ;;
    esac
}

# --- Main ---
main() {
    parse_args "$@"
    require_cmds btrfs findmnt

    section "Create Btrfs Snapshot"

    resolve_source

    local fs
    fs=$(fstype_of "$SRC_MNT")
    [[ "$fs" == "btrfs" ]] || fatal "${SRC_MNT} is ${fs:-unknown}, not Btrfs — cannot snapshot."

    # The source mountpoint must itself be a subvolume root.
    $SUDO btrfs subvolume show "$SRC_MNT" &>/dev/null \
        || { [[ $EUID -ne 0 ]] && sudo -v; $SUDO btrfs subvolume show "$SRC_MNT" &>/dev/null; } \
        || fatal "${SRC_MNT} is not a Btrfs subvolume root — cannot snapshot it directly."

    if [[ $EUID -ne 0 ]]; then
        info "Creating a snapshot requires root. You may be prompted for your password."
        sudo -v || fatal "sudo authentication failed."
    fi

    # Ensure the snapshot directory exists (same pattern as full-upgrade.sh).
    if [[ ! -d "$SNAPSHOT_DIR" ]]; then
        warn "Snapshot directory ${SNAPSHOT_DIR} does not exist."
        confirm "Create it now?" || { info "Cancelled."; exit 0; }
        $SUDO mkdir -p "$SNAPSHOT_DIR" || fatal "Could not create ${SNAPSHOT_DIR}."
    fi

    # Snapshots cannot cross filesystems: source and destination must share
    # the same Btrfs volume (they may be different subvolumes of it).
    local src_dev dst_dev
    src_dev=$(btrfs_device "$SRC_MNT")
    dst_dev=$(btrfs_device "$SNAPSHOT_DIR")
    if [[ -n "$src_dev" && -n "$dst_dev" && "$src_dev" != "$dst_dev" ]]; then
        fatal "Snapshot dir is on ${dst_dev} but ${SRC_MNT} is on ${src_dev}. \
They must be the same Btrfs filesystem."
    fi

    local timestamp dest
    timestamp=$(date +%Y%m%d_%H%M%S)
    dest="${SNAPSHOT_DIR%/}/${SRC_LABEL}_${SNAP_NAME}_${timestamp}"

    [[ -e "$dest" ]] && fatal "Destination already exists: ${dest}"

    local mode="read-only"; (( READONLY )) || mode="writable"
    info "Source     : ${SRC_MNT}"
    info "Destination: ${dest}"
    info "Mode       : ${mode}"
    echo ""

    local ro_flag=()
    (( READONLY )) && ro_flag=(-r)

    if $SUDO btrfs subvolume snapshot "${ro_flag[@]}" "$SRC_MNT" "$dest"; then
        echo ""
        ok "Snapshot created: ${BOLD}${dest}${RESET}"
        info "List snapshots:   list-snapshots.sh"
        info "Restore later:    restore-snapshot.sh $(basename "$dest")"
    else
        fatal "Snapshot creation failed — see output above."
    fi
}

main "$@"
