#!/usr/bin/env bash
# ============================================================
# clean-system.sh
# Description : System cleanup: orphan packages, pacman cache
#               (keeps last 2 versions), AUR helper caches (yay/paru:
#               uninstalled packages, old builds, stale sources) and
#               log cleanup via clean-logs.sh.
#               All destructive actions require confirmation.
# Dependencies: pacman, paccache (pacman-contrib), journalctl, find, du,
#               pgrep; git (optional, AUR stale source cleanup)
# Compatibility: CachyOS, Arch Linux
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

KEEP_VERSIONS="${KEEP_VERSIONS:-2}"       # Versions of each package to keep in cache
MAX_LOG_SIZE="${MAX_LOG_SIZE:-500M}"      # Max journald log size to keep
MAX_JOURNAL_DAYS="${MAX_JOURNAL_DAYS:-30}" # Max journal age in days

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

# --- paccache dry run ---
# Lists the package files a paccache run would remove (signatures omitted) and
# the space it would free. Returns 1 when there is nothing to remove — paccache
# itself exits 0 either way, so its output is the only signal.
# Usage: paccache_preview <paccache options...>
paccache_preview() {
    local out saved
    local -a pkgs=()

    out=$(paccache -dv --nocolor "$@" 2>/dev/null)
    saved=$(sed -n 's/^==> finished dry run: .*disk space saved: \(.*\))$/\1/p' <<< "$out")
    [[ -n "$saved" ]] || return 1

    mapfile -t pkgs < <(sed -n '/^==> Candidate packages:/,/^$/p' <<< "$out" \
        | grep -v -e '^==>' -e '\.sig$' -e '^$')
    printf '    %s\n' "${pkgs[@]}"
    info "${#pkgs[@]} package file(s), ${saved} to free."
}

# --- Pacman cache ---
clean_pkg_cache() {
    section "Package cache (pacman)"

    require_cmds paccache

    local cache_size
    cache_size=$(du -sh /var/cache/pacman/pkg/ 2>/dev/null | cut -f1)
    info "Current cache size: ${cache_size}"
    info "Keeping last ${KEEP_VERSIONS} versions of each package."

    if ! paccache_preview -k "$KEEP_VERSIONS"; then
        ok "No old package versions to remove."
    elif confirm "Clean cache keeping ${KEEP_VERSIONS} version(s) per package?"; then
        if sudo paccache -r -k "$KEEP_VERSIONS"; then
            ok "Package cache cleaned."
        else
            error "Error cleaning package cache."
        fi
    else
        info "Cache cleanup skipped."
    fi

    echo ""
    info "Cache for packages that are no longer installed:"
    if ! paccache_preview -u -k 0; then
        ok "None found."
    elif confirm "Remove cache for uninstalled packages?"; then
        if sudo paccache -ru -k 0; then
            ok "Uninstalled packages cache removed."
        else
            error "Error removing uninstalled packages cache."
        fi
    else
        info "Skipped."
    fi
}

# ============================================================
# AUR helper caches (yay / paru)
# ============================================================
# Every AUR package gets its own git clone under the helper's cache dir and
# makepkg builds inside it. With no PKGDEST/SRCDEST set, every built package and
# every downloaded source is left there too, so each update adds another copy
# that paccache — which only scans the pacman cache — never removes.

# Mirrors makepkg's get_protocol + get_filename: the name a .SRCINFO source
# entry is saved under inside the clone dir.
srcinfo_filename() {
    local netfile="$1" proto filename

    if [[ "$netfile" == *::* ]]; then
        printf '%s\n' "${netfile%%::*}"
        return
    fi

    if [[ "$netfile" == *://* ]]; then
        proto="${netfile%%://*}"
        proto="${proto%%+*}"
    elif [[ "$netfile" == *lp:* ]]; then
        proto="${netfile%%+lp:*}"
    else
        proto="local"
    fi

    case "$proto" in
        bzr|fossil|git|hg|svn)
            filename="${netfile%%#*}"
            filename="${filename%%\?*}"
            filename="${filename%/}"
            filename="${filename##*/}"
            [[ "$proto" == bzr    ]] && filename="${filename#*lp:}"
            [[ "$proto" == fossil ]] && filename="${filename}.fossil"
            [[ "$proto" == git    ]] && filename="${filename%%.git*}"
            ;;
        *)
            filename="${netfile##*/}"
            ;;
    esac
    printf '%s\n' "$filename"
}

