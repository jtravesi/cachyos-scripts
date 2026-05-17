#!/usr/bin/env bash
# ============================================================
# bandwidth-check.sh
# Description : Network bandwidth and latency test using curl.
#               Tests download speed against multiple endpoints
#               and measures latency via ping. No third-party
#               tools required.
# Dependencies: curl, ping, awk
# Compatibility: Any Linux
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

require_cmds curl ping awk

# Test file endpoints — public CDN files of known size
DOWNLOAD_ENDPOINTS=(
    "https://speed.cloudflare.com/__down?bytes=10000000|Cloudflare|10MB"
    "https://proof.ovh.net/files/10Mb.dat|OVH|10MB"
    "https://speedtest.tele2.net/10MB.zip|Tele2|10MB"
)

# Latency targets
PING_TARGETS=(
    "1.1.1.1|Cloudflare DNS"
    "8.8.8.8|Google DNS"
    "9.9.9.9|Quad9 DNS"
)

TIMEOUT="${TIMEOUT:-15}"   # seconds per download test

# --- Format bytes to human readable ---
format_speed() {
    local bytes_per_sec="$1"
    if (( bytes_per_sec >= 1048576 )); then
        awk "BEGIN {printf \"%.1f MB/s\", $bytes_per_sec / 1048576}"
    elif (( bytes_per_sec >= 1024 )); then
        awk "BEGIN {printf \"%.1f KB/s\", $bytes_per_sec / 1024}"
    else
        echo "${bytes_per_sec} B/s"
    fi
}

# --- Download speed test ---
test_download() {
    section "Download speed"

    local total_speed=0
    local successful=0

    printf "\n  %-20s %-10s %-15s %s\n" "Endpoint" "Size" "Speed" "Status"
    printf "  %s\n" "$(printf '%.0s─' {1..60})"

    for endpoint_entry in "${DOWNLOAD_ENDPOINTS[@]}"; do
        IFS='|' read -r url label size <<< "$endpoint_entry"

        local start end elapsed bytes_per_sec speed status
        start=$(date +%s%N)

        local http_code
        http_code=$(curl -sf -o /dev/null -w "%{http_code} %{size_download} %{speed_download}" \
            --max-time "$TIMEOUT" \
            --connect-timeout 5 \
            "$url" 2>/dev/null)

        if [[ $? -eq 0 ]]; then
            local speed_bps
            speed_bps=$(awk '{print int($3)}' <<< "$http_code")
            speed=$(format_speed "$speed_bps")
            status="${GREEN}OK${RESET}"
            (( total_speed += speed_bps ))
            (( successful++ ))
        else
            speed="—"
            status="${RED}FAILED${RESET}"
        fi

        printf "  %-20s %-10s %-15s " "$label" "$size" "$speed"
        echo -e "$status"
    done

    if (( successful > 0 )); then
        local avg_speed
        avg_speed=$(format_speed $(( total_speed / successful )))
        echo ""
        ok "Average download speed: ${BOLD}${avg_speed}${RESET} (across ${successful} endpoint(s))"
    else
        error "All download tests failed. Check your internet connection."
    fi
}

# --- Latency test ---
test_latency() {
    section "Latency (ping)"

    printf "\n  %-20s %-12s %-12s %-12s %s\n" "Target" "Min" "Avg" "Max" "Status"
    printf "  %s\n" "$(printf '%.0s─' {1..65})"

    for target_entry in "${PING_TARGETS[@]}"; do
        IFS='|' read -r ip label <<< "$target_entry"

        local ping_output
        ping_output=$(ping -c 4 -W 3 "$ip" 2>/dev/null)

        if [[ $? -eq 0 ]]; then
            local stats min avg max
            stats=$(grep "rtt" <<< "$ping_output" | awk -F'/' '{print $5, $6, $7}' | tr '/' ' ')
            min=$(awk '{print $1}' <<< "$stats")
            avg=$(awk '{print $2}' <<< "$stats")
            max=$(awk '{print $3}' <<< "$stats")
            printf "  %-20s %-12s %-12s %-12s " \
                "${label} (${ip})" "${min}ms" "${avg}ms" "${max}ms"
            echo -e "${GREEN}OK${RESET}"
        else
            printf "  %-20s %-12s %-12s %-12s " \
                "${label} (${ip})" "—" "—" "—"
            echo -e "${RED}UNREACHABLE${RESET}"
        fi
    done
}

# --- DNS resolution test ---
test_dns() {
    section "DNS resolution"

    local targets=("google.com" "github.com" "archlinux.org")

    printf "\n  %-25s %-15s %s\n" "Domain" "Time" "Status"
    printf "  %s\n" "$(printf '%.0s─' {1..50})"

    for domain in "${targets[@]}"; do
        local start end elapsed
        start=$(date +%s%N)

        if curl -sf --max-time 5 --resolve "${domain}:443:$(getent hosts "$domain" | awk '{print $1}' | head -1)" \
            "https://${domain}" -o /dev/null 2>/dev/null; then
            end=$(date +%s%N)
            elapsed=$(( (end - start) / 1000000 ))
            printf "  %-25s %-15s " "$domain" "${elapsed}ms"
            echo -e "${GREEN}OK${RESET}"
        else
            # Try just getent
            if getent hosts "$domain" &>/dev/null; then
                end=$(date +%s%N)
                elapsed=$(( (end - start) / 1000000 ))
                printf "  %-25s %-15s " "$domain" "${elapsed}ms"
                echo -e "${YELLOW}RESOLVED (no HTTP)${RESET}"
            else
                printf "  %-25s %-15s " "$domain" "—"
                echo -e "${RED}FAILED${RESET}"
            fi
        fi
    done
}

# --- Main ---
main() {
    section "Network Bandwidth & Latency Check"

    test_latency
    test_dns
    test_download
}

main "$@"
