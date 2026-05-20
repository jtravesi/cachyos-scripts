#!/usr/bin/env bash
# ============================================================
# system-info.sh
# Description : Full system summary: hardware, OS, CPU, memory,
#               disks, network interfaces and uptime. Read-only.
# Dependencies: lscpu, free, df, lsblk, ip, uname, hostnamectl
# Compatibility: Any Linux
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

# --- OS & Host ---
show_host() {
    section "System"

    local hostname os kernel arch machine firmware
    hostname=$(hostname 2>/dev/null)
    os=$(hostnamectl 2>/dev/null | awk -F': ' '/Operating System/{print $2}')
    kernel=$(uname -r)
    arch=$(uname -m)
    machine=$(hostnamectl 2>/dev/null | awk -F': ' '/Hardware Model/{print $2}')
    vendor=$(hostnamectl 2>/dev/null | awk -F': ' '/Hardware Vendor/{print $2}')
    firmware=$(hostnamectl 2>/dev/null | awk -F': ' '/Firmware Version/{print $2}')
    chassis=$(hostnamectl 2>/dev/null | awk -F': ' '/Chassis/{gsub(/[^a-zA-Z ]/, "", $2); print $2}' | xargs)

    printf "  %-18s %s\n" "Hostname:"   "$hostname"
    printf "  %-18s %s\n" "OS:"         "${os:-unknown}"
    printf "  %-18s %s\n" "Kernel:"     "$kernel"
    printf "  %-18s %s\n" "Arch:"       "$arch"
    printf "  %-18s %s\n" "Chassis:"    "${chassis:-unknown}"
    printf "  %-18s %s %s\n" "Hardware:" "${vendor:-}" "${machine:-}"
    printf "  %-18s %s\n" "Firmware:"   "${firmware:-unknown}"
}

# --- Uptime & Load ---
show_uptime() {
    section "Uptime & Load"

    local uptime_str load idle
    uptime_str=$(uptime -p 2>/dev/null || uptime)
    load=$(uptime 2>/dev/null | grep -oP 'load average: \K.*')

    printf "  %-18s %s\n" "Uptime:"      "$uptime_str"
    printf "  %-18s %s\n" "Load avg:"    "${load:-unknown}"

    # Logged-in users
    local users
    users=$(who 2>/dev/null | wc -l)
    printf "  %-18s %s\n" "Logged in:"   "${users} user(s)"
}