# True when any package built from this clone dir is installed. Split packages
# build several pkgnames from one pkgbase, so every pkgname in .SRCINFO counts.
aur_dir_installed() {
    local dir="$1" name
    local -a names=()

    [[ -f "${dir}/.SRCINFO" ]] && mapfile -t names < <(sed -n 's/^[[:space:]]*pkgname = //p' "${dir}/.SRCINFO")
    (( ${#names[@]} )) || names=("${dir##*/}")

    for name in "${names[@]}"; do
        pacman -Q "$name" &>/dev/null && return 0
    done
    return 1
}

# --- AUR: build dirs of uninstalled packages ---
clean_aur_uninstalled() {
    local cache="$1" dir
    local -a stale=()

    for dir in "$cache"/*/; do
        dir="${dir%/}"
        [[ -L "$dir" ]] && continue
        aur_dir_installed "$dir" || stale+=("$dir")
    done

    if (( ${#stale[@]} == 0 )); then
        ok "No build dirs left over from uninstalled packages."
        return 0
    fi

    warn "${#stale[@]} build dir(s) for packages that are no longer installed:"
    for dir in "${stale[@]}"; do
        printf "    %-35s %s\n" "${dir##*/}" "$(du -sh "$dir" 2>/dev/null | cut -f1)"
    done

    confirm "Remove them?" || { info "Skipped."; return 0; }

    if rm -rf -- "${stale[@]}"; then
        ok "Removed ${#stale[@]} build dir(s)."
    else
        error "Some build dirs could not be removed."
    fi
}

# --- AUR: old built packages ---
# paccache only globs the top level of a cachedir, so each clone dir is passed
# as its own -c. Same keep policy as the pacman cache.
clean_aur_packages() {
    local cache="$1" dir
    local -a args=()

    for dir in "$cache"/*/; do
        [[ -L "${dir%/}" ]] || args+=(-c "${dir%/}")
    done
    (( ${#args[@]} )) || return 0

    info "Built packages (keeping last ${KEEP_VERSIONS} of each):"
    if ! paccache_preview -k "$KEEP_VERSIONS" "${args[@]}"; then
        ok "No old built packages."
        return 0
    fi

    confirm "Remove old built packages?" || { info "Skipped."; return 0; }

    if paccache -r --nocolor -k "$KEEP_VERSIONS" "${args[@]}"; then
        ok "Old built packages removed."
    else
        error "Error removing old built packages."
    fi
}

# --- AUR: stale sources and build leftovers ---
# Whatever the AUR repo does not track was produced by makepkg: downloaded
# sources, src/ and pkg/ build trees, logs. Only the sources the current
# .SRCINFO still lists are kept — that includes VCS clones, which are expensive
# to fetch again. Built packages are left to clean_aur_packages.
clean_aur_sources() {
    local cache="$1" dir entry name pkgbase bytes total=0
    local -a stale=() order=()
    local -A keep=() count=() size=()

    if ! command -v git &>/dev/null; then
        warn "git not found — stale source cleanup skipped."
        return 0
    fi

    for dir in "$cache"/*/; do
        dir="${dir%/}"
        [[ -L "$dir" || ! -d "${dir}/.git" || ! -f "${dir}/.SRCINFO" ]] && continue
        pkgbase="${dir##*/}"

        keep=()
        while IFS= read -r entry; do
            name=$(srcinfo_filename "$entry")
            [[ -n "$name" ]] && keep[$name]=1
        done < <(sed -n 's/^[[:space:]]*source\(_[A-Za-z0-9_]*\)\{0,1\} = //p' "${dir}/.SRCINFO")

        # safe.directory: under sudo, git refuses to read a repo owned by another
        # user and would silently report nothing to clean.
        while IFS= read -r -d '' entry; do
            name="${entry%/}"
            [[ "$name" == *.pkg.tar* ]] && continue
            [[ -n "${keep[$name]:-}" ]] && continue

            bytes=$(du -sb -- "${dir}/${name}" 2>/dev/null | cut -f1)
            stale+=("${dir}/${name}")
            [[ -n "${count[$pkgbase]:-}" ]] || order+=("$pkgbase")
            count[$pkgbase]=$(( ${count[$pkgbase]:-0} + 1 ))
            size[$pkgbase]=$(( ${size[$pkgbase]:-0} + ${bytes:-0} ))
            total=$(( total + ${bytes:-0} ))
        done < <(git -c safe.directory="$dir" -C "$dir" ls-files -oz --directory 2>/dev/null)
    done

    info "Sources and build leftovers no longer used by the current PKGBUILDs:"
    if (( ${#stale[@]} == 0 )); then
        ok "None found."
        return 0
    fi

    for pkgbase in "${order[@]}"; do
        printf "    %-35s %3d item(s)  %s\n" \
            "$pkgbase" "${count[$pkgbase]}" "$(numfmt --to=iec-i --suffix=B "${size[$pkgbase]}")"
    done
    info "${#stale[@]} item(s), $(numfmt --to=iec-i --suffix=B "$total") to free."

    confirm "Remove them?" || { info "Skipped."; return 0; }

    if rm -rf -- "${stale[@]}"; then
        ok "Stale sources removed."
    else
        error "Some files could not be removed."
    fi
}

# --- AUR helper caches ---
clean_aur_cache() {
    section "Package cache (AUR helpers)"

    local -a caches=()
    mapfile -t caches < <(aur_cache_dirs)
    if (( ${#caches[@]} == 0 )); then
        info "No yay or paru cache found."
        return 0
    fi

    # Removing a clone dir or its src/ while makepkg is building in it breaks
    # that build.
    if pgrep -x yay &>/dev/null || pgrep -x paru &>/dev/null || pgrep -x makepkg &>/dev/null; then
        warn "An AUR helper or makepkg is running — AUR cache cleanup skipped."
        return 0
    fi

    local cache
    for cache in "${caches[@]}"; do
        info "Cache: ${cache} ($(du -sh "$cache" 2>/dev/null | cut -f1))"
        echo ""
        clean_aur_uninstalled "$cache"
        echo ""
        clean_aur_packages "$cache"
        echo ""
        clean_aur_sources "$cache"
    done
}

# --- Log cleanup (delegates to logs/clean-logs.sh) ---
clean_logs() {
    section "System logs"

    local clean_logs_script="${SCRIPT_DIR}/../logs/clean-logs.sh"

    if [[ ! -x "$clean_logs_script" ]]; then
        warn "logs/clean-logs.sh not found or not executable — skipping log cleanup."
        return 0
    fi

    info "Delegating to clean-logs.sh (journal vacuum + /var/log cleanup)."
    echo ""

    # Run in dry-run first so the user sees what will be cleaned
    bash "$clean_logs_script" \
        --journal-size "$MAX_LOG_SIZE" \
        --journal-days "$MAX_JOURNAL_DAYS"

    echo ""
    confirm "Apply log cleanup as shown above?" || {
        info "Log cleanup skipped."
        return 0
    }

    sudo bash "$clean_logs_script" \
        --journal-size "$MAX_LOG_SIZE" \
        --journal-days "$MAX_JOURNAL_DAYS" \
        --confirm
}

# --- Summary ---
print_summary() {
    section "Disk space summary"
    df -h / | awk 'NR==2 {printf "  Root: %s used of %s (%s free)\n", $3, $2, $4}'
}

# --- Main ---
main() {
    section "CachyOS System Cleanup"

    clean_orphans
    clean_pkg_cache
    clean_aur_cache
    clean_logs
    print_summary

    ok "Cleanup complete."
}

main "$@"
