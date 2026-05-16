#!/usr/bin/env bash
# ============================================================
# clean-system.sh
# Description : System cleanup: orphan packages, pacman cache
#               (keeps last 2 versions), systemd journal rotation.
#               All destructive actions require confirmation.
# Dependencies: pacman, paccache (pacman-contrib), journalctl
# Compatibility: CachyOS, Arch Linux
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

KEEP_VERSIONS="${KEEP_VERSIONS:-2}"       # Versions of each package to keep in cache
MAX_LOG_SIZE="${MAX_LOG_SIZE:-500M}"      # Max journald log size to keep

# --- Orphan packages ---
clean_orphans() {
    section "Orphan packages"

    local orphans
    mapfile -t orphans < <(pacman -Qdtq 2>/dev/null)

    if [[ ${#orphans[@]} -eq 0 ]]; then
        ok "No orphan packages found."
        return 0
    fi

    warn "${#orphans[@]} orphan package(s) found (not required by any other package)."
    echo ""
    echo -e "  ${YELLOW}Note: orphan does not mean unused — review carefully before removing.${RESET}"
    echo ""

    # Show each package with index and description
    local i=1
    for pkg in "${orphans[@]}"; do
        local desc
        desc=$(pacman -Qi "$pkg" 2>/dev/null | awk -F': ' '/^Description/{print $2}')
        printf "    [%2d] %-35s %s\n" "$i" "$pkg" "${desc:-(no description)}"
        ((i++))
    done

    echo ""
    echo -e "  Enter package numbers to remove (e.g. ${BOLD}1,3,5${RESET}), ${BOLD}all${RESET}, or ${BOLD}none${RESET} to skip:"
    echo -n "  Selection: "
    read -r selection

    if [[ -z "$selection" || "$selection" == "none" ]]; then
        info "Orphan cleanup skipped."
        return 0
    fi

    local to_remove=()

    if [[ "$selection" == "all" ]]; then
        to_remove=("${orphans[@]}")
    else
        # Parse comma-separated indices
        IFS=',' read -ra indices <<< "$selection"
        for idx in "${indices[@]}"; do
            idx="${idx// /}"  # trim spaces
            if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#orphans[@]} )); then
                to_remove+=("${orphans[$((idx - 1))]}")
            else
                warn "Invalid selection ignored: '${idx}'"
            fi
        done
    fi

    if [[ ${#to_remove[@]} -eq 0 ]]; then
        info "No valid packages selected. Skipping."
        return 0
    fi

    echo ""
    warn "The following packages will be removed:"
    for pkg in "${to_remove[@]}"; do
        echo "    - ${pkg}"
    done

    confirm_critical "Remove ${#to_remove[@]} package(s)?" || {
        info "Orphan cleanup cancelled."
        return 0
    }

    if sudo pacman -Rns "${to_remove[@]}" --noconfirm; then
        ok "${#to_remove[@]} orphan package(s) removed."
    else
        error "Error removing some packages."
    fi
}

# --- Pacman cache ---
clean_pkg_cache() {
    section "Package cache (pacman)"

    require_cmds paccache

    local cache_size
    cache_size=$(du -sh /var/cache/pacman/pkg/ 2>/dev/null | cut -f1)
    info "Current cache size: ${cache_size}"
    info "Keeping last ${KEEP_VERSIONS} versions of each package."

    local to_remove
    to_remove=$(paccache -d -k "$KEEP_VERSIONS" 2>/dev/null | grep "==> cache" || true)
    if [[ -n "$to_remove" ]]; then
        info "Packages to remove from cache:"
        echo "$to_remove" | sed 's/^/    /'
    fi

    confirm "Clean cache keeping ${KEEP_VERSIONS} version(s) per package?" || {
        info "Cache cleanup skipped."
        return 0
    }

    if sudo paccache -r -k "$KEEP_VERSIONS"; then
        ok "Package cache cleaned."
    else
        error "Error cleaning package cache."
    fi

    local uninstalled
    uninstalled=$(paccache -du -k 0 2>/dev/null | grep "==> cache" || true)
    if [[ -n "$uninstalled" ]]; then
        warn "Cache found for uninstalled packages:"
        echo "$uninstalled" | sed 's/^/    /'
        confirm "Remove cache for uninstalled packages?" && \
            sudo paccache -ru -k 0 && ok "Uninstalled packages cache removed."
    fi
}

# --- Journal logs ---
clean_journal() {
    section "System logs (journald)"

    local current_size
    current_size=$(journalctl --disk-usage 2>/dev/null | grep -oP '[\d.]+ [A-Z]+' | head -1)
    info "Current journald usage: ${current_size:-unknown}"
    info "Target size limit: ${MAX_LOG_SIZE}"

    confirm "Rotate journald logs to a maximum of ${MAX_LOG_SIZE}?" || {
        info "Log cleanup skipped."
        return 0
    }

    if sudo journalctl --vacuum-size="$MAX_LOG_SIZE"; then
        ok "Logs rotated successfully."
    else
        error "Error rotating journald logs."
    fi
}

# --- Summary ---
print_summary() {
    section "Disk space summary"
    df -h / | awk 'NR==2 {printf "  Root: %s used of %s (%s free)\n", $3, $2, $4}'
}

# --- Main ---
main() {
    section "CachyOS System Cleanup"
    detect_pkg_manager

    clean_orphans
    clean_pkg_cache
    clean_journal
    print_summary

    ok "Cleanup complete."
}

main "$@"