# --- CPU ---
show_cpu() {
    section "CPU"

    local model cores threads sockets freq_max freq_cur governor
    model=$(lscpu 2>/dev/null | awk -F': +' '/Model name/{print $2; exit}')
    cores=$(lscpu 2>/dev/null | awk -F': +' '/^Core\(s\) per socket/{print $2}')
    sockets=$(lscpu 2>/dev/null | awk -F': +' '/^Socket\(s\)/{print $2}')
    threads=$(lscpu 2>/dev/null | awk -F': +' '/^Thread\(s\) per core/{print $2}')
    freq_max=$(lscpu 2>/dev/null | awk -F': +' '/CPU max MHz/{printf "%.0f MHz", $2}')
    freq_cur=$(lscpu 2>/dev/null | awk -F': +' '/CPU\(s\) scaling MHz/{printf "%s", $2; exit}')
    [[ -z "$freq_cur" ]] && freq_cur=$(lscpu 2>/dev/null | awk -F': +' '/CPU MHz/{printf "%.0f MHz", $2; exit}')

    local total_cores=$(( ${sockets:-1} * ${cores:-1} ))
    local total_threads=$(( total_cores * ${threads:-1} ))

    printf "  %-18s %s\n" "Model:"       "${model:-unknown}"
    printf "  %-18s %d socket(s) × %d core(s) × %d thread(s) = %d logical CPU(s)\n" \
        "Topology:" "${sockets:-1}" "${cores:-?}" "${threads:-?}" "$total_threads"
    printf "  %-18s %s (max %s)\n" "Frequency:" "${freq_cur:-?}" "${freq_max:-?}"

    # Governor per core (show unique values)
    if [[ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
        local governors
        governors=$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null \
            | sort -u | tr '\n' ' ')
        printf "  %-18s %s\n" "Governor:" "${governors:-unknown}"
    fi

    # Temperature via sensors
    if command -v sensors &>/dev/null; then
        local cpu_temp
        cpu_temp=$(sensors 2>/dev/null \
            | grep -iE 'Tctl|Tdie|Package id|Core 0' \
            | awk '{print $1, $2}' | head -1)
        [[ -n "$cpu_temp" ]] && printf "  %-18s %s\n" "Temperature:" "$cpu_temp"
    fi
}

# --- Memory ---
show_memory() {
    section "Memory"

    free -h 2>/dev/null | awk '
        /^Mem:/ {
            printf "  %-18s %s total  |  %s used  |  %s free  |  %s available\n",
                "RAM:", $2, $3, $4, $7
        }
        /^Swap:/ {
            printf "  %-18s %s total  |  %s used  |  %s free\n",
                "Swap:", $2, $3, $4
        }
    '
}

# --- Disks ---
show_disks() {
    section "Disks"

    # Block devices overview
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL 2>/dev/null \
        | grep -v '^loop' \
        | awk 'NR==1{printf "  %s\n", $0; next} {printf "  %s\n", $0}'

    echo ""

    # Filesystem usage
    info "Filesystem usage:"
    printf "  %-25s %6s %6s %6s %5s  %s\n" "SOURCE" "SIZE" "USED" "AVAIL" "USE%" "MOUNT"
    df -h --output=source,size,used,avail,pcent,target 2>/dev/null \
        | grep -v '^SOURCE\|^Filesystem\|^tmpfs\|^devtmpfs\|^udev\|^none\|^efivarfs' \
        | grep -v '^/dev/loop' \
        | awk '{printf "  %-25s %6s %6s %6s %5s  %s\n",$1,$2,$3,$4,$5,$6}'
}

# --- Network ---
show_network() {
    section "Network"

    ip -br addr 2>/dev/null | while IFS= read -r line; do
        local iface state addrs
        iface=$(awk '{print $1}' <<< "$line")
        state=$(awk '{print $2}' <<< "$line")
        addrs=$(awk '{$1=$2=""; print $0}' <<< "$line" | xargs)

        local color="$RESET"
        [[ "$state" == "UP" ]] && color="$GREEN"
        [[ "$state" == "DOWN" ]] && color="$RED"

        printf "  ${color}%-18s %-8s %s${RESET}\n" "$iface" "$state" "${addrs:--}"
    done

    echo ""
    local gw
    gw=$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')
    printf "  %-18s %s\n" "Default GW:" "${gw:-none}"

    local dns
    dns=$(grep '^nameserver' /etc/resolv.conf 2>/dev/null \
        | awk '{printf "%s ", $2}' | xargs)
    printf "  %-18s %s\n" "DNS:" "${dns:-unknown}"
}

# --- GPU ---
show_gpu() {
    command -v lspci &>/dev/null || return

    local gpus
    # Match PCI class names exactly to avoid false positives (e.g. "Ultra 3D" NVMe)
    gpus=$(lspci 2>/dev/null | grep -E 'VGA compatible controller|3D controller|Display controller' | sed 's/^[^ ]* //')

    [[ -z "$gpus" ]] && return

    section "GPU"
    while IFS= read -r gpu; do
        printf "  %s\n" "$gpu"
    done <<< "$gpus"

    # NVIDIA driver version if present
    if [[ -f /proc/driver/nvidia/version ]]; then
        local nv_ver
        nv_ver=$(grep -oP 'Module for x86_64\s+\K[\d.]+' /proc/driver/nvidia/version 2>/dev/null)
        [[ -n "$nv_ver" ]] && printf "  %-18s %s\n" "NVIDIA driver:" "$nv_ver"
    fi
}

# --- Packages ---
show_packages() {
    section "Packages"

    if command -v pacman &>/dev/null; then
        local total aur
        total=$(pacman -Qq 2>/dev/null | wc -l)
        aur=$(pacman -Qm 2>/dev/null | wc -l)
        printf "  %-18s %d total  (%d AUR)\n" "Installed:" "$total" "$aur"
    fi
}

# --- Main ---
main() {
    section "System Info"
    require_cmds lscpu free df lsblk ip uname

    show_host
    show_uptime
    show_cpu
    show_memory
    show_disks
    show_network
    show_gpu
    show_packages
}

main "$@"
