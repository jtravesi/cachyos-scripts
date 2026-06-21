#!/usr/bin/env bash
# ============================================================
# io-latency-check.sh
# Description : Quick per-disk I/O benchmark. For every physical
#               disk it measures random-read access latency and
#               sequential read throughput. Read-only by default
#               — it never writes to a device. With --write it
#               adds a throughput test that writes a temporary
#               file on the disk's mounted filesystem (then
#               deletes it), never touching the raw device.
#               Uses ioping / hdparm when available and falls
#               back to dd otherwise.
# Dependencies: lsblk, dd, blockdev (util-linux); optional: ioping
#               (precise latency), hdparm (read throughput)
# Compatibility: Any Linux
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

# Raw device reads need privileges; use sudo inline when not already root.
SUDO=""
[[ $EUID -ne 0 ]] && SUDO="sudo"

# --- Tunables ---
LAT_SAMPLES=20          # random reads for the dd-based latency fallback
LAT_BS=4096             # block size for latency reads (bytes)
SEQ_SIZE_MB=256         # sequential read size for the dd throughput fallback
WRITE_SIZE_MB=256       # size of the optional --write temp file

# Latency thresholds in milliseconds (type-aware)
SSD_LAT_WARN=1.0
SSD_LAT_CRIT=5.0
HDD_LAT_WARN=20.0
HDD_LAT_CRIT=50.0

DO_WRITE=0
GLOBAL_VERDICT="OK"
declare -a SUMMARY_LINES

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -w, --write   Also run a write throughput test. Writes a ${WRITE_SIZE_MB}MB
                temporary file on each disk's mounted filesystem and deletes
                it afterwards. Never writes to the raw device.
  -h, --help    Show this help.

Notes:
  * Requires root (raw device reads). You will be prompted for sudo.
  * Read-only by default — safe to run on a system disk.
  * Install 'ioping' for accurate latency figures (or use 'fio' for full
    benchmarking); without ioping the dd fallback includes process-call
    overhead and overstates latency on very fast (NVMe) devices.
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -w|--write) DO_WRITE=1 ;;
            -h|--help)  usage; exit 0 ;;
            -*)         usage; fatal "Unknown option: $1" ;;
            *)          usage; fatal "Unexpected argument: $1" ;;
        esac
        shift
    done
}

# --- Raise a verdict variable's severity. Usage: bump <varname> WARN|CRIT ---
bump() {
    local -n _v="$1"
    case "$2" in
        CRIT) _v="CRIT" ;;
        WARN) [[ "$_v" != "CRIT" ]] && _v="WARN" ;;
    esac
}

# --- Compare two floats with awk: returns 0 if $1 >= $2 ---
fge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>=b)}'; }

# --- Verdict for a latency value given disk kind (HDD vs solid state) ---
lat_verdict() {
    local ms="$1" kind="$2" warn crit
    if [[ "$kind" == "HDD" ]]; then warn="$HDD_LAT_WARN"; crit="$HDD_LAT_CRIT"
    else                            warn="$SSD_LAT_WARN"; crit="$SSD_LAT_CRIT"
    fi
    if   fge "$ms" "$crit"; then echo "CRIT"
    elif fge "$ms" "$warn"; then echo "WARN"
    else                         echo "OK"
    fi
}

# --- Colored value for a verdict ---
verdict_color() {
    case "$1" in
        CRIT) echo "$RED" ;;
        WARN) echo "$YELLOW" ;;
        *)    echo "$GREEN" ;;
    esac
}

# --- Random-read latency -> "min avg max" in ms, via ioping ---
lat_ioping() {
    local dev="$1" out line rhs
    out=$($SUDO ioping -c "$LAT_SAMPLES" -i 0 -q -D "$dev" 2>/dev/null) || return 1
    # ioping prints e.g. "min/avg/max/mdev = 53.2 us / 71.4 us / 95.3 us / 12 us"
    line=$(grep -E 'min/avg/max' <<< "$out" | tail -1)
    [[ -z "$line" ]] && return 1
    rhs="${line#*= }"
    awk -v s="$rhs" 'BEGIN{
        n = split(s, parts, "/");
        if (n < 3) exit 1;
        for (i = 1; i <= 3; i++) {
            m = parts[i]; gsub(/^[ \t]+|[ \t]+$/, "", m);
            split(m, kv, " "); v = kv[1]; u = kv[2];
            f = 1;
            if      (u == "s")  f = 1000;
            else if (u == "ms") f = 1;
            else if (u == "us") f = 0.001;
            else if (u == "ns") f = 0.000001;
            o[i] = v * f;
        }
        printf "%.3f %.3f %.3f", o[1], o[2], o[3];
    }'
}

