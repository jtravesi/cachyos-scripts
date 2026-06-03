#!/usr/bin/env bash
# ============================================================
# mount-manager.sh
# Description : Interactive manager to list, mount and unmount
#               block devices with filesystem detection. On mount you
#               can choose read-write/read-only and the location
#               (udisks default under /run/media, or a custom path via
#               sudo mount); NTFS read-write mounts are warned about
#               (Windows hibernation / dirty bit). Critical system
#               mounts (/, /boot, …) are never offered for unmount.
#               Can also add persistent UUID-based mounts to /etc/fstab
#               (backup + nofail + verify) and review existing entries.
# Dependencies: lsblk, findmnt; udisksctl (udisks2) and/or mount/umount
# Compatibility: Any Linux
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

BACKEND=""          # "udisks" or "mount"
declare -a LINES    # cached `lsblk -P` lines for the current view

# --- Pick the mount backend ---
detect_backend() {
    if command -v udisksctl &>/dev/null; then
        BACKEND="udisks"
    elif command -v mount &>/dev/null; then
        BACKEND="mount"
    else
        fatal "No usable backend found (need udisksctl or mount)."
    fi
}

# --- Extract a value from one `lsblk -P` line ---
# Anchored on start-of-line/whitespace so the key TYPE is not matched
# inside FSTYPE, etc.  Usage: lsblk_val "$line" FSTYPE
lsblk_val() {
    sed -n "s/.*\\(^\\|[[:space:]]\\)${2}=\"\\([^\"]*\\)\".*/\\2/p" <<< "$1"
}

# --- (Re)load the block-device list ---
load_devices() {
    mapfile -t LINES < <(lsblk -P -o PATH,TYPE,FSTYPE,LABEL,SIZE,MOUNTPOINT,RM,UUID 2>/dev/null)
}

