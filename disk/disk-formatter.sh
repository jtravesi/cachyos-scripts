#!/usr/bin/env bash
# ============================================================
# disk-formatter.sh
# Description : Interactive tool to format devices (create a
#               filesystem), change filesystem labels, and
#               partition disks (quick single-partition layout
#               or hand off to cfdisk). DESTRUCTIVE — every
#               operation is gated behind a type-to-confirm
#               prompt, and the disk hosting / and /boot (plus
#               any mounted/swap device) is fully off-limits.
# Dependencies: lsblk, findmnt, wipefs; parted/cfdisk and the
#               relevant mkfs.* / *label tools (offered on demand)
# Compatibility: Any Linux
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

declare -A SYSTEM_DISK    # set of base disk names that must never be touched
declare -a LINES          # cached `lsblk -P` lines
FS_CHOICE=""              # set by choose_filesystem

# --- Extract a value from one `lsblk -P` line (anchored to avoid TYPE⊂FSTYPE) ---
lsblk_val() {
    sed -n "s/.*\\(^\\|[[:space:]]\\)${2}=\"\\([^\"]*\\)\".*/\\2/p" <<< "$1"
}

load_devices() {
    mapfile -t LINES < <(lsblk -P -o PATH,TYPE,FSTYPE,LABEL,SIZE,MOUNTPOINT,RM 2>/dev/null)
}

# --- Base physical disk for any device (climbs partitions, mappers, LVM) ---
# Strips any btrfs subvolume suffix (e.g. /dev/sdb2[/@home]) first.
disk_of() {
    lsblk -rsno NAME "${1%%\[*}" 2>/dev/null | tail -1
}

is_real_block() {
    local path="$1" type="$2"
    [[ "$type" == "loop" ]] && return 1
    [[ "$path" == /dev/loop* || "$path" == /dev/zram* || "$path" == /dev/sr* ]] && return 1
    return 0
}

# --- Build the set of off-limits disks (root/boot/swap hosts) ---
build_system_disks() {
    SYSTEM_DISK=()
    local src mp disk

    while read -r src mp; do
        case "$mp" in
            /|/boot|/boot/efi|/efi|/usr|/var|/home) ;;
            *) continue ;;
        esac
        disk=$(disk_of "$src")
        [[ -n "$disk" ]] && SYSTEM_DISK["$disk"]=1
    done < <(findmnt -rno SOURCE,TARGET 2>/dev/null)

    while read -r src; do
        [[ -z "$src" ]] && continue
        disk=$(disk_of "$src")
        [[ -n "$disk" ]] && SYSTEM_DISK["$disk"]=1
    done < <(swapon --show=NAME --noheadings 2>/dev/null)
}

is_system_dev() {
    local d; d=$(disk_of "$1")
    [[ -n "$d" && -n "${SYSTEM_DISK[$d]:-}" ]]
}

# --- True if the device or any of its children is mounted ---
device_or_children_mounted() {
    lsblk -rno MOUNTPOINT "$1" 2>/dev/null | grep -q '[^[:space:]]'
}

# --- Make lsblk / file managers see a new filesystem or label immediately ---
# Writing a label with *label tools does not emit a udev event, so lsblk's
# cached LABEL stays stale until we trigger a re-read of the device.
refresh_dev() {
    sudo udevadm trigger --settle --name-match="$1" 2>/dev/null
    sudo udevadm settle 2>/dev/null
}

# --- Ensure an external tool is present; offer to install it ---
ensure_tool() {
    local tool="$1" pkg="$2"
    command -v "$tool" &>/dev/null && return 0

    warn "Required tool '${tool}' is not installed (package: ${pkg})."
    confirm "Install ${pkg} now?" || return 1

    detect_pkg_manager
    if [[ "$PKG_MANAGER" == "pacman" ]]; then
        sudo pacman -S --needed "$pkg"
    else
        "$PKG_MANAGER" -S --needed "$pkg"
    fi
    command -v "$tool" &>/dev/null
}

# --- Type-to-confirm gate for a destructive operation ---
confirm_destruction() {
    local target="$1" name="${1#/dev/}" typed
    echo ""
    warn "ALL DATA on ${BOLD}${target}${RESET}${YELLOW} will be PERMANENTLY DESTROYED."
    echo -en "    ${RED}Type '${BOLD}${name}${RESET}${RED}' to confirm (anything else cancels): ${RESET}"
    read -r typed
    [[ "$typed" == "$name" ]]
}

