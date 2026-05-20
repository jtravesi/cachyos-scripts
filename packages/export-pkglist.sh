#!/usr/bin/env bash
# ============================================================
# export-pkglist.sh
# Description : Exports installed packages (official + AUR)
#               with versions to a timestamped file. Supports
#               plain text, JSON and pacman-restore formats.
#               Output can be used with diff-pkglist.sh to
#               compare snapshots across machines or time.
# Dependencies: pacman, expac (optional, for fast batch queries)
# Compatibility: CachyOS, Arch Linux
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

OUTPUT_DIR="${HOME}/pkg-snapshots"
FORMAT="text"          # text | json | pacman
INCLUDE_AUR=true
INCLUDE_OFFICIAL=true
PRINT_ONLY=false       # print to stdout instead of saving

# --- Parse args ---
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output|-o)
                OUTPUT_DIR="${2:?--output requires a directory path}"; shift 2 ;;
            --format|-f)
                FORMAT="${2:?--format requires: text, json or pacman}"; shift 2 ;;
            --aur-only)
                INCLUDE_OFFICIAL=false; shift ;;
            --official-only)
                INCLUDE_AUR=false; shift ;;
            --print|-p)
                PRINT_ONLY=true; shift ;;
            --help|-h)
                echo "Usage: $(basename "$0") [OPTIONS]"
                echo ""
                echo "  --output DIR       Directory to save snapshots (default: ~/pkg-snapshots)"
                echo "  --format FORMAT    Output format: text, json, pacman (default: text)"
                echo "  --aur-only         Only export AUR packages"
                echo "  --official-only    Only export official packages"
                echo "  --print            Print to stdout instead of saving to file"
                exit 0 ;;
            *) warn "Unknown argument: $1"; shift ;;
        esac
    done

    case "$FORMAT" in
        text|json|pacman) ;;
        *) fatal "Unknown format '${FORMAT}'. Valid: text, json, pacman" ;;
    esac
}

# --- Collect packages ---
# Uses expac when available (25ms for full DB), falls back to pacman -Qi per package.

_use_expac() { command -v expac &>/dev/null; }

get_official_pkgs() {
    # Returns TSV: name version repo install_date
    if _use_expac; then
        # expac --sync gives the real repo name; --query gives install date
        # Join them via name as key using awk
        local sync_data query_data
        sync_data=$(expac '%n\t%r' --sync 2>/dev/null)
        query_data=$(expac '%n\t%v\t%l' --query 2>/dev/null)

        # Build repo lookup from sync_data, then emit official (non-foreign) packages
        awk -F'\t' '
            NR==FNR { repo[$1]=$2; next }
            ($1 in repo) { printf "%s\t%s\t%s\t%s\n", $1, $2, repo[$1], $3 }
        ' <(echo "$sync_data") <(echo "$query_data")
    else
        pacman -Qn 2>/dev/null | while read -r name version; do
            local repo install_date
            repo=$(pacman -Si "$name" 2>/dev/null | awk -F': ' '/^Repository/{print $2; exit}')
            install_date=$(pacman -Qi "$name" 2>/dev/null | awk -F': ' '/^Install Date/{print $2; exit}')
            printf '%s\t%s\t%s\t%s\n' "$name" "$version" "${repo:-official}" "${install_date:-unknown}"
        done
    fi
}

get_aur_pkgs() {
    # Returns TSV: name version repo install_date
    if _use_expac; then
        local sync_data query_data
        sync_data=$(expac '%n\t%r' --sync 2>/dev/null)
        query_data=$(expac '%n\t%v\t%l' --query 2>/dev/null)

        # Foreign packages: in query_data but NOT in sync_data
        awk -F'\t' '
            NR==FNR { known[$1]=1; next }
            !($1 in known) { printf "%s\t%s\taur\t%s\n", $1, $2, $3 }
        ' <(echo "$sync_data") <(echo "$query_data")
    else
        pacman -Qm 2>/dev/null | while read -r name version; do
            local install_date
            install_date=$(pacman -Qi "$name" 2>/dev/null | awk -F': ' '/^Install Date/{print $2; exit}')
            printf '%s\t%s\taur\t%s\n' "$name" "$version" "${install_date:-unknown}"
        done
    fi
}