# --- Random-read latency (ms) -> "min avg max" via dd, direct, random offsets ---
lat_dd() {
    local dev="$1"
    local size_bytes max_block
    size_bytes=$($SUDO blockdev --getsize64 "$dev" 2>/dev/null) || return 1
    [[ "$size_bytes" =~ ^[0-9]+$ && "$size_bytes" -gt 0 ]] || return 1
    max_block=$(( size_bytes / LAT_BS ))
    (( max_block < 1 )) && return 1

    local i off t0 t1 ns sum=0 min="" max=0 samples=0
    for (( i = 0; i < LAT_SAMPLES; i++ )); do
        off=$(( (RANDOM * 32768 + RANDOM) % max_block ))
        t0=$(date +%s%N)
        $SUDO dd if="$dev" of=/dev/null bs="$LAT_BS" count=1 skip="$off" \
            iflag=direct status=none 2>/dev/null || continue
        t1=$(date +%s%N)
        ns=$(( t1 - t0 ))
        sum=$(( sum + ns ))
        (( samples++ ))
        [[ -z "$min" || ns -lt min ]] && min=$ns
        (( ns > max )) && max=$ns
    done
    (( samples == 0 )) && return 1
    # Convert ns -> ms with two decimals
    awk -v mn="$min" -v sm="$sum" -v mx="$max" -v n="$samples" \
        'BEGIN{printf "%.3f %.3f %.3f", mn/1e6, (sm/n)/1e6, mx/1e6}'
}

# --- Sequential read throughput (MB/s) via hdparm ---
tput_hdparm() {
    local dev="$1" out
    out=$($SUDO hdparm -t "$dev" 2>/dev/null) || return 1
    grep -oE '[0-9.]+ MB/sec' <<< "$out" | tail -1 | grep -oE '[0-9.]+'
}

# --- Parse a dd stderr report "<bytes> bytes ... copied, <secs> s, ..."
#     into MB/s. Expects LC_ALL=C dd output (dot decimal). ---
dd_mbps() {
    local out="$1" bytes secs
    bytes=$(awk '/copied/{print $1; exit}' <<< "$out")
    secs=$(awk -F'copied, ' 'NF>1{split($2, a, " "); print a[1]; exit}' <<< "$out")
    [[ "$bytes" =~ ^[0-9]+$ && -n "$secs" ]] || return 1
    awk -v b="$bytes" -v s="$secs" 'BEGIN{ if (s>0) printf "%.1f", (b/1048576)/s; else exit 1 }'
}

# --- Sequential read throughput (MB/s) via dd (direct, from device start) ---
tput_dd() {
    local dev="$1" out
    # LC_ALL=C so dd prints a '.' decimal regardless of the user's locale.
    out=$($SUDO env LC_ALL=C dd if="$dev" of=/dev/null bs=1M count="$SEQ_SIZE_MB" \
        iflag=direct 2>&1) || return 1
    dd_mbps "$out"
}

# --- First writable mountpoint backed by device $1 (incl. its partitions) ---
device_mountpoint() {
    local dev="$1" mp
    while read -r mp; do
        [[ -n "$mp" && -d "$mp" && -w "$mp" ]] && { echo "$mp"; return 0; }
    done < <(lsblk -nro MOUNTPOINT "$dev" 2>/dev/null)
    return 1
}

# --- Write throughput (MB/s) on a temp file at mountpoint $1 ---
tput_write() {
    local mp="$1" tmp out mbps
    # Bail out unless there's comfortably more free space than we intend to write.
    local avail_mb
    avail_mb=$(df -Pm "$mp" 2>/dev/null | awk 'NR==2{print $4}')
    [[ "$avail_mb" =~ ^[0-9]+$ ]] && (( avail_mb < WRITE_SIZE_MB + 256 )) && {
        echo "SKIP:low-space"; return 1; }

    tmp="${mp%/}/.io-latency-check.$$.tmp"
    # LC_ALL=C so dd prints a '.' decimal regardless of the user's locale.
    out=$(LC_ALL=C dd if=/dev/zero of="$tmp" bs=1M count="$WRITE_SIZE_MB" \
        oflag=direct conv=fdatasync 2>&1)
    local rc=$?
    rm -f "$tmp" 2>/dev/null
    (( rc != 0 )) && { echo "SKIP:write-failed"; return 1; }

    mbps=$(dd_mbps "$out") || { echo "SKIP:parse"; return 1; }
    echo "$mbps"
}

