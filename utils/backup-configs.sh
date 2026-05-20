#!/usr/bin/env bash
# ============================================================
# backup-configs.sh
# Description : Backup /etc and critical config files to a
#               timestamped tar.gz with SHA256 checksum.
#               Excludes secrets, caches and large binaries.
# Dependencies: tar, sha256sum, find
# Compatibility: Any Linux
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

BACKUP_DIR="${BACKUP_DIR:-${HOME}/config-backups}"
KEEP_LAST="${KEEP_LAST:-10}"   # max number of backups to retain

# Paths to include in the backup
INCLUDE_PATHS=(
    /etc
    "${HOME}/.config"
    "${HOME}/.local/share/keyrings"
    "${HOME}/.ssh"
    "${HOME}/.gnupg"
)

# Patterns to exclude from the archive
EXCLUDE_PATTERNS=(
    "*.log"
    "*.cache"
    "*.sock"
    "*.pid"
    "*/.git/*"
    "*/Cache/*"
    "*/cache/*"
    "*/__pycache__/*"
    "*/node_modules/*"
    "/etc/udev/hwdb.bin"
    "/etc/pacman.d/gnupg/trustdb.gpg"
)

# --- Parse args ---
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output|-o)
                BACKUP_DIR="${2:?--output requires a directory path}"; shift 2 ;;
            --keep|-k)
                KEEP_LAST="${2:?--keep requires a number}"; shift 2 ;;
            --help|-h)
                echo "Usage: $(basename "$0") [OPTIONS]"
                echo ""
                echo "  --output DIR   Directory to save backups (default: ~/config-backups)"
                echo "  --keep N       Number of backups to keep (default: ${KEEP_LAST})"
                exit 0 ;;
            *) warn "Unknown argument: $1"; shift ;;
        esac
    done
}

# --- Show what will be backed up ---
show_preview() {
    section "Backup Preview"

    info "Output directory: ${BACKUP_DIR}"
    info "Paths to include:"
    for path in "${INCLUDE_PATHS[@]}"; do
        if [[ -e "$path" ]]; then
            local size
            size=$(du -sh "$path" 2>/dev/null | awk '{print $1}')
            printf "  ${GREEN}%-40s %s${RESET}\n" "$path" "${size}"
        else
            printf "  ${YELLOW}%-40s (not found — skipped)${RESET}\n" "$path"
        fi
    done

    echo ""
    info "Excluded patterns: ${EXCLUDE_PATTERNS[*]}"
    echo ""
}

# --- Rotate old backups ---
rotate_backups() {
    local count
    count=$(find "$BACKUP_DIR" -maxdepth 1 -name "configs_*.tar.gz" 2>/dev/null | wc -l)

    if [[ "$count" -ge "$KEEP_LAST" ]]; then
        local to_delete=$(( count - KEEP_LAST + 1 ))
        warn "Rotating old backups (keeping last ${KEEP_LAST}):"
        find "$BACKUP_DIR" -maxdepth 1 -name "configs_*.tar.gz" \
            | sort | head -"$to_delete" | while IFS= read -r old; do
            rm -f "$old" "${old%.tar.gz}.sha256"
            info "  Removed: $(basename "$old")"
        done
    fi
}

# --- Run backup ---
run_backup() {
    section "Creating Backup"

    mkdir -p "$BACKUP_DIR" || fatal "Cannot create backup directory: ${BACKUP_DIR}"

    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    local archive="${BACKUP_DIR}/configs_${timestamp}.tar.gz"
    local checksum_file="${archive%.tar.gz}.sha256"

    # Build exclude args for tar
    local exclude_args=()
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        exclude_args+=(--exclude="$pattern")
    done

    # Filter include paths to only existing ones
    local existing_paths=()
    for path in "${INCLUDE_PATHS[@]}"; do
        [[ -e "$path" ]] && existing_paths+=("$path")
    done

    [[ ${#existing_paths[@]} -eq 0 ]] && fatal "No source paths exist. Nothing to back up."

    info "Archiving to: ${archive}"

    if sudo tar -czf "$archive" \
        "${exclude_args[@]}" \
        --ignore-failed-read \
        --warning=no-file-changed \
        "${existing_paths[@]}" 2>/dev/null; then
        ok "Archive created."
    else
        warn "tar finished with warnings (some files may have been skipped)."
    fi

    # Fix ownership so the user can read it
    sudo chown "$(id -un):$(id -gn)" "$archive" 2>/dev/null

    # Checksum
    info "Computing SHA256 checksum…"
    sha256sum "$archive" > "$checksum_file" \
        && ok "Checksum saved: $(basename "$checksum_file")"

    # Size report
    local size
    size=$(du -sh "$archive" 2>/dev/null | awk '{print $1}')
    echo ""
    ok "Backup complete: ${BOLD}${archive}${RESET} (${size})"
    info "Verify with: sha256sum -c ${checksum_file}"
}

# --- Main ---
main() {
    section "Config Backup"
    require_cmds tar sha256sum find

    parse_args "$@"

    show_preview
    confirm "Proceed with backup?" || { info "Backup cancelled."; exit 0; }

    rotate_backups
    run_backup
}

main "$@"