# ============================================================
# Filesystem registry
# ============================================================

# Present the filesystem menu (with guidance) and set FS_CHOICE.
choose_filesystem() {
    section "Select filesystem"
    cat <<'EOF'
  [1] ext4   Linux native (journaling, POSIX permissions). Best for Linux-only
             disks. Not readable by Windows/macOS without extra software.
  [2] exfat  Cross-platform (Windows/macOS/Linux), no 4 GB file-size limit.
             Ideal for large/shared USB drives. No journaling or POSIX perms.
  [3] fat32  Maximum compatibility (BIOS, cameras, TVs, consoles, boot media).
             Limits: 4 GB max file size, ~2 TB max volume.
  [4] ntfs   Windows filesystem with large-file support; good for Windows
             sharing. Permissions are emulated on Linux and it is slower.
  [5] btrfs  Modern Linux copy-on-write: snapshots, checksums, compression.
             Linux-only; more overhead on small/USB media.
  [6] xfs    High-performance Linux fs for big files/volumes.
             Linux-only; a volume cannot be shrunk after creation.
EOF
    echo ""
    echo -n "  Choose filesystem [1-6] (Enter to cancel): "
    local c; read -r c
    case "$c" in
        1) FS_CHOICE="ext4"  ;;
        2) FS_CHOICE="exfat" ;;
        3) FS_CHOICE="fat32" ;;
        4) FS_CHOICE="ntfs"  ;;
        5) FS_CHOICE="btrfs" ;;
        6) FS_CHOICE="xfs"   ;;
        *) FS_CHOICE=""      ;;
    esac
    [[ -n "$FS_CHOICE" ]]
}

# Create a filesystem on a device (no label; label is set separately).
fs_make() {
    local key="$1" dev="$2"
    case "$key" in
        ext4)  ensure_tool mkfs.ext4  e2fsprogs  || return 1; sudo mkfs.ext4  -F   "$dev" ;;
        exfat) ensure_tool mkfs.exfat exfatprogs || return 1; sudo mkfs.exfat      "$dev" ;;
        fat32) ensure_tool mkfs.vfat  dosfstools || return 1; sudo mkfs.vfat  -F 32 "$dev" ;;
        ntfs)  ensure_tool mkfs.ntfs  ntfs-3g    || return 1; sudo mkfs.ntfs  -Q -F "$dev" ;;
        btrfs) ensure_tool mkfs.btrfs btrfs-progs|| return 1; sudo mkfs.btrfs -f   "$dev" ;;
        xfs)   ensure_tool mkfs.xfs   xfsprogs   || return 1; sudo mkfs.xfs   -f   "$dev" ;;
        *) error "Unknown filesystem: ${key}"; return 1 ;;
    esac
}

# Set the label of an existing filesystem (accepts mkfs keys and lsblk fstypes).
fs_label() {
    local key="$1" dev="$2" label="$3"
    case "$key" in
        ext2|ext3|ext4) ensure_tool e2label   e2fsprogs   || return 1; sudo e2label   "$dev" "$label" ;;
        exfat)          ensure_tool exfatlabel exfatprogs  || return 1; sudo exfatlabel "$dev" "$label" ;;
        vfat|fat32|fat)
            ensure_tool fatlabel dosfstools || return 1
            # FAT volume labels are uppercase by convention; lowercase ones
            # trigger a warning and may not display correctly elsewhere.
            local up="${label^^}"
            [[ "$up" != "$label" ]] && info "FAT labels are uppercase — using '${up}'."
            sudo fatlabel "$dev" "$up" ;;
        ntfs)           ensure_tool ntfslabel  ntfs-3g     || return 1; sudo ntfslabel "$dev" "$label" ;;
        btrfs)          ensure_tool btrfs      btrfs-progs || return 1; sudo btrfs filesystem label "$dev" "$label" ;;
        xfs)            ensure_tool xfs_admin  xfsprogs    || return 1; sudo xfs_admin -L "$label" "$dev" ;;
        *) error "Labeling not supported for filesystem: ${key}"; return 1 ;;
    esac
}