# --- Benchmark a single disk ---
bench_disk() {
    local name="$1" rota="$2" model="$3" size="$4"
    local dev="/dev/${name}"

    local kind="HDD"
    [[ "$name" == nvme* ]] && kind="NVMe"
    [[ "$rota" == "0" && "$kind" != "NVMe" ]] && kind="SSD"

    section "${dev}  —  ${model:-unknown}"
    printf "    %-22s %s\n" "Type / size:" "${kind}${size:+, ${size}}"

    # Quick reachability probe (handles empty card readers etc.)
    if ! $SUDO dd if="$dev" of=/dev/null bs="$LAT_BS" count=1 iflag=direct status=none 2>/dev/null; then
        warn "Device not readable (no media or unsupported) — skipping."
        SUMMARY_LINES+=("$(printf '%s|%s|%s' "$dev" "N/A" "skipped")")
        return 0
    fi

    # --- Latency (ioping if present, else dd fallback) ---
    local verdict="OK" trip=""
    command -v ioping &>/dev/null && trip=$(lat_ioping "$dev")
    [[ -z "$trip" ]] && trip=$(lat_dd "$dev")
    if [[ -n "$trip" ]]; then
        local mn av mx
        read -r mn av mx <<< "$trip"
        verdict=$(lat_verdict "$av" "$kind")
        local c; c=$(verdict_color "$verdict")
        printf "    %-22s ${c}%s ms${RESET}  (min %s / max %s ms)\n" \
            "Random read latency:" "$av" "$mn" "$mx"
    else
        warn "Latency measurement failed."
    fi

    # --- Sequential read throughput ---
    local rmbs
    if command -v hdparm &>/dev/null; then
        rmbs=$(tput_hdparm "$dev")
    fi
    [[ -z "$rmbs" ]] && rmbs=$(tput_dd "$dev")
    [[ -n "$rmbs" ]] && printf "    %-22s %s MB/s\n" "Sequential read:" "$rmbs"

    # --- Optional write test ---
    if (( DO_WRITE )); then
        local mp
        if mp=$(device_mountpoint "$dev"); then
            local wmbs
            wmbs=$(tput_write "$mp")
            if [[ "$wmbs" == SKIP:* ]]; then
                warn "Write test skipped (${wmbs#SKIP:}) on ${mp}."
            else
                printf "    %-22s %s MB/s  ${CYAN}(temp file on %s)${RESET}\n" \
                    "Sequential write:" "$wmbs" "$mp"
            fi
        else
            info "Write test skipped — no writable mountpoint on ${dev}."
        fi
    fi

    bump GLOBAL_VERDICT "$verdict"
    SUMMARY_LINES+=("$(printf '%s|%s|%s' "$dev" "${rmbs:-?} MB/s read" "$verdict")")
}

# --- Final summary ---
show_summary() {
    section "Summary"
    local entry dev detail verdict color symbol
    for entry in "${SUMMARY_LINES[@]}"; do
        IFS='|' read -r dev detail verdict <<< "$entry"
        case "$verdict" in
            OK)   color="$GREEN";  symbol="✓" ;;
            WARN) color="$YELLOW"; symbol="!" ;;
            CRIT) color="$RED";    symbol="✗" ;;
            *)    color="$CYAN";   symbol="*" ;;
        esac
        printf "  ${color}%s${RESET}  %-14s %-22s ${color}%s${RESET}\n" \
            "$symbol" "$dev" "$detail" "$verdict"
    done

    echo ""
    if ! command -v ioping &>/dev/null; then
        info "Latency uses a dd fallback (includes call overhead). Install ${BOLD}ioping${RESET} for precise figures."
    fi
}

# --- Main ---
main() {
    parse_args "$@"
    require_cmds lsblk dd

    section "I/O Latency Check"

    if [[ $EUID -ne 0 ]]; then
        info "Raw device access requires root. You may be prompted for your password."
        sudo -v || fatal "sudo authentication failed."
    fi

    if (( DO_WRITE )); then
        warn "Write test enabled: a ${WRITE_SIZE_MB}MB temp file will be written"
        warn "on each disk's mounted filesystem and then deleted."
        confirm "Proceed with write tests?" || { info "Cancelled."; exit 0; }
    fi

    # Physical disks only — skip zram, loop, optical and floppy devices.
    local -a rows
    mapfile -t rows < <(lsblk -dn -o NAME,TYPE,ROTA,MODEL,SIZE 2>/dev/null \
        | awk '$2=="disk" && $1 !~ /^(zram|loop|sr|fd)/')

    [[ ${#rows[@]} -eq 0 ]] && fatal "No physical disks found."

    local name type rota model size
    while read -r name type rota model size; do
        # MODEL may contain spaces; re-read with fixed columns per device.
        model=$(lsblk -dn -o MODEL "/dev/${name}" 2>/dev/null | xargs)
        size=$(lsblk -dn -o SIZE "/dev/${name}" 2>/dev/null | xargs)
        rota=$(lsblk -dn -o ROTA "/dev/${name}" 2>/dev/null | xargs)
        bench_disk "$name" "$rota" "$model" "$size"
    done < <(printf '%s\n' "${rows[@]}")

    show_summary

    [[ "$GLOBAL_VERDICT" == "CRIT" ]] && exit 2
    [[ "$GLOBAL_VERDICT" == "WARN" ]] && exit 1
    exit 0
}

main "$@"