# --- Format: plain text ---
format_text() {
    local official_pkgs="$1"
    local aur_pkgs="$2"
    local hostname
    hostname=$(hostname)
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    echo "# Package snapshot"
    echo "# Host     : ${hostname}"
    echo "# Date     : ${timestamp}"
    echo "# Generated: export-pkglist.sh"
    echo ""

    if "$INCLUDE_OFFICIAL" && [[ -n "$official_pkgs" ]]; then
        local count
        count=$(echo "$official_pkgs" | grep -c '.' || true)
        echo "## Official packages (${count})"
        echo ""
        printf '%-45s %-25s %s\n' "NAME" "VERSION" "REPO"
        printf '%s\n' "$(printf '%.0s─' {1..80})"
        echo "$official_pkgs" | while IFS=$'\t' read -r name version repo _; do
            printf '%-45s %-25s %s\n' "$name" "$version" "$repo"
        done
        echo ""
    fi

    if "$INCLUDE_AUR" && [[ -n "$aur_pkgs" ]]; then
        local count
        count=$(echo "$aur_pkgs" | grep -c '.' || true)
        echo "## AUR packages (${count})"
        echo ""
        printf '%-45s %s\n' "NAME" "VERSION"
        printf '%s\n' "$(printf '%.0s─' {1..70})"
        echo "$aur_pkgs" | while IFS=$'\t' read -r name version _ _; do
            printf '%-45s %s\n' "$name" "$version"
        done
        echo ""
    fi
}

# --- Format: JSON ---
format_json() {
    local official_pkgs="$1"
    local aur_pkgs="$2"
    local hostname
    hostname=$(hostname)
    local timestamp
    timestamp=$(date --iso-8601=seconds)

    echo "{"
    echo "  \"meta\": {"
    echo "    \"host\": \"${hostname}\","
    echo "    \"generated_at\": \"${timestamp}\","
    echo "    \"generator\": \"export-pkglist.sh\""
    echo "  },"

    local first=true

    if "$INCLUDE_OFFICIAL" && [[ -n "$official_pkgs" ]]; then
        echo "  \"official\": ["
        local pkg_first=true
        while IFS=$'\t' read -r name version repo install_date; do
            "$pkg_first" || echo ","
            pkg_first=false
            printf '    {"name": "%s", "version": "%s", "repo": "%s", "install_date": "%s"}' \
                "$name" "$version" "$repo" "$install_date"
        done <<< "$official_pkgs"
        echo ""
        echo "  ],"
        first=false
    else
        echo "  \"official\": [],"
    fi

    if "$INCLUDE_AUR" && [[ -n "$aur_pkgs" ]]; then
        echo "  \"aur\": ["
        local pkg_first=true
        while IFS=$'\t' read -r name version _ install_date; do
            "$pkg_first" || echo ","
            pkg_first=false
            printf '    {"name": "%s", "version": "%s", "repo": "aur", "install_date": "%s"}' \
                "$name" "$version" "$install_date"
        done <<< "$aur_pkgs"
        echo ""
        echo "  ]"
    else
        echo "  \"aur\": []"
    fi

    echo "}"
}

# --- Format: pacman restore (name only, one per line) ---
# Compatible with: pacman -S - < file  or  paru -S - < file
format_pacman() {
    local official_pkgs="$1"
    local aur_pkgs="$2"

    if "$INCLUDE_OFFICIAL" && [[ -n "$official_pkgs" ]]; then
        echo "$official_pkgs" | awk -F'\t' '{print $1}'
    fi
    if "$INCLUDE_AUR" && [[ -n "$aur_pkgs" ]]; then
        echo "$aur_pkgs" | awk -F'\t' '{print $1}'
    fi
}

# --- Main ---
main() {
    section "Package List Export"
    require_cmds pacman

    parse_args "$@"

    info "Collecting package data — this may take a moment…"
    echo ""

    local official_pkgs="" aur_pkgs=""

    if "$INCLUDE_OFFICIAL"; then
        info "Scanning official packages…"
        official_pkgs=$(get_official_pkgs)
        local n_official
        n_official=$(echo "$official_pkgs" | grep -c '.' || true)
        ok "Official: ${n_official} package(s)"
    fi

    if "$INCLUDE_AUR"; then
        info "Scanning AUR packages…"
        aur_pkgs=$(get_aur_pkgs)
        local n_aur
        n_aur=$(echo "$aur_pkgs" | grep -c '.' || true)
        ok "AUR: ${n_aur} package(s)"
    fi

    echo ""

    # Build output content
    local content
    case "$FORMAT" in
        text)   content=$(format_text   "$official_pkgs" "$aur_pkgs") ;;
        json)   content=$(format_json   "$official_pkgs" "$aur_pkgs") ;;
        pacman) content=$(format_pacman "$official_pkgs" "$aur_pkgs") ;;
    esac

    if "$PRINT_ONLY"; then
        echo "$content"
        return
    fi

    # Save to file
    mkdir -p "$OUTPUT_DIR" || fatal "Cannot create output directory: ${OUTPUT_DIR}"

    local ext="txt"
    [[ "$FORMAT" == "json" ]]   && ext="json"
    [[ "$FORMAT" == "pacman" ]] && ext="pkglist"

    local filename="${OUTPUT_DIR}/pkgs_$(hostname)_$(date '+%Y%m%d_%H%M%S').${ext}"

    echo "$content" > "$filename" \
        || fatal "Could not write to ${filename}"

    ok "Snapshot saved to: ${BOLD}${filename}${RESET}"
    info "Format: ${FORMAT} — use diff-pkglist.sh to compare snapshots."
}

main "$@"
