#!/usr/bin/env bash
# ============================================================
# full-upgrade.sh
# Description : Full system upgrade with optional pre-upgrade Btrfs
#               snapshot, package list snapshot, keyring refresh, AUR
#               update review (security/aur-gate.sh) and firmware
#               updates via fwupd/LVFS.
#               Detects package manager automatically.
# Dependencies: pacman, paru or yay (optional), btrfs-progs (optional),
#               fwupd (optional, firmware stage), jq (optional, per-device
#               firmware selection)
# Compatibility: CachyOS, Arch Linux
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

SNAPSHOT_SUBVOL="${SNAPSHOT_SUBVOL:-/}"
SNAPSHOT_DIR="${SNAPSHOT_DIR:-/.snapshots}"

PACKAGES_ENABLED=true       # false with --firmware-only
FIRMWARE_MODE="ask"         # ask | always | never
AUR_SCOPE=""                # "--repo" when this run skips AUR updates

# Refuse to flash below this battery level when running without AC power.
FW_MIN_BATTERY="${FW_MIN_BATTERY:-30}"
# UEFI capsule updates are staged on the ESP; below this it is not worth trying.
FW_MIN_ESP_MB="${FW_MIN_ESP_MB:-64}"
# Never nag about uploading update history to LVFS — nothing leaves the machine
# unless the user runs 'fwupdmgr report-history' themselves.
FW_OPTS=(--no-unreported-check)

# --- Usage ---
usage() {
    cat <<'EOF'
Usage: full-upgrade.sh [OPTIONS]

Full system upgrade: pre-upgrade Btrfs snapshot, package list snapshot,
keyring refresh, package upgrade and optional firmware updates.

Options:
  --firmware        Always run the firmware stage (skip the "check firmware?"
                    question; flashing is still confirmed device by device)
  --no-firmware     Skip the firmware stage entirely
  --firmware-only   Only update firmware (skip snapshots and packages)
  -h, --help        Show this help

Environment:
  SNAPSHOT_SUBVOL   Subvolume to snapshot (default: /)
  SNAPSHOT_DIR      Where snapshots are stored (default: /.snapshots)
  FW_MIN_BATTERY    Minimum battery % to flash without AC (default: 30)
  FW_MIN_ESP_MB     Minimum free space on the ESP, in MB (default: 64)
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --firmware)      FIRMWARE_MODE="always"; shift ;;
            --no-firmware)   FIRMWARE_MODE="never";  shift ;;
            --firmware-only) FIRMWARE_MODE="always"; PACKAGES_ENABLED=false; shift ;;
            -h|--help)       usage; exit 0 ;;
            # Unknown flags are fatal on purpose: silently ignoring a typo such
            # as --no-firmwar would flash firmware the user asked to skip.
            *) usage >&2; fatal "Unknown argument: $1" ;;
        esac
    done

    if [[ "$FIRMWARE_MODE" == "never" ]] && ! $PACKAGES_ENABLED; then
        fatal "--firmware-only and --no-firmware cannot be combined — nothing would run."
    fi
}

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

# --- AUR update review ---
# Runs aur-gate.sh over the pending AUR updates before anything is built, so a
# risky update can be skipped with a repo-only upgrade instead of being stopped
# halfway through the transaction. Read-only: it does not sync the databases.
try_aur_preflight() {
    [[ "$PKG_MANAGER" == pacman ]] && return 0
    local gate="${SCRIPT_DIR}/../security/aur-gate.sh"
    [[ -f "$gate" ]] || return 0

    section "AUR update review"
    local rc reply
    bash "$gate" pending
    rc=$?

    case $rc in
        0) ;;
        1) info "Some AUR updates need a look — see the notes above." ;;
        2)
            warn "At least one AUR update was flagged as dangerous."
            echo -en "${WARN} [r] upgrade repo packages only  [c] continue anyway  [a] abort  (default: r): "
            read -r reply
            case "${reply,,}" in
                c) info "Continuing. If aur-gate is installed as makepkg it asks again before each flagged build." ;;
                a) info "Upgrade cancelled."; exit 0 ;;
                *) AUR_SCOPE="--repo"; info "AUR updates skipped for this run." ;;
            esac
            ;;
        *)
            warn "AUR update review failed (exit ${rc})."
            confirm "Continue with the upgrade anyway?" || exit 1
            ;;
    esac
}