# Validate a label length against per-filesystem limits.
validate_label() {
    local key="$1" label="$2" max
    case "$key" in
        fat32|vfat|fat)  max=11  ;;
        xfs)             max=12  ;;
        exfat)           max=15  ;;
        ext2|ext3|ext4)  max=16  ;;
        ntfs)            max=32  ;;
        *)               max=255 ;;
    esac
    if (( ${#label} > max )); then
        warn "Label too long for ${key}: ${#label} chars (max ${max})."
        return 1
    fi
    return 0
}

# ============================================================
# Shared selection helpers
# ============================================================

# Print the device tree for a target (so the user sees exactly what's at stake).
show_target() {
    section "Target: $1"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT "$1" 2>/dev/null | sed 's/^/  /'
}

# --- Device overview at the top of the menu ---
show_devices() {
    section "Block devices"
    printf "  %-16s %-7s %-11s %-15s %-12s %s\n" \
        "DEVICE" "SIZE" "FSTYPE" "LABEL" "MOUNTPOINT" "NOTES"
    printf "  %s\n" "$(printf '%.0s─' {1..86})"

    local line path type fstype label size mp rm notes color
    for line in "${LINES[@]}"; do
        path=$(lsblk_val "$line" PATH)
        type=$(lsblk_val "$line" TYPE)
        is_real_block "$path" "$type" || continue

        fstype=$(lsblk_val "$line" FSTYPE)
        label=$(lsblk_val "$line" LABEL)
        size=$(lsblk_val "$line" SIZE)
        mp=$(lsblk_val "$line" MOUNTPOINT)
        rm=$(lsblk_val "$line" RM)
        (( ${#label} > 15 )) && label="${label:0:12}..."

        notes=""; color="$RESET"
        if is_system_dev "$path"; then
            notes="SYSTEM (protected)"; color="$RED"
        else
            [[ "$rm" == "1" ]] && notes="removable"
            [[ -n "$mp" ]] && notes="${notes:+$notes, }mounted"
        fi

        printf "  ${color}%-16s %-7s %-11s %-15s %-12s %s${RESET}\n" \
            "$path" "${size:--}" "${fstype:--}" "${label:--}" "${mp:--}" "$notes"
    done
}

# ============================================================
# Actions
# ============================================================

# --- Format: create a fresh filesystem on a partition/device ---
do_format() {
    local -a P_PATH P_DESC
    local line path type fstype label size mp
    for line in "${LINES[@]}"; do
        path=$(lsblk_val "$line" PATH)
        type=$(lsblk_val "$line" TYPE)
        is_real_block "$path" "$type" || continue
        is_system_dev "$path" && continue
        device_or_children_mounted "$path" && continue
        [[ "$type" == "part" || "$type" == "disk" || "$type" == "crypt" || "$type" == "lvm" ]] || continue

        fstype=$(lsblk_val "$line" FSTYPE)
        label=$(lsblk_val "$line" LABEL)
        size=$(lsblk_val "$line" SIZE)
        local kind="$type"
        [[ "$type" == "disk" ]] && kind="disk (whole)"
        P_PATH+=("$path")
        P_DESC+=("$(printf '%-16s %-13s %-8s %-11s %s' "$path" "$kind" "$size" "${fstype:-empty}" "${label:-}")")
    done

    if [[ ${#P_PATH[@]} -eq 0 ]]; then
        info "No formattable devices (must be unmounted and not on the system disk)."
        return
    fi

    section "Format a device"
    local i
    for i in "${!P_PATH[@]}"; do
        printf "  %-4s %s\n" "[$((i + 1))]" "${P_DESC[i]}"
    done
    echo ""
    echo -n "  Select device to format [1-${#P_PATH[@]}] (Enter to cancel): "
    local choice; read -r choice
    [[ -z "$choice" ]] && { info "Cancelled."; return; }
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#P_PATH[@]} )); then
        warn "Invalid selection."; return
    fi

    local dev="${P_PATH[$((choice - 1))]}"
    # Re-check safety right before acting
    is_system_dev "$dev" && { error "Refusing: ${dev} is part of the system disk."; return; }
    device_or_children_mounted "$dev" && { error "Refusing: ${dev} is mounted. Unmount it first."; return; }

    show_target "$dev"

    choose_filesystem || { info "Cancelled."; return; }

    local label
    echo ""
    echo -n "  Volume label (optional, Enter to skip): "
    read -r label
    [[ -n "$label" ]] && { validate_label "$FS_CHOICE" "$label" || return; }

    section "Confirm format"
    warn "This will create a fresh ${BOLD}${FS_CHOICE}${RESET}${YELLOW} filesystem on ${BOLD}${dev}${RESET}."
    confirm_destruction "$dev" || { info "Cancelled."; return; }

    info "Wiping old signatures…"
    sudo wipefs -a "$dev" >/dev/null
    info "Creating ${FS_CHOICE} filesystem on ${dev}…"
    if fs_make "$FS_CHOICE" "$dev"; then
        [[ -n "$label" ]] && fs_label "$FS_CHOICE" "$dev" "$label"
        refresh_dev "$dev"
        ok "Done. ${dev} is now ${FS_CHOICE}${label:+ labelled '${label}'}."
    else
        error "Format failed — see output above."
    fi
}

# --- Change the label of an existing filesystem ---
do_label() {
    local -a L_PATH L_FSTYPE L_DESC
    local line path type fstype label size mp
    for line in "${LINES[@]}"; do
        path=$(lsblk_val "$line" PATH)
        type=$(lsblk_val "$line" TYPE)
        is_real_block "$path" "$type" || continue
        is_system_dev "$path" && continue
        device_or_children_mounted "$path" && continue
        fstype=$(lsblk_val "$line" FSTYPE)
        [[ -z "$fstype" || "$fstype" == "crypto_LUKS" || "$fstype" == "swap" ]] && continue

        label=$(lsblk_val "$line" LABEL)
        size=$(lsblk_val "$line" SIZE)
        L_PATH+=("$path"); L_FSTYPE+=("$fstype")
        L_DESC+=("$(printf '%-16s %-8s %-8s %s' "$path" "$size" "$fstype" "${label:-(no label)}")")
    done

    if [[ ${#L_PATH[@]} -eq 0 ]]; then
        info "No eligible filesystems (must be unmounted and not on the system disk)."
        return
    fi

    section "Change a filesystem label"
    local i
    for i in "${!L_PATH[@]}"; do
        printf "  [%d] %s\n" $((i + 1)) "${L_DESC[i]}"
    done
    echo ""
    echo -n "  Select filesystem [1-${#L_PATH[@]}] (Enter to cancel): "
    local choice; read -r choice
    [[ -z "$choice" ]] && { info "Cancelled."; return; }
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#L_PATH[@]} )); then
        warn "Invalid selection."; return
    fi

    local idx=$((choice - 1))
    local dev="${L_PATH[idx]}" fstype="${L_FSTYPE[idx]}"
    echo -n "  New label: "
    local label; read -r label
    [[ -z "$label" ]] && { info "Cancelled."; return; }
    validate_label "$fstype" "$label" || return

    confirm "Set label of ${dev} (${fstype}) to '${label}'?" || { info "Cancelled."; return; }
    if fs_label "$fstype" "$dev" "$label"; then
        refresh_dev "$dev"
        ok "Label of ${dev} set to '${label}'."
    else
        error "Could not set label."
    fi
}

# --- Quick layout: wipe disk → single full-disk partition → format ---
quick_partition() {
    local disk="$1"

    echo ""
    echo "  Partition table:"
    echo "    [1] GPT       Modern standard. Required for >2 TB and UEFI. (default)"
    echo "    [2] MBR/msdos Maximum compatibility (old BIOS/devices); ≤2 TB, ≤4 partitions."
    echo -n "  Choose [1-2] (Enter = GPT): "
    local t table; read -r t
    [[ "$t" == "2" ]] && table="msdos" || table="gpt"

    choose_filesystem || { info "Cancelled."; return; }

    local label
    echo ""
    echo -n "  Volume label (optional, Enter to skip): "
    read -r label
    [[ -n "$label" ]] && { validate_label "$FS_CHOICE" "$label" || return; }

    section "Confirm partition + format"
    warn "This will ERASE the ENTIRE disk ${BOLD}${disk}${RESET}${YELLOW} — partition table and all partitions —"
    warn "then create one ${table^^} partition formatted as ${BOLD}${FS_CHOICE}${RESET}."
    confirm_destruction "$disk" || { info "Cancelled."; return; }

    ensure_tool parted parted || return

    info "Wiping ${disk}…"
    sudo wipefs -a "$disk" >/dev/null
    info "Creating ${table} table and a single partition…"
    if ! sudo parted -s "$disk" mklabel "$table" mkpart primary 0% 100%; then
        error "Partitioning failed."; return
    fi
    sudo partprobe "$disk" 2>/dev/null
    sudo udevadm settle 2>/dev/null
    sleep 1

    local part
    part=$(lsblk -rno PATH,TYPE "$disk" 2>/dev/null | awk '$2=="part"{print $1; exit}')
    if [[ -z "$part" ]]; then
        error "Could not detect the new partition. Re-plug or check 'lsblk ${disk}'."
        return
    fi

    info "Formatting ${part} as ${FS_CHOICE}…"
    sudo wipefs -a "$part" >/dev/null
    if fs_make "$FS_CHOICE" "$part"; then
        [[ -n "$label" ]] && fs_label "$FS_CHOICE" "$part" "$label"
        refresh_dev "$part"
        ok "${disk} partitioned (${table}) and ${part} formatted as ${FS_CHOICE}."
    else
        error "Format of ${part} failed."
    fi
}

# --- Partition a whole disk (quick layout or cfdisk) ---
do_partition() {
    local -a D_PATH D_DESC
    local line path type size model
    for line in "${LINES[@]}"; do
        path=$(lsblk_val "$line" PATH)
        type=$(lsblk_val "$line" TYPE)
        [[ "$type" == "disk" ]] || continue
        is_real_block "$path" "$type" || continue
        is_system_dev "$path" && continue
        device_or_children_mounted "$path" && continue

        size=$(lsblk_val "$line" SIZE)
        model=$(lsblk -dno MODEL "$path" 2>/dev/null | xargs)
        D_PATH+=("$path")
        D_DESC+=("$(printf '%-14s %-8s %s' "$path" "$size" "${model:-}")")
    done

    if [[ ${#D_PATH[@]} -eq 0 ]]; then
        info "No partitionable disks (must have no mounted partitions and not be the system disk)."
        return
    fi

    section "Partition a disk"
    local i
    for i in "${!D_PATH[@]}"; do
        printf "  [%d] %s\n" $((i + 1)) "${D_DESC[i]}"
    done
    echo ""
    echo -n "  Select disk [1-${#D_PATH[@]}] (Enter to cancel): "
    local choice; read -r choice
    [[ -z "$choice" ]] && { info "Cancelled."; return; }
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#D_PATH[@]} )); then
        warn "Invalid selection."; return
    fi

    local disk="${D_PATH[$((choice - 1))]}"
    is_system_dev "$disk" && { error "Refusing: ${disk} is the system disk."; return; }
    device_or_children_mounted "$disk" && { error "Refusing: ${disk} has mounted partitions."; return; }

    show_target "$disk"

    echo ""
    echo "  [1] Quick   — wipe disk + one partition spanning it + format"
    echo "  [2] cfdisk  — open the interactive partition editor (manual)"
    echo "  [3] Cancel"
    echo -n "  Choose [1-3]: "
    local mode; read -r mode
    case "$mode" in
        1) quick_partition "$disk" ;;
        2)
            ensure_tool cfdisk util-linux || return
            sudo cfdisk "$disk"
            sudo partprobe "$disk" 2>/dev/null
            sudo udevadm settle 2>/dev/null
            ok "cfdisk closed. Format any new partitions with option [1] of the main menu."
            ;;
        *) info "Cancelled." ;;
    esac
}

# ============================================================
# Main
# ============================================================
main() {
    require_cmds lsblk findmnt wipefs

    # Refuse to run if we cannot identify the root device — operating
    # without knowing the system disk would be unsafe.
    [[ -n "$(findmnt -rno SOURCE / 2>/dev/null)" ]] \
        || fatal "Could not determine the root device; refusing to run."

    section "Disk Formatter"
    warn "This tool can PERMANENTLY ERASE data. The system disk is protected,"
    warn "but double-check every selection before confirming."

    while true; do
        build_system_disks
        load_devices
        show_devices

        echo ""
        echo "  [1] Format a device (create filesystem)"
        echo "  [2] Change a filesystem label"
        echo "  [3] Partition a disk (quick or cfdisk)"
        echo "  [4] Refresh"
        echo "  [5] Exit"
        echo ""
        echo -n "  Option [1-5]: "
        local opt; read -r opt

        case "$opt" in
            1) do_format ;;
            2) do_label ;;
            3) do_partition ;;
            4) : ;;
            5|q|Q) info "Bye."; break ;;
            *) warn "Invalid option." ;;
        esac
        echo ""
    done
}

main "$@"
