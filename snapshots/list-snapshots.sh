#!/usr/bin/env bash
# ============================================================
# list-snapshots.sh
# Description : List Btrfs snapshots managed under the snapshot
#               directory (default /.snapshots), showing each
#               snapshot's source subvolume, creation time, mode
#               (read-only / writable) and subvolume ID. With
#               --all it also lists every snapshot known to the
#               filesystem, not just the ones these tools create.
#               Read-only — only runs `btrfs subvolume` queries.
# Dependencies: btrfs (btrfs-progs), findmnt
# Compatibility: Linux + Btrfs
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

SNAPSHOT_DIR="${SNAPSHOT_DIR:-/.snapshots}"

# btrfs subvolume ioctls need privileges; use sudo inline when not root.
SUDO=""
[[ $EUID -ne 0 ]] && SUDO="sudo"

SHOW_ALL=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] [SNAPSHOT_DIR]

  SNAPSHOT_DIR    Directory holding the snapshots (default: ${SNAPSHOT_DIR};
                  override with the SNAPSHOT_DIR env var too).

Options:
  -a, --all       Also list every snapshot on the filesystem, not just the
                  ones created under the snapshot directory.
  -h, --help      Show this help.
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -a|--all)  SHOW_ALL=1 ;;
            -h|--help) usage; exit 0 ;;
            -*)        usage; fatal "Unknown option: $1" ;;
            *)         SNAPSHOT_DIR="$1" ;;
        esac
        shift
    done
}

# --- Filesystem type at a path (resolves to the containing mount) ---
fstype_of() { findmnt -no FSTYPE --target "$1" 2>/dev/null; }

# --- One field value from `btrfs subvolume show` output ---
# Usage: show_field "<show output>" "Creation time"
show_field() {
    grep -im1 "$2" <<< "$1" | sed 's/^[^:]*:[[:space:]]*//' | xargs
}

# --- Print one managed snapshot row from its directory path ---
print_managed_row() {
    local path="$1" show name source created flags mode id
    show=$($SUDO btrfs subvolume show "$path" 2>/dev/null) || return 1

    name=$(basename "$path")
    created=$(show_field "$show" "Creation time")
    id=$(show_field "$show" "Subvolume ID")
    flags=$(show_field "$show" "Flags")
    [[ "$flags" == *readonly* ]] && mode="RO" || mode="RW"

    # Source is encoded as the first underscore-delimited token by create-snapshot.sh.
    source="${name%%_*}"
    [[ "$source" == "$name" ]] && source="?"

    local mcolor="$GREEN"
    [[ "$mode" == "RW" ]] && mcolor="$YELLOW"
    printf "  %-34s %-7s %-19s ${mcolor}%-3s${RESET} %s\n" \
        "$name" "$source" "${created:0:19}" "$mode" "$id"
}

# --- List snapshots created under SNAPSHOT_DIR ---
list_managed() {
    section "Managed snapshots in ${SNAPSHOT_DIR}"

    if [[ ! -d "$SNAPSHOT_DIR" ]]; then
        info "Snapshot directory ${SNAPSHOT_DIR} does not exist yet."
        info "Create one with: ${BOLD}create-snapshot.sh${RESET}"
        return 0
    fi

    printf "  ${BOLD}%-34s %-7s %-19s %-3s %s${RESET}\n" \
        "NAME" "SOURCE" "CREATED" "MOD" "ID"
    printf "  %s\n" "$(printf '%.0s─' {1..78})"

    local entry count=0
    shopt -s nullglob
    for entry in "${SNAPSHOT_DIR%/}"/*; do
        [[ -d "$entry" ]] || continue
        if print_managed_row "$entry"; then
            (( count++ ))
        fi
    done
    shopt -u nullglob

    echo ""
    if (( count == 0 )); then
        info "No snapshots found in ${SNAPSHOT_DIR}."
    else
        ok "${count} snapshot(s) found."
    fi
}

# --- List every snapshot on the filesystem ---
list_all() {
    section "All snapshots on the filesystem"

    local mnt="$SNAPSHOT_DIR"
    [[ -d "$mnt" ]] || mnt="/"

    local out
    out=$($SUDO btrfs subvolume list -s -t "$mnt" 2>/dev/null)
    if [[ -z "$out" ]] || [[ $(wc -l <<< "$out") -le 2 ]]; then
        info "No snapshots reported by 'btrfs subvolume list -s'."
        return 0
    fi
    # Reprint the native table, indented.
    sed 's/^/  /' <<< "$out"
}

# --- Main ---
main() {
    parse_args "$@"
    require_cmds btrfs findmnt

    section "Btrfs Snapshots"

    local fs
    fs=$(fstype_of "${SNAPSHOT_DIR}")
    [[ -z "$fs" ]] && fs=$(fstype_of "/")
    if [[ "$fs" != "btrfs" ]]; then
        fatal "No Btrfs filesystem found at ${SNAPSHOT_DIR} (detected: ${fs:-unknown}). \
These tools require Btrfs."
    fi

    if [[ $EUID -ne 0 ]]; then
        info "Querying Btrfs subvolumes requires root. You may be prompted for your password."
        sudo -v || fatal "sudo authentication failed."
    fi

    list_managed
    (( SHOW_ALL )) && list_all
}

main "$@"