# --- True if a mount point belongs to the OS and must not be unmounted ---
is_protected_mount() {
    case "$1" in
        /|/boot|/boot/efi|/efi|/usr|/var|/home|"[SWAP]") return 0 ;;
        /usr/*|/var/*) return 0 ;;
        *) return 1 ;;
    esac
}

# --- True if a device line is a real, non-virtual block device ---
is_real_block() {
    local path="$1" type="$2"
    [[ "$type" == "loop" ]] && return 1
    [[ "$path" == /dev/loop* || "$path" == /dev/zram* || "$path" == /dev/sr* ]] && return 1
    return 0
}

# --- Current device overview ---
# MOUNTPOINT is the last column on purpose: it carries color escapes, which
# would otherwise throw off %-Ns padding of any column printed after it.
show_devices() {
    section "Block devices"
    printf "  %-16s %-7s %-11s %-15s %-10s %s\n" \
        "DEVICE" "SIZE" "FSTYPE" "LABEL" "FLAGS" "MOUNTPOINT"
    printf "  %s\n" "$(printf '%.0s─' {1..86})"

    local line path type fstype label size mp rm flags mp_color
    for line in "${LINES[@]}"; do
        path=$(lsblk_val "$line" PATH)
        type=$(lsblk_val "$line" TYPE)
        is_real_block "$path" "$type" || continue

        fstype=$(lsblk_val "$line" FSTYPE)
        label=$(lsblk_val "$line" LABEL)
        size=$(lsblk_val "$line" SIZE)
        mp=$(lsblk_val "$line" MOUNTPOINT)
        rm=$(lsblk_val "$line" RM)

        # Truncate long labels so columns stay aligned
        (( ${#label} > 15 )) && label="${label:0:12}..."

        flags="-"
        [[ "$rm" == "1" ]] && flags="removable"

        if [[ -n "$mp" ]]; then
            if is_protected_mount "$mp"; then mp_color="$CYAN"; else mp_color="$GREEN"; fi
        else
            mp_color=""
            mp="-"
        fi

        printf "  %-16s %-7s %-11s %-15s %-10s ${mp_color}%s${RESET}\n" \
            "$path" "${size:--}" "${fstype:--}" "${label:--}" "$flags" "$mp"
    done
}

# --- Collect indices of devices that can be mounted ---
# Populates CAND_PATH / CAND_FSTYPE / CAND_LABEL / CAND_SIZE arrays.
collect_mountable() {
    CAND_PATH=(); CAND_FSTYPE=(); CAND_LABEL=(); CAND_SIZE=()
    local line path type fstype label size mp
    for line in "${LINES[@]}"; do
        path=$(lsblk_val "$line" PATH)
        type=$(lsblk_val "$line" TYPE)
        is_real_block "$path" "$type" || continue
        fstype=$(lsblk_val "$line" FSTYPE)
        mp=$(lsblk_val "$line" MOUNTPOINT)
        # Mountable: has a filesystem, not already mounted, not swap/LUKS
        [[ -z "$fstype" || -n "$mp" ]] && continue
        [[ "$fstype" == "swap" || "$fstype" == "crypto_LUKS" ]] && continue
        CAND_PATH+=("$path")
        CAND_FSTYPE+=("$fstype")
        CAND_LABEL+=("$(lsblk_val "$line" LABEL)")
        CAND_SIZE+=("$(lsblk_val "$line" SIZE)")
    done
}

# --- Collect indices of devices that can be unmounted ---
# Populates CAND_PATH / CAND_MP arrays (protected mounts excluded).
collect_unmountable() {
    CAND_PATH=(); CAND_MP=()
    local line path type mp
    for line in "${LINES[@]}"; do
        path=$(lsblk_val "$line" PATH)
        type=$(lsblk_val "$line" TYPE)
        is_real_block "$path" "$type" || continue
        mp=$(lsblk_val "$line" MOUNTPOINT)
        [[ -z "$mp" ]] && continue
        is_protected_mount "$mp" && continue
        CAND_PATH+=("$path")
        CAND_MP+=("$mp")
    done
}

# --- Backend mount ---
# Usage: mount_device DEV LABEL MODE LOCATION CUSTOM_PATH
#   MODE      = rw | ro
#   LOCATION  = default | custom
#   CUSTOM    = explicit mount point when LOCATION=custom (else empty)
mount_device() {
    local dev="$1" label="$2" mode="$3" location="$4" custom="$5"
    local out opts=""
    [[ "$mode" == "ro" ]] && opts="ro"

    # Default location + udisks backend → /run/media via udisksctl (no sudo).
    if [[ "$location" == "default" && "$BACKEND" == "udisks" ]]; then
        local -a cmd=(udisksctl mount -b "$dev")
        [[ -n "$opts" ]] && cmd+=(-o "$opts")
        info "Mounting ${dev} via udisksctl (${mode})…"
        if out=$("${cmd[@]}" 2>&1); then
            ok "$out"
        else
            error "Mount failed: ${out}"
        fi
        return
    fi

    # Custom path, or default location without udisks → sudo mount at a path.
    command -v mount &>/dev/null || { error "mount command not available."; return; }
    local mp="$custom"
    if [[ -z "$mp" ]]; then
        local name="${label:-$(basename "$dev")}"
        mp="/mnt/${name// /_}"
    fi
    info "Mounting ${dev} at ${mp} (${mode}, sudo)…"
    if ! sudo mkdir -p "$mp"; then
        error "Could not create ${mp}."
        return
    fi
    local -a mopts=()
    [[ -n "$opts" ]] && mopts=(-o "$opts")
    if sudo mount "${mopts[@]}" "$dev" "$mp"; then
        ok "Mounted ${dev} at ${mp}"
    else
        error "Mount failed."
        # Remove the mount point only if we just created it and it's empty.
        sudo rmdir "$mp" 2>/dev/null
    fi
}

# --- Backend unmount ---
unmount_device() {
    local dev="$1"

    if [[ "$BACKEND" == "udisks" ]]; then
        info "Unmounting ${dev} via udisksctl…"
        local out
        if out=$(udisksctl unmount -b "$dev" 2>&1); then
            ok "$out"
        else
            error "Unmount failed: ${out}"
        fi
        return
    fi

    info "Unmounting ${dev} (sudo)…"
    if sudo umount "$dev"; then
        ok "Unmounted ${dev}"
    else
        error "Unmount failed — device may be busy. Close programs using it and retry."
    fi
}

# --- Mount action ---
do_mount() {
    collect_mountable
    if [[ ${#CAND_PATH[@]} -eq 0 ]]; then
        info "No unmounted filesystems available to mount."
        return
    fi

    section "Mount a device"
    local i
    for i in "${!CAND_PATH[@]}"; do
        printf "  [%d] %-16s %-8s %-11s %s\n" \
            $((i + 1)) "${CAND_PATH[i]}" "${CAND_SIZE[i]}" \
            "${CAND_FSTYPE[i]}" "${CAND_LABEL[i]:-(no label)}"
    done

    echo ""
    echo -n "  Select device to mount [1-${#CAND_PATH[@]}] (Enter to cancel): "
    read -r choice
    [[ -z "$choice" ]] && { info "Cancelled."; return; }

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#CAND_PATH[@]} )); then
        warn "Invalid selection."
        return
    fi

    local idx=$((choice - 1))
    local dev="${CAND_PATH[idx]}" fstype="${CAND_FSTYPE[idx]}" label="${CAND_LABEL[idx]}"
    local mode="rw" location="default" custom="" ans

    # --- Read/write vs read-only ---
    echo ""
    echo "  Mount mode:  [1] Read-write (default)   [2] Read-only"
    echo -n "  Choice [1-2] (Enter = read-write): "
    read -r ans
    [[ "$ans" == "2" ]] && mode="ro"

    # --- NTFS safety warning when mounting read-write ---
    if [[ "$fstype" == ntfs* && "$mode" == "rw" ]]; then
        echo ""
        warn "NTFS detected. Mounting read-write can corrupt the filesystem if"
        warn "Windows is hibernated or 'Fast Startup' is enabled (dirty bit)."
        echo "    [1] Mount read-only (safer)"
        echo "    [2] Mount read-write anyway"
        echo "    [3] Cancel"
        echo -n "  Choice [1-3] (Enter = read-only): "
        read -r ans
        case "$ans" in
            2) mode="rw" ;;
            3) info "Cancelled."; return ;;
            *) mode="ro" ;;
        esac
    fi

    # --- Mount location ---
    echo ""
    if [[ "$BACKEND" == "udisks" ]]; then
        echo "  Location:  [1] Default (udisksctl → /run/media)   [2] Custom path (sudo mount)"
    else
        echo "  Location:  [1] Default (/mnt/<label>)   [2] Custom path (sudo mount)"
    fi
    echo -n "  Choice [1-2] (Enter = default): "
    read -r ans
    if [[ "$ans" == "2" ]]; then
        location="custom"
        local suggested="/mnt/${label:-$(basename "$dev")}"
        suggested="${suggested// /_}"
        echo -n "  Mount point [Enter = ${suggested}]: "
        read -r custom
        [[ -z "$custom" ]] && custom="$suggested"
    fi

    mount_device "$dev" "$label" "$mode" "$location" "$custom"
}

# --- Unmount action ---
do_unmount() {
    collect_unmountable
    if [[ ${#CAND_PATH[@]} -eq 0 ]]; then
        info "No unmountable devices (system mounts are protected)."
        return
    fi

    section "Unmount a device"
    local i
    for i in "${!CAND_PATH[@]}"; do
        printf "  [%d] %-16s mounted at %s\n" \
            $((i + 1)) "${CAND_PATH[i]}" "${CAND_MP[i]}"
    done

    echo ""
    echo -n "  Select device to unmount [1-${#CAND_PATH[@]}] (Enter to cancel): "
    read -r choice
    [[ -z "$choice" ]] && { info "Cancelled."; return; }

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#CAND_PATH[@]} )); then
        warn "Invalid selection."
        return
    fi

    local idx=$((choice - 1))
    confirm "Unmount ${CAND_PATH[idx]} (${CAND_MP[idx]})?" || { info "Cancelled."; return; }
    unmount_device "${CAND_PATH[idx]}"
}

# ============================================================
# Persistent mounts (/etc/fstab)
# ============================================================

FSTAB="/etc/fstab"

# --- True if a spec/fstype is a virtual (non-block-device) filesystem ---
is_virtual_source() {
    case "$1" in
        tmpfs|proc|sysfs|devpts|devtmpfs|run|none|cgroup|cgroup2|mqueue|\
        hugetlbfs|debugfs|tracefs|securityfs|configfs|bpf|pstore|efivarfs|\
        ramfs|overlay|fusectl|binfmt_misc|autofs) return 0 ;;
        *) return 1 ;;
    esac
}

# --- Resolve an fstab spec to a currently-present device/path (or empty) ---
resolve_spec() {
    case "$1" in
        UUID=*)     lsblk -rno PATH,UUID     2>/dev/null | awk -v v="${1#UUID=}"     'tolower($2)==tolower(v){print $1; exit}' ;;
        PARTUUID=*) lsblk -rno PATH,PARTUUID 2>/dev/null | awk -v v="${1#PARTUUID=}" 'tolower($2)==tolower(v){print $1; exit}' ;;
        LABEL=*)    lsblk -rno PATH,LABEL     2>/dev/null | awk -v v="${1#LABEL=}"    '$2==v{print $1; exit}' ;;
        /*)         [[ -e "$1" ]] && echo "$1" ;;          # /dev/... or /swapfile
    esac
}

# --- True if a UUID already has an (uncommented) fstab entry ---
fstab_has_uuid() {
    grep -iqE "^[[:space:]]*UUID=$1([[:space:]]|=|$)" "$FSTAB" 2>/dev/null
}

# --- True if a mount point is already used by an fstab entry ---
fstab_mountpoint_used() {
    awk -v mp="$1" '$1!~/^#/ && $1!="" && $2==mp{f=1} END{exit !f}' "$FSTAB" 2>/dev/null
}

# --- Sensible default mount options per filesystem ---
# Always includes nofail + a device timeout so a missing/secondary disk
# never blocks boot. uid/gid/umask only for non-POSIX-permission filesystems.
default_fstab_opts() {
    local fstype="$1" mode="$2" rw="rw"
    [[ "$mode" == "ro" ]] && rw="ro"
    case "$fstype" in
        ntfs|ntfs3|vfat|exfat)
            echo "${rw},nofail,x-systemd.device-timeout=10s,uid=$(id -u),gid=$(id -g),umask=022" ;;
        *)
            echo "${rw},nofail,x-systemd.device-timeout=10s" ;;
    esac
}

# --- Collect devices eligible to be made persistent ---
# Filesystem present, has a UUID, not swap/LUKS, not already in fstab.
collect_persistable() {
    CAND_PATH=(); CAND_FSTYPE=(); CAND_LABEL=(); CAND_SIZE=(); CAND_UUID=()
    local line path type fstype uuid
    for line in "${LINES[@]}"; do
        path=$(lsblk_val "$line" PATH)
        type=$(lsblk_val "$line" TYPE)
        is_real_block "$path" "$type" || continue
        fstype=$(lsblk_val "$line" FSTYPE)
        uuid=$(lsblk_val "$line" UUID)
        [[ -z "$fstype" || -z "$uuid" ]] && continue
        [[ "$fstype" == "swap" || "$fstype" == "crypto_LUKS" ]] && continue
        fstab_has_uuid "$uuid" && continue
        CAND_PATH+=("$path")
        CAND_FSTYPE+=("$fstype")
        CAND_LABEL+=("$(lsblk_val "$line" LABEL)")
        CAND_SIZE+=("$(lsblk_val "$line" SIZE)")
        CAND_UUID+=("$uuid")
    done
}

# --- Review action: list current fstab entries with live status ---
show_fstab() {
    section "Persistent mounts (${FSTAB})"

    if [[ ! -r "$FSTAB" ]]; then
        warn "Cannot read ${FSTAB}."
        return
    fi

    printf "  %-16s %-14s %-16s %-7s %-12s %s\n" \
        "DEVICE" "LABEL" "MOUNTPOINT" "TYPE" "STATUS" "OPTIONS"
    printf "  %s\n" "$(printf '%.0s─' {1..96})"

    local spec mp fstype opts dump pass resolved status scolor dev_disp lbl
    local found=0 skipped=0
    while read -r spec mp fstype opts dump pass; do
        [[ -z "$spec" || "$spec" == \#* ]] && continue
        # Virtual filesystems (tmpfs, proc, …) aren't disks — skip them.
        if is_virtual_source "$spec" || is_virtual_source "$fstype"; then
            (( skipped++ ))
            continue
        fi
        found=1

        resolved=$(resolve_spec "$spec")
        if [[ "$fstype" == "swap" ]]; then
            [[ -n "$resolved" ]] && { status="swap"; scolor="$CYAN"; } \
                                 || { status="MISSING"; scolor="$RED"; }
        elif [[ -z "$resolved" ]]; then
            status="MISSING"; scolor="$RED"
        elif findmnt -rn --mountpoint "$mp" &>/dev/null; then
            status="mounted"; scolor="$GREEN"
        else
            status="not mounted"; scolor="$YELLOW"
        fi

        # Prefer the resolved device path; fall back to the raw spec when MISSING.
        dev_disp="${resolved:-$spec}"
        (( ${#dev_disp} > 16 )) && dev_disp="${dev_disp:0:13}..."

        # Label: from the live device, or from a LABEL= spec when MISSING.
        lbl=""
        if [[ -n "$resolved" ]]; then
            lbl=$(lsblk -rno LABEL "$resolved" 2>/dev/null | head -1)
        elif [[ "$spec" == LABEL=* ]]; then
            lbl="${spec#LABEL=}"
        fi
        [[ -z "$lbl" ]] && lbl="-"
        (( ${#lbl} > 14 )) && lbl="${lbl:0:11}..."

        printf "  %-16s %-14s %-16s %-7s ${scolor}%-12s${RESET} %s\n" \
            "$dev_disp" "$lbl" "$mp" "${fstype:--}" "$status" "${opts:--}"
    done < "$FSTAB"

    (( found == 0 )) && info "No disk entries found in ${FSTAB}."
    echo ""
    info "${RED}MISSING${RESET} = the device for this entry is not present right now (stale or disconnected)."
    (( skipped > 0 )) && info "${skipped} virtual entr$( (( skipped == 1 )) && echo y || echo ies ) (tmpfs, proc, …) hidden."
}

# --- Add action: append a persistent mount to fstab (with safeguards) ---
add_fstab() {
    collect_persistable
    if [[ ${#CAND_PATH[@]} -eq 0 ]]; then
        info "No eligible devices (all already in fstab, or without a filesystem/UUID)."
        return
    fi

    section "Add persistent mount (${FSTAB})"
    local i
    for i in "${!CAND_PATH[@]}"; do
        printf "  [%d] %-16s %-8s %-11s %s\n" \
            $((i + 1)) "${CAND_PATH[i]}" "${CAND_SIZE[i]}" \
            "${CAND_FSTYPE[i]}" "${CAND_LABEL[i]:-(no label)}"
    done

    echo ""
    echo -n "  Select device to make persistent [1-${#CAND_PATH[@]}] (Enter to cancel): "
    read -r choice
    [[ -z "$choice" ]] && { info "Cancelled."; return; }
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#CAND_PATH[@]} )); then
        warn "Invalid selection."
        return
    fi

    local idx=$((choice - 1))
    local dev="${CAND_PATH[idx]}" fstype="${CAND_FSTYPE[idx]}"
    local label="${CAND_LABEL[idx]}" uuid="${CAND_UUID[idx]}"
    local mode="rw" mp ans

    # --- Mount point ---
    local suggested="/mnt/${label:-$(basename "$dev")}"
    suggested="${suggested// /_}"
    echo ""
    echo -n "  Mount point [Enter = ${suggested}]: "
    read -r mp
    [[ -z "$mp" ]] && mp="$suggested"
    if [[ "$mp" != /* ]]; then
        warn "Mount point must be an absolute path."
        return
    fi
    if fstab_mountpoint_used "$mp"; then
        warn "${FSTAB} already has an entry for ${mp}. Aborting."
        return
    fi

    # --- Read/write vs read-only ---
    echo ""
    echo "  Mount mode:  [1] Read-write (default)   [2] Read-only"
    echo -n "  Choice [1-2] (Enter = read-write): "
    read -r ans
    [[ "$ans" == "2" ]] && mode="ro"

    # --- NTFS safety warning when persisting read-write ---
    if [[ "$fstype" == ntfs* && "$mode" == "rw" ]]; then
        echo ""
        warn "NTFS detected. A persistent read-write mount can corrupt the"
        warn "filesystem if Windows hibernates or uses 'Fast Startup'."
        echo "    [1] Make it read-only (safer)"
        echo "    [2] Read-write anyway"
        echo "    [3] Cancel"
        echo -n "  Choice [1-3] (Enter = read-only): "
        read -r ans
        case "$ans" in
            2) mode="rw" ;;
            3) info "Cancelled."; return ;;
            *) mode="ro" ;;
        esac
    fi

    # --- Build and preview the entry ---
    local opts entry
    opts=$(default_fstab_opts "$fstype" "$mode")
    entry="UUID=${uuid}  ${mp}  ${fstype}  ${opts}  0  0"

    section "Proposed ${FSTAB} entry"
    echo "  ${BOLD}${entry}${RESET}"
    echo ""
    info "Uses UUID (stable across reboots) and ${BOLD}nofail${RESET} (a missing disk won't block boot)."
    echo ""
    confirm_critical "Append this line to ${FSTAB}?" || { info "Cancelled."; return; }

    # --- Backup, then append ---
    local backup="${FSTAB}.bak.$(date +%Y%m%d-%H%M%S)"
    if sudo cp -a "$FSTAB" "$backup"; then
        ok "Backup saved: ${backup}"
    else
        error "Could not back up ${FSTAB}. Aborting."
        return
    fi

    if echo "$entry" | sudo tee -a "$FSTAB" >/dev/null; then
        ok "Entry appended to ${FSTAB}."
    else
        error "Failed to write ${FSTAB}."
        return
    fi

    # --- Create the mount point so the entry is valid at boot ---
    # (findmnt --verify flags a missing target, and the mount can't happen
    #  at boot without it — /mnt lives on the root fs, so it persists.)
    if sudo mkdir -p "$mp"; then
        ok "Mount point ready: ${mp}"
    else
        warn "Could not create ${mp} — create it before rebooting."
    fi

    # --- Reload systemd first, then validate (avoids stale-fstab warning) ---
    sudo systemctl daemon-reload 2>/dev/null
    info "Validating with findmnt --verify…"
    local vout vrc
    vout=$(findmnt --verify 2>&1); vrc=$?
    if (( vrc == 0 )); then
        ok "fstab verification passed."
    else
        warn "fstab verification reported issues:"
        echo "$vout" | sed 's/^/    /'
        warn "If this looks wrong, restore with: ${BOLD}sudo cp ${backup} ${FSTAB}${RESET}"
    fi

    # --- Offer to mount it now ---
    if confirm "Mount ${mp} now?"; then
        if sudo mount "$mp"; then
            ok "Mounted at ${mp}."
        else
            error "Mount failed — review the entry. Backup is at ${backup}."
        fi
    fi
}

# --- Collect fstab entries that may be removed ---
# Disk entries only; virtual filesystems and critical system mounts are
# excluded. Records the exact source line number for a precise deletion.
collect_fstab_removable() {
    REM_NUM=(); REM_DEV=(); REM_LABEL=(); REM_MP=(); REM_TYPE=(); REM_RAW=()
    local n=0 raw spec mp fstype opts dump pass resolved lbl
    while IFS= read -r raw || [[ -n "$raw" ]]; do
        (( n++ ))
        [[ -z "$raw" || "$raw" == \#* ]] && continue
        read -r spec mp fstype opts dump pass <<< "$raw"
        [[ -z "$spec" ]] && continue
        if is_virtual_source "$spec" || is_virtual_source "$fstype"; then continue; fi
        if is_protected_mount "$mp"; then continue; fi

        resolved=$(resolve_spec "$spec")
        lbl=""
        if [[ -n "$resolved" ]]; then
            lbl=$(lsblk -rno LABEL "$resolved" 2>/dev/null | head -1)
        elif [[ "$spec" == LABEL=* ]]; then
            lbl="${spec#LABEL=}"
        fi
        [[ -z "$lbl" ]] && lbl="-"

        REM_NUM+=("$n")
        REM_RAW+=("$raw")
        REM_DEV+=("${resolved:-$spec}")
        REM_LABEL+=("$lbl")
        REM_MP+=("$mp")
        REM_TYPE+=("$fstype")
    done < "$FSTAB"
}

# --- Remove action: delete a persistent mount from fstab (with safeguards) ---
remove_fstab() {
    collect_fstab_removable
    if [[ ${#REM_NUM[@]} -eq 0 ]]; then
        info "No removable disk entries in ${FSTAB} (system mounts are protected)."
        return
    fi

    section "Remove persistent mount (${FSTAB})"
    local i dev_disp
    for i in "${!REM_NUM[@]}"; do
        dev_disp="${REM_DEV[i]}"
        (( ${#dev_disp} > 16 )) && dev_disp="${dev_disp:0:13}..."
        printf "  [%d] %-16s %-14s %-16s %s\n" \
            $((i + 1)) "$dev_disp" "${REM_LABEL[i]}" "${REM_MP[i]}" "${REM_TYPE[i]}"
    done

    echo ""
    echo -n "  Select entry to remove [1-${#REM_NUM[@]}] (Enter to cancel): "
    read -r choice
    [[ -z "$choice" ]] && { info "Cancelled."; return; }
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#REM_NUM[@]} )); then
        warn "Invalid selection."
        return
    fi

    local idx=$((choice - 1))
    local mp="${REM_MP[idx]}" lineno="${REM_NUM[idx]}"

    section "Entry to remove"
    echo "  ${BOLD}${REM_RAW[idx]}${RESET}"
    echo ""
    info "This only edits ${FSTAB} (stops mounting at boot); current mounts stay until you unmount."
    echo ""
    confirm_critical "Remove this entry from ${FSTAB}?" || { info "Cancelled."; return; }

    # --- Backup, then delete the exact line ---
    local backup="${FSTAB}.bak.$(date +%Y%m%d-%H%M%S)"
    if sudo cp -a "$FSTAB" "$backup"; then
        ok "Backup saved: ${backup}"
    else
        error "Could not back up ${FSTAB}. Aborting."
        return
    fi

    if sudo sed -i "${lineno}d" "$FSTAB"; then
        ok "Entry removed from ${FSTAB}."
    else
        error "Failed to edit ${FSTAB}. Restore with: sudo cp ${backup} ${FSTAB}"
        return
    fi

    # --- Validate + reload ---
    info "Validating with findmnt --verify…"
    local vout vrc
    vout=$(findmnt --verify 2>&1); vrc=$?
    if (( vrc == 0 )); then
        ok "fstab verification passed."
    else
        warn "fstab verification reported issues:"
        echo "$vout" | sed 's/^/    /'
        warn "If this looks wrong, restore with: ${BOLD}sudo cp ${backup} ${FSTAB}${RESET}"
    fi
    sudo systemctl daemon-reload 2>/dev/null

    # --- Offer to unmount it now if still mounted ---
    if findmnt -rn --mountpoint "$mp" &>/dev/null; then
        if confirm "It is still mounted at ${mp}. Unmount it now?"; then
            if sudo umount "$mp"; then
                ok "Unmounted ${mp}."
            else
                error "Unmount failed — device may be busy."
            fi
        fi
    fi
}

# --- Main menu loop ---
main() {
    require_cmds lsblk findmnt
    detect_backend

    section "Mount Manager"
    if [[ "$BACKEND" == "udisks" ]]; then
        info "Backend: udisksctl (no sudo, mounts under /run/media)"
    else
        info "Backend: mount + sudo (mounts under /mnt)"
    fi

    while true; do
        load_devices
        show_devices

        echo ""
        echo "  [1] Mount a device"
        echo "  [2] Unmount a device"
        echo "  [3] Add persistent mount (fstab)"
        echo "  [4] Remove persistent mount (fstab)"
        echo "  [5] Review persistent mounts (fstab)"
        echo "  [6] Refresh"
        echo "  [7] Exit"
        echo ""
        echo -n "  Option [1-7]: "
        read -r opt

        case "$opt" in
            1) do_mount ;;
            2) do_unmount ;;
            3) add_fstab ;;
            4) remove_fstab ;;
            5) show_fstab ;;
            6) : ;;
            7|q|Q) info "Bye."; break ;;
            *) warn "Invalid option." ;;
        esac
        echo ""
    done
}

main "$@"