# --- Upgrade ---
run_upgrade() {
    section "Upgrading system with ${PKG_MANAGER}"

    local cmd
    case "$PKG_MANAGER" in
        paru)   cmd="paru -Syu${AUR_SCOPE:+ $AUR_SCOPE}" ;;
        yay)    cmd="yay -Syu${AUR_SCOPE:+ $AUR_SCOPE}" ;;
        pacman) cmd="sudo pacman -Syu" ;;
    esac

    info "Command: ${cmd}"
    confirm "Start upgrade now?" || {
        info "Package upgrade cancelled."
        # Firmware does not depend on the package upgrade, so returning instead
        # of exiting lets that stage still run. With no firmware stage pending
        # there is nothing left to do.
        [[ "$FIRMWARE_MODE" == "never" ]] && exit 0
        return 1
    }

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

# ============================================================
# Firmware updates (fwupd / LVFS)
# ============================================================

# Parallel arrays describing the pending updates, one entry per device.
FW_IDS=(); FW_NAMES=(); FW_FROM=(); FW_TO=(); FW_FLAGS=(); FW_PROTO=()
FW_SELECTED=()

# fwupdmgr reports "nothing to do" as exit code 2, which is not a failure.
fw_rc_ok() { (( $1 == 0 || $1 == 2 )); }

# --- Availability ---
# Checks both the client and the daemon: fwupd is D-Bus activated, so an
# installed fwupdmgr says nothing about whether the service can actually start.
fw_available() {
    if ! command -v fwupdmgr &>/dev/null; then
        info "fwupd is not installed — firmware updates skipped."
        info "Install it with: ${PKG_MANAGER:-pacman} -S fwupd"
        return 1
    fi

    local err rc
    err=$(fwupdmgr get-devices --json "${FW_OPTS[@]}" 2>&1 >/dev/null)
    rc=$?
    if ! fw_rc_ok "$rc"; then
        warn "fwupd is installed but the daemon is not responding (exit ${rc})."
        [[ -n "$err" ]] && printf '%s\n' "$err" | tail -n 3 >&2
        info "Try: sudo systemctl start fwupd"
        return 1
    fi
}

