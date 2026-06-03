#!/usr/bin/env bash
# ============================================================
# disk-usage.sh
# Description : Disk usage summary by filesystem with usage bars,
#               inode pressure alerts, and the top-N largest
#               directories under a target path (default: $HOME).
#               Read-only — never modifies anything.
# Dependencies: df, du, sort, numfmt
# Compatibility: Any Linux
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

# --- Defaults ---
TARGET="$HOME"
TOP_N=15

# Pseudo / virtual filesystems we never want in the report
EXCLUDE_FS=(tmpfs devtmpfs squashfs overlay efivarfs devfs ramfs fuse.portal)

# Thresholds for color-coding usage percentages
WARN_PCT=75
CRIT_PCT=90

usage() {
    cat <<EOF
Usage: $(basename "$0") [PATH] [-n COUNT]

  PATH        Directory to analyse for the top-N largest subdirectories
              (default: \$HOME — ${HOME})
  -n COUNT    Number of directories to list (default: ${TOP_N})

Examples:
  $(basename "$0")                 # top ${TOP_N} dirs under \$HOME
  $(basename "$0") /var            # top dirs under /var
  $(basename "$0") / -n 20         # top 20 dirs under /  (use sudo for full coverage)
EOF
}

# --- Parse arguments ---
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n)        shift; TOP_N="${1:-}" ;;
            -h|--help) usage; exit 0 ;;
            -*)        usage; fatal "Unknown option: $1" ;;
            *)         TARGET="$1" ;;
        esac
        shift
    done

    [[ "$TOP_N" =~ ^[0-9]+$ ]] && (( TOP_N > 0 )) || fatal "Invalid count: ${TOP_N}"
    [[ -d "$TARGET" ]] || fatal "Not a directory: ${TARGET}"
    TARGET="$(realpath "$TARGET")"
}

# --- Build the list of -x exclusions for df ---
df_excludes() {
    local fs out=()
    for fs in "${EXCLUDE_FS[@]}"; do
        out+=(-x "$fs")
    done
    printf '%s\n' "${out[@]}"
}

# --- Color for a usage percentage ---
pct_color() {
    local pct="$1"
    if   (( pct >= CRIT_PCT )); then echo "$RED"
    elif (( pct >= WARN_PCT )); then echo "$YELLOW"
    else                             echo "$GREEN"
    fi
}

# --- Render a fixed-width usage bar (10 cells) ---
usage_bar() {
    local pct="$1" width=10 filled i bar=""
    filled=$(( pct * width / 100 ))
    (( filled > width )) && filled=$width
    (( filled < 0 ))     && filled=0
    for (( i = 0; i < width; i++ )); do
        if (( i < filled )); then bar+="█"; else bar+="░"; fi
    done
    printf '%s' "$bar"
}

# --- Filesystem usage by mount point ---
show_filesystems() {
    section "Filesystem usage"

    local -a ex
    mapfile -t ex < <(df_excludes)

    printf "  %-20s %7s %7s %7s  %5s  %-12s %s\n" \
        "MOUNT" "SIZE" "USED" "AVAIL" "USE%" "USAGE" "SOURCE"
    printf "  %s\n" "$(printf '%.0s─' {1..82})"

    local source size used avail pcent target pct color bar
    while read -r source size used avail pcent target; do
        pct="${pcent%\%}"
        [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
        color="$(pct_color "$pct")"
        bar="$(usage_bar "$pct")"
        printf "  %-20s %7s %7s %7s  ${color}%5s${RESET}  [${color}%s${RESET}] %s\n" \
            "$target" "$size" "$used" "$avail" "$pcent" "$bar" "$source"
    done < <(df -h --output=source,size,used,avail,pcent,target "${ex[@]}" 2>/dev/null \
                | tail -n +2 \
                | grep -v '^/dev/loop' \
                | sort -k6)
}

# --- Inode pressure (only flag filesystems above WARN_PCT) ---
show_inodes() {
    section "Inode usage"

    local -a ex
    mapfile -t ex < <(df_excludes)

    local source iused ipcent target pct color flagged=0
    while read -r source iused ipcent target; do
        pct="${ipcent%\%}"
        # btrfs and other dynamic-inode filesystems report '-' here; skip them.
        [[ "$pct" =~ ^[0-9]+$ ]] || continue
        if (( pct >= WARN_PCT )); then
            color="$(pct_color "$pct")"
            printf "  ${color}%-20s %s inodes used (%s)${RESET}  %s\n" \
                "$target" "$iused" "$ipcent" "$source"
            flagged=1
        fi
    done < <(df -i --output=source,iused,ipcent,target "${ex[@]}" 2>/dev/null \
                | tail -n +2 \
                | grep -v '^/dev/loop')

    (( flagged == 0 )) && ok "All filesystems below ${WARN_PCT}% inode usage."
}

# --- Top-N largest immediate subdirectories of TARGET ---
show_top_dirs() {
    section "Top ${TOP_N} directories in ${TARGET}"

    if [[ $EUID -ne 0 && "$TARGET" != "$HOME"* ]]; then
        info "Not running as root — directories you can't read will be skipped."
    fi
    info "Scanning ${TARGET} (single filesystem)…"

    # One byte-accurate pass: stay on one filesystem (-x), only direct children.
    local -a rows
    mapfile -t rows < <(du -x --max-depth=1 -B1 "$TARGET" 2>/dev/null | sort -rn)

    if [[ ${#rows[@]} -eq 0 ]]; then
        warn "Nothing to report (empty or unreadable)."
        return 0
    fi

    # The largest entry is TARGET itself (sum of its children) → use as total.
    local total_bytes
    IFS=$'\t' read -r total_bytes _ <<< "${rows[0]}"
    (( total_bytes == 0 )) && { warn "Directory is empty."; return 0; }

    printf "\n  %-9s %6s   %s\n" "SIZE" "OF DIR" "PATH"
    printf "  %s\n" "$(printf '%.0s─' {1..70})"

    local bytes path pct color hsize shown=0
    while IFS=$'\t' read -r bytes path; do
        # Skip the TARGET total line itself
        [[ "$path" == "$TARGET" ]] && continue
        (( shown >= TOP_N )) && break

        pct=$(( bytes * 100 / total_bytes ))
        color="$(pct_color "$pct")"
        hsize="$(LC_ALL=C numfmt --to=iec "$bytes")"

        printf "  %-9s ${color}%5s%%${RESET}   %s\n" "$hsize" "$pct" "$path"
        (( shown++ ))
    done < <(printf '%s\n' "${rows[@]}")

    echo ""
    info "Scanned total: ${BOLD}$(LC_ALL=C numfmt --to=iec "$total_bytes")${RESET} in ${TARGET}"
}

# --- Main ---
main() {
    parse_args "$@"
    require_cmds df du sort numfmt

    section "Disk Usage"
    show_filesystems
    show_inodes
    show_top_dirs
}

main "$@"