# --- Power source ---
# Echoes "ac" or "battery:<pct>". Peripheral batteries report scope=Device
# (wireless mice, keyboards, headsets) and are ignored — otherwise a desktop
# with a Logitech mouse would look like a laptop running on battery.
fw_power_state() {
    local ps type scope pct="" have_bat=false on_ac=false

    for ps in /sys/class/power_supply/*; do
        [[ -d "$ps" ]] || continue
        type=$(cat "$ps/type" 2>/dev/null)
        scope=$(cat "$ps/scope" 2>/dev/null)
        [[ "$scope" == "Device" ]] && continue

        case "$type" in
            Battery)
                have_bat=true
                [[ -z "$pct" ]] && pct=$(cat "$ps/capacity" 2>/dev/null)
                ;;
            Mains|USB|UPS)
                [[ "$(cat "$ps/online" 2>/dev/null)" == "1" ]] && on_ac=true
                ;;
        esac
    done

    # No system battery at all: desktop or server, so always mains powered.
    if ! $have_bat || $on_ac; then
        echo "ac"
    else
        echo "battery:${pct:-unknown}"
    fi
}

fw_check_power() {
    local state pct level
    state=$(fw_power_state)
    [[ "$state" == "ac" ]] && return 0

    pct="${state#battery:}"
    if [[ "$pct" =~ ^[0-9]+$ ]]; then
        if (( pct < FW_MIN_BATTERY )); then
            error "On battery at ${pct}% (minimum ${FW_MIN_BATTERY}%) — firmware updates skipped."
            info "Plug in AC power and re-run with --firmware-only."
            return 1
        fi
        level="${pct}%"
    else
        level="charge unknown"
    fi

    warn "Running on battery (${level}). Losing power mid-flash can brick a device."
    confirm "Continue without AC power?" || return 1
}

# --- ESP free space ---
# A UEFI capsule update is written to the EFI System Partition and only applied
# by the firmware on the next boot. A full ESP makes it fail there, long after
# this script has exited, so check it up front.
fw_check_esp() {
    local esp avail
    command -v bootctl &>/dev/null && esp=$(bootctl --print-esp-path 2>/dev/null)
    [[ -z "$esp" ]] && esp=$(findmnt -rno TARGET -t vfat 2>/dev/null | grep -m1 -E '^/(boot|efi)')
    [[ -n "$esp" && -d "$esp" ]] || return 0

    avail=$(df -Pm "$esp" 2>/dev/null | awk 'NR==2 {print $4}')
    [[ "$avail" =~ ^[0-9]+$ ]] || return 0

    if (( avail < FW_MIN_ESP_MB )); then
        warn "Only ${avail} MB free on the ESP (${esp}) — UEFI updates may fail to stage."
        info "Free some space there, or drop old kernels from ${esp}."
        confirm "Continue anyway?" || return 1
    else
        info "ESP ${esp}: ${avail} MB free."
    fi
    return 0
}

# True when at least one pending update goes through the UEFI capsule path.
fw_needs_esp() {
    local p
    for p in "${FW_PROTO[@]}"; do
        [[ "$p" == *uefi* ]] && return 0
    done
    return 1
}

# --- Metadata refresh ---
fw_refresh() {
    info "Refreshing firmware metadata from LVFS…"

    local rc
    fwupdmgr refresh "${FW_OPTS[@]}"
    rc=$?
    # 2 means the metadata on disk is already current.
    fw_rc_ok "$rc" && return 0

    warn "Could not refresh firmware metadata (exit ${rc})."
    confirm "Continue with the metadata already on disk?" || return 1
}

# --- Collect pending updates ---
# Fills the FW_* arrays. Returns 0 when there is something to flash, 1 when the
# firmware is current or the list could not be read.
fw_collect() {
    FW_IDS=(); FW_NAMES=(); FW_FROM=(); FW_TO=(); FW_FLAGS=(); FW_PROTO=()

    local out rc
    # stderr is dropped rather than merged: fwupd writes GLib warnings there
    # that would otherwise end up inside the JSON document.
    out=$(fwupdmgr get-updates --json "${FW_OPTS[@]}" 2>/dev/null)
    rc=$?

    if ! command -v jq &>/dev/null; then
        # Without jq there is no way to split the list per device, so fall back
        # to fwupd's own report and an all-or-nothing decision.
        if (( rc != 0 )); then
            (( rc == 2 )) && ok "Firmware is up to date." \
                          || warn "Could not read the firmware update list (exit ${rc})."
            return 1
        fi
        info "jq is not installed — per-device selection unavailable."
        fwupdmgr get-updates "${FW_OPTS[@]}"
        FW_IDS=("ALL")   # sentinel consumed by fw_apply
        return 0
    fi

    local n
    n=$(jq -r '(.Devices // []) | length' <<< "$out" 2>/dev/null)
    [[ "$n" =~ ^[0-9]+$ ]] || n=0

    if (( n == 0 )); then
        local msg
        msg=$(jq -r '.Error.Message // empty' <<< "$out" 2>/dev/null)
        if ! fw_rc_ok "$rc" && [[ -n "$msg" ]]; then
            warn "Could not read the firmware update list: ${msg}"
        elif ! fw_rc_ok "$rc"; then
            warn "Could not read the firmware update list (exit ${rc})."
        else
            ok "Firmware is up to date."
        fi
        return 1
    fi

    local id name from to flags proto
    while IFS=$'\t' read -r id name from to flags proto; do
        [[ -z "$id" ]] && continue
        FW_IDS+=("$id")
        FW_NAMES+=("$name")
        FW_FROM+=("$from")
        FW_TO+=("$to")
        FW_FLAGS+=("$flags")
        FW_PROTO+=("$proto")
    done < <(jq -r '.Devices[]
        | [ .DeviceId,
            (.Name // "Unknown device"),
            (.Version // "?"),
            (.Releases[0].Version // "?"),
            ((.Flags // []) | join(",")),
            (.Releases[0].Protocol // ((.Protocols // []) | join(","))) ]
        | @tsv' <<< "$out" 2>/dev/null)

    (( ${#FW_IDS[@]} > 0 ))
}

# --- Show pending updates ---
fw_show() {
    local i note
    echo ""
    info "${#FW_IDS[@]} device(s) with a firmware update available:"
    echo ""
    for i in "${!FW_IDS[@]}"; do
        note=""
        if   [[ "${FW_FLAGS[$i]}" == *needs-shutdown* ]]; then note=" ${YELLOW}(shutdown required)${RESET}"
        elif [[ "${FW_FLAGS[$i]}" == *needs-reboot*   ]]; then note=" ${YELLOW}(reboot required)${RESET}"
        fi
        printf "    [%d] %-32s %s → %b\n" \
            "$((i + 1))" "${FW_NAMES[$i]}" "${FW_FROM[$i]}" "${FW_TO[$i]}${note}"
    done
    echo ""
}

# --- Choose what to flash ---
# Fills FW_SELECTED with indexes into the FW_* arrays.
fw_select() {
    FW_SELECTED=()
    local reply tok bad

    while true; do
        echo -en "${WARN} Apply which updates? [a]ll / [s]kip / numbers (e.g. 1 3): "
        read -r reply || { echo ""; return 1; }

        case "${reply,,}" in
            a|all)         FW_SELECTED=("${!FW_IDS[@]}"); return 0 ;;
            s|skip|n|none|"") info "Firmware updates skipped."; return 1 ;;
        esac

        FW_SELECTED=()
        bad=false
        local -A seen=()
        for tok in $reply; do
            if [[ ! "$tok" =~ ^[0-9]+$ ]] || (( tok < 1 || tok > ${#FW_IDS[@]} )); then
                warn "Invalid selection: ${tok}"
                bad=true
                break
            fi
            # Repeated numbers would flash the same device twice.
            [[ -n "${seen[$tok]:-}" ]] && continue
            seen[$tok]=1
            FW_SELECTED+=("$((tok - 1))")
        done

        if ! $bad && (( ${#FW_SELECTED[@]} > 0 )); then
            return 0
        fi
    done
}

# --- Apply ---
# --no-reboot-check stops fwupdmgr from prompting for a reboot after every
# device; fw_post reports once, after the whole batch.
fw_apply() {
    local failed=0 rc i

    if [[ "${FW_IDS[0]}" == "ALL" ]]; then
        section "Updating all firmware"
        fwupdmgr update --no-reboot-check "${FW_OPTS[@]}"
        rc=$?
        fw_rc_ok "$rc" || failed=1
    else
        for i in "${FW_SELECTED[@]}"; do
            section "Updating ${FW_NAMES[$i]} (${FW_FROM[$i]} → ${FW_TO[$i]})"
            fwupdmgr update "${FW_IDS[$i]}" --no-reboot-check "${FW_OPTS[@]}"
            rc=$?
            if fw_rc_ok "$rc"; then
                ok "${FW_NAMES[$i]}: done."
            else
                error "${FW_NAMES[$i]}: failed (exit ${rc})."
                failed=$(( failed + 1 ))
            fi
        done
    fi

    if (( failed > 0 )); then
        warn "${failed} firmware update(s) failed — those devices keep their current firmware."
        info "Details: fwupdmgr get-history"
        return 1
    fi

    ok "Firmware updates applied."
}

# --- Reboot / shutdown notice ---
# Capsule updates are staged now and written by the device itself on the next
# boot, so the flash is not finished until the machine restarts.
fw_post() {
    local i needs_shutdown=false rc

    for i in "${FW_SELECTED[@]}"; do
        [[ "${FW_FLAGS[$i]}" == *needs-shutdown* ]] && needs_shutdown=true
    done

    fwupdmgr check-reboot-needed "${FW_OPTS[@]}" &>/dev/null
    rc=$?

    if (( rc == 0 )); then
        if $needs_shutdown; then
            warn "Power off completely (not just reboot) to finish flashing the firmware."
        else
            warn "Reboot to finish flashing the firmware."
        fi
        info "Verify afterwards with: fwupdmgr get-history"
    elif (( rc == 2 )); then
        ok "No reboot needed."
    fi
}

# --- Firmware stage ---
try_firmware() {
    [[ "$FIRMWARE_MODE" == "never" ]] && return 0

    section "Firmware updates (fwupd)"

    if [[ "$FIRMWARE_MODE" == "ask" ]]; then
        confirm "Check for firmware updates?" || { info "Firmware stage skipped."; return 0; }
    fi

    fw_available   || return 0
    fw_check_power || return 0
    fw_refresh     || return 0
    fw_collect     || return 0

    # Protocols are unknown without jq, so check the ESP in that case too.
    if (( ${#FW_PROTO[@]} == 0 )) || fw_needs_esp; then
        fw_check_esp || return 0
    fi

    if [[ "${FW_IDS[0]}" != "ALL" ]]; then
        fw_show
        fw_select || return 0
    fi

    echo ""
    warn "Firmware is flashed by the device itself: a Btrfs snapshot cannot undo it,"
    warn "and an interrupted flash can leave the device unusable."
    confirm_critical "Flash the selected firmware now?" || {
        info "Firmware updates cancelled."
        return 0
    }

    fw_apply
    fw_post
}

# --- Main ---
main() {
    parse_args "$@"

    section "CachyOS Full Upgrade"

    if $PACKAGES_ENABLED; then
        detect_pkg_manager
        try_aur_preflight
        try_snapshot
        try_pkg_snapshot
        # A cancelled upgrade leaves nothing to diff, but the firmware stage
        # below still runs.
        run_upgrade && try_pkg_diff
    else
        info "Firmware-only run — snapshots and package upgrade skipped."
    fi

    try_firmware
}

main "$@"
