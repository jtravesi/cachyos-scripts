#!/usr/bin/env bash
# ============================================================
# hardening-check.sh
# Description : Pragmatic security hardening audit. Reviews SSH config,
#               kernel sysctl parameters, critical file permissions,
#               PAM/authentication policy, mount flags and miscellaneous
#               security posture (AppArmor, core dumps, CVE scan).
#               Read-only — never modifies the system.
# Dependencies: sysctl, stat, findmnt, awk, grep
# Compatibility: Any systemd Linux (some checks Arch-specific)
# ============================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

VERBOSE=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
    -v, --verbose    Show current and expected values for each check
    -h, --help       Show this help

Runs a pragmatic hardening audit over SSH, sysctl, file permissions,
PAM, mounts and miscellaneous posture (AppArmor, core dumps, CVEs).
Read-only. Run as root for full coverage.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--verbose) VERBOSE=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *) error "Unknown option: $1"; usage; exit 2 ;;
    esac
done

require_cmds sysctl stat findmnt awk grep

# --- Score tracking ---
# Per-section counters: SECTION_TOTAL, SECTION_PASS
declare -A SECTION_TOTAL SECTION_PASS SECTION_FAIL SECTION_WARN SECTION_SKIP
GLOBAL_FAIL=0

CURRENT_SECTION=""

start_section() {
    CURRENT_SECTION="$1"
    SECTION_TOTAL[$CURRENT_SECTION]=0
    SECTION_PASS[$CURRENT_SECTION]=0
    SECTION_FAIL[$CURRENT_SECTION]=0
    SECTION_WARN[$CURRENT_SECTION]=0
    SECTION_SKIP[$CURRENT_SECTION]=0
    section "$CURRENT_SECTION"
}

# report STATUS "label" "current" "expected" "recommendation"
report() {
    local status="$1" label="$2" current="${3:-}" expected="${4:-}" recommend="${5:-}"
    local sym color

    SECTION_TOTAL[$CURRENT_SECTION]=$((SECTION_TOTAL[$CURRENT_SECTION] + 1))

    case "$status" in
        OK)   sym="✓"; color="$GREEN";  SECTION_PASS[$CURRENT_SECTION]=$((SECTION_PASS[$CURRENT_SECTION] + 1)) ;;
        WARN) sym="!"; color="$YELLOW"; SECTION_WARN[$CURRENT_SECTION]=$((SECTION_WARN[$CURRENT_SECTION] + 1)) ;;
        FAIL) sym="✗"; color="$RED";    SECTION_FAIL[$CURRENT_SECTION]=$((SECTION_FAIL[$CURRENT_SECTION] + 1)); GLOBAL_FAIL=1 ;;
        SKIP) sym="-"; color="$CYAN";   SECTION_SKIP[$CURRENT_SECTION]=$((SECTION_SKIP[$CURRENT_SECTION] + 1)) ;;
    esac

    echo -e "    ${color}[${sym}] ${label}${RESET}"
    if [[ "$VERBOSE" -eq 1 && -n "$current" ]]; then
        echo -e "        current:  ${current}"
        [[ -n "$expected" ]] && echo -e "        expected: ${expected}"
    fi
    if [[ "$status" != "OK" && -n "$recommend" ]]; then
        echo -e "        ${YELLOW}↳ ${recommend}${RESET}"
    fi
}

# --- SSH config helpers ---

# Reads effective value of an sshd_config directive, considering
# /etc/ssh/sshd_config and /etc/ssh/sshd_config.d/*.conf overrides.
# Last match wins (in OpenSSH, first match wins, but for our flat reads
# we read main first then drop-ins).
ssh_get() {
    local key="$1"
    local value=""
    local files=("/etc/ssh/sshd_config")
    if [[ -d /etc/ssh/sshd_config.d ]]; then
        local f
        for f in /etc/ssh/sshd_config.d/*.conf; do
            [[ -f "$f" ]] && files+=("$f")
        done
    fi
    local file
    for file in "${files[@]}"; do
        [[ -r "$file" ]] || continue
        local match
        match=$(grep -iE "^\s*${key}\s+" "$file" 2>/dev/null | head -1 | awk '{print $2}')
        [[ -n "$match" ]] && value="$match"
    done
    echo "$value"
}

# --- Section 1: SSH ---

check_ssh() {
    start_section "SSH"

    if [[ ! -f /etc/ssh/sshd_config ]]; then
        report SKIP "sshd not installed" "" "" ""
        return
    fi

    if [[ ! -r /etc/ssh/sshd_config ]]; then
        report SKIP "/etc/ssh/sshd_config not readable (need root)" "" "" ""
        return
    fi

    local val

    val=$(ssh_get PermitRootLogin)
    val="${val:-prohibit-password}"   # OpenSSH default
    case "$val" in
        no|prohibit-password) report OK   "PermitRootLogin = ${val}" "$val" "no|prohibit-password" ;;
        yes)                  report FAIL "PermitRootLogin = yes"     "$val" "no" "Set 'PermitRootLogin no' in sshd_config" ;;
        *)                    report WARN "PermitRootLogin = ${val}"  "$val" "no" "Use 'no' or 'prohibit-password'" ;;
    esac

    val=$(ssh_get PasswordAuthentication)
    val="${val:-yes}"   # OpenSSH default
    if [[ "$val" == "no" ]]; then
        report OK "PasswordAuthentication = no" "$val" "no"
    else
        if systemctl is-active --quiet sshd 2>/dev/null; then
            report FAIL "PasswordAuthentication = ${val}" "$val" "no" "Switch to key-based auth and disable passwords"
        else
            report WARN "PasswordAuthentication = ${val} (sshd inactive)" "$val" "no" "Disable when enabling sshd"
        fi
    fi

    val=$(ssh_get PermitEmptyPasswords)
    val="${val:-no}"
    if [[ "$val" == "no" ]]; then
        report OK "PermitEmptyPasswords = no" "$val" "no"
    else
        report FAIL "PermitEmptyPasswords = ${val}" "$val" "no" "Set 'PermitEmptyPasswords no'"
    fi

    val=$(ssh_get X11Forwarding)
    val="${val:-no}"
    if [[ "$val" == "no" ]]; then
        report OK "X11Forwarding = no" "$val" "no"
    else
        report WARN "X11Forwarding = ${val}" "$val" "no" "Disable unless explicitly needed"
    fi

    val=$(ssh_get MaxAuthTries)
    val="${val:-6}"
    if [[ "$val" -le 4 ]] 2>/dev/null; then
        report OK   "MaxAuthTries = ${val}" "$val" "≤ 4"
    elif [[ "$val" -le 6 ]] 2>/dev/null; then
        report WARN "MaxAuthTries = ${val}" "$val" "≤ 4" "Lower to 3 or 4"
    else
        report FAIL "MaxAuthTries = ${val}" "$val" "≤ 4" "Lower to 3 or 4"
    fi
}

# --- Section 2: Kernel / sysctl ---

# check_sysctl param expected_op expected_val recommend
# op: "eq" / "gte"
check_sysctl() {
    local param="$1" op="$2" expected="$3" recommend="${4:-}"
    local current
    current=$(sysctl -n "$param" 2>/dev/null || echo "")

    if [[ -z "$current" ]]; then
        report SKIP "$param (not exposed)" "" "" ""
        return
    fi

    local pass=0
    case "$op" in
        eq)  [[ "$current" == "$expected" ]] && pass=1 ;;
        gte) [[ "$current" -ge "$expected" ]] 2>/dev/null && pass=1 ;;
    esac

    if [[ "$pass" -eq 1 ]]; then
        report OK "${param} = ${current}" "$current" "${op} ${expected}"
    else
        report FAIL "${param} = ${current}" "$current" "${op} ${expected}" \
            "${recommend:-Set in /etc/sysctl.d/99-hardening.conf: ${param} = ${expected}}"
    fi
}

check_kernel() {
    start_section "Kernel / sysctl"

    check_sysctl kernel.dmesg_restrict          eq  1
    check_sysctl kernel.kptr_restrict           gte 1
    check_sysctl kernel.yama.ptrace_scope       gte 1
    check_sysctl kernel.unprivileged_bpf_disabled gte 1
    check_sysctl net.ipv4.tcp_syncookies        eq  1
    check_sysctl net.ipv4.conf.all.rp_filter    eq  1
    check_sysctl net.ipv4.conf.all.accept_redirects eq 0
    check_sysctl net.ipv4.conf.all.send_redirects   eq 0
    check_sysctl kernel.randomize_va_space      eq  2
    check_sysctl fs.protected_symlinks          eq  1
    check_sysctl fs.protected_hardlinks         eq  1
}

# --- Section 3: File permissions ---

# check_perm path expected_mode expected_owner expected_group [allow_stricter]
check_perm() {
    local path="$1" want_mode="$2" want_owner="$3" want_group="$4" stricter="${5:-0}"

    if [[ ! -e "$path" ]]; then
        report SKIP "$path (does not exist)" "" "" ""
        return
    fi

    if [[ ! -r "$path" && "$EUID" -ne 0 ]]; then
        # We can still stat() metadata without read perms in most cases
        :
    fi

    local mode owner group
    mode=$(stat -c '%a' "$path" 2>/dev/null) || { report SKIP "$path (stat failed)" "" "" ""; return; }
    owner=$(stat -c '%U' "$path" 2>/dev/null)
    group=$(stat -c '%G' "$path" 2>/dev/null)

    local current="${mode} ${owner}:${group}"
    local expected="${want_mode} ${want_owner}:${want_group}"

    local mode_ok=0 owner_ok=0
    if [[ "$stricter" -eq 1 ]]; then
        [[ "$mode" -le "$want_mode" ]] 2>/dev/null && mode_ok=1
    else
        [[ "$mode" == "$want_mode" ]] && mode_ok=1
    fi
    [[ "$owner" == "$want_owner" && "$group" == "$want_group" ]] && owner_ok=1

    if [[ "$mode_ok" -eq 1 && "$owner_ok" -eq 1 ]]; then
        report OK "${path}" "$current" "$expected"
    elif [[ "$owner_ok" -eq 0 ]]; then
        report FAIL "${path} ownership" "$current" "$expected" "chown ${want_owner}:${want_group} ${path}"
    else
        report FAIL "${path} mode" "$current" "$expected" "chmod ${want_mode} ${path}"
    fi
}

check_perms() {
    start_section "File permissions"

    check_perm /etc/shadow   600 root root
    check_perm /etc/gshadow  600 root root
    check_perm /etc/passwd   644 root root
    check_perm /etc/group    644 root root
    check_perm /etc/sudoers  440 root root

    # /boot — Arch default is 755 root root which is acceptable; 700 ideal
    if [[ -d /boot ]]; then
        local mode
        mode=$(stat -c '%a' /boot 2>/dev/null)
        if [[ "$mode" -le 700 ]] 2>/dev/null; then
            report OK   "/boot (${mode})" "$mode" "≤ 700"
        elif [[ "$mode" == "755" ]]; then
            report WARN "/boot (755)" "755" "700" "chmod 700 /boot to hide kernel/initramfs metadata from non-root"
        else
            report FAIL "/boot (${mode})" "$mode" "≤ 755" "chmod 755 /boot or stricter"
        fi
    fi

    # Per-user authorized_keys
    local uhome
    for uhome in /home/*; do
        [[ -d "$uhome" ]] || continue
        local ak="${uhome}/.ssh/authorized_keys"
        if [[ -e "$ak" ]]; then
            local mode
            mode=$(stat -c '%a' "$ak" 2>/dev/null)
            if [[ "$mode" -le 600 ]] 2>/dev/null; then
                report OK   "${ak} (${mode})" "$mode" "≤ 600"
            else
                report FAIL "${ak} (${mode})" "$mode" "≤ 600" "chmod 600 ${ak}"
            fi
        fi
    done
}

# --- Section 4: PAM / Authentication ---

check_pam() {
    start_section "PAM / Authentication"

    # faillock or tally2 in system-auth
    local sa="/etc/pam.d/system-auth"
    if [[ -r "$sa" ]]; then
        if grep -qE "^\s*[^#].*pam_faillock\.so" "$sa"; then
            report OK "pam_faillock configured" "present" "present"
        elif grep -qE "^\s*[^#].*pam_tally2\.so" "$sa"; then
            report OK "pam_tally2 configured" "present" "present (legacy)"
        else
            report WARN "No account lockout module" "none" "pam_faillock" \
                "Configure pam_faillock in /etc/pam.d/system-auth to lock accounts after N failed attempts"
        fi

        if grep -qE "^\s*[^#].*pam_pwquality\.so" "$sa" || grep -qE "^\s*[^#].*pam_cracklib\.so" "$sa"; then
            report OK "Password quality module" "present" "present"
        else
            report WARN "No password quality enforcement" "none" "pam_pwquality" \
                "Install libpwquality and add pam_pwquality.so to /etc/pam.d/passwd"
        fi
    else
        report SKIP "/etc/pam.d/system-auth not readable" "" "" ""
        report SKIP "Password quality check (needs system-auth)" "" "" ""
    fi

    # login.defs UMASK
    if [[ -r /etc/login.defs ]]; then
        local umask_val
        umask_val=$(awk '/^UMASK/ {print $2; exit}' /etc/login.defs)
        umask_val="${umask_val:-022}"
        case "$umask_val" in
            027|077) report OK   "UMASK = ${umask_val}" "$umask_val" "027 or stricter" ;;
            022)     report WARN "UMASK = 022 (Arch default)" "022" "027" "Set 'UMASK 027' in /etc/login.defs" ;;
            *)       report WARN "UMASK = ${umask_val}" "$umask_val" "027" ;;
        esac

        local maxdays
        maxdays=$(awk '/^PASS_MAX_DAYS/ {print $2; exit}' /etc/login.defs)
        maxdays="${maxdays:-99999}"
        if [[ "$maxdays" -le 90 ]] 2>/dev/null; then
            report OK   "PASS_MAX_DAYS = ${maxdays}" "$maxdays" "≤ 90"
        elif [[ "$maxdays" -le 180 ]] 2>/dev/null; then
            report WARN "PASS_MAX_DAYS = ${maxdays}" "$maxdays" "≤ 90"
        else
            report WARN "PASS_MAX_DAYS = ${maxdays} (no rotation)" "$maxdays" "≤ 90" \
                "Set 'PASS_MAX_DAYS 90' in /etc/login.defs"
        fi
    else
        report SKIP "/etc/login.defs not readable" "" "" ""
    fi
}

# --- Section 5: Mounts ---

# Check if a mount point has all the required options
mount_has_opts() {
    local mp="$1"; shift
    local opts
    opts=$(findmnt -no OPTIONS "$mp" 2>/dev/null) || return 1
    local opt
    for opt in "$@"; do
        echo ",$opts," | grep -q ",${opt}," || return 1
    done
    return 0
}

check_mounts() {
    start_section "Mounts"

    # /tmp — should have nosuid,nodev (noexec is nice but breaks some installers)
    if findmnt -no SOURCE /tmp &>/dev/null; then
        if mount_has_opts /tmp nosuid nodev; then
            report OK "/tmp has nosuid,nodev" "$(findmnt -no OPTIONS /tmp)" "nosuid,nodev"
        else
            report WARN "/tmp missing hardening flags" "$(findmnt -no OPTIONS /tmp)" "nosuid,nodev" \
                "Mount /tmp as tmpfs with nosuid,nodev"
        fi
    else
        report SKIP "/tmp not a separate mount" "" "" ""
    fi

    # /dev/shm — should have nosuid,nodev,noexec
    if findmnt -no SOURCE /dev/shm &>/dev/null; then
        if mount_has_opts /dev/shm nosuid nodev noexec; then
            report OK "/dev/shm has nosuid,nodev,noexec" "$(findmnt -no OPTIONS /dev/shm)" "nosuid,nodev,noexec"
        else
            report WARN "/dev/shm missing flags" "$(findmnt -no OPTIONS /dev/shm)" "nosuid,nodev,noexec" \
                "Add nosuid,nodev,noexec to /dev/shm in /etc/fstab"
        fi
    fi

    # /home as separate mount — nosuid is nice
    if findmnt -no SOURCE /home &>/dev/null; then
        if mount_has_opts /home nosuid; then
            report OK "/home has nosuid" "$(findmnt -no OPTIONS /home)" "nosuid"
        else
            report WARN "/home (separate mount) without nosuid" "$(findmnt -no OPTIONS /home)" "nosuid" \
                "Add nosuid to /home in /etc/fstab"
        fi
    fi

    # Removable mounts (under /media, /mnt, /run/media) without nosuid
    local m
    while IFS= read -r m; do
        [[ -z "$m" ]] && continue
        if ! mount_has_opts "$m" nosuid; then
            report WARN "Removable mount without nosuid: $m" "$(findmnt -no OPTIONS "$m")" "nosuid" \
                "Removable devices should be mounted with nosuid,nodev"
        fi
    done < <(findmnt -no TARGET | grep -E '^/(media|mnt|run/media)/' || true)
}

# --- Section 6: Misc / MAC ---

check_misc() {
    start_section "Misc"

    # AppArmor
    if command -v aa-status &>/dev/null; then
        if aa-status --enabled 2>/dev/null; then
            local profiles
            profiles=$(aa-status --profiled 2>/dev/null || echo "?")
            report OK "AppArmor enabled (${profiles} profiles loaded)" "enabled" "enabled"
        else
            report WARN "AppArmor installed but not enabled" "disabled" "enabled" \
                "Boot with apparmor=1 security=apparmor kernel parameters"
        fi
    elif [[ -d /sys/module/apparmor ]]; then
        report WARN "AppArmor module loaded but aa-status not available" "module loaded" "userspace tools" \
            "Install apparmor package"
    else
        report WARN "AppArmor not in use" "absent" "enabled" \
            "Install apparmor and enable on boot for MAC protection"
    fi

    # Core dumps
    local cp
    cp=$(sysctl -n kernel.core_pattern 2>/dev/null || echo "")
    if [[ -z "$cp" || "$cp" == "core" ]]; then
        report WARN "Core dumps enabled (pattern: '${cp:-default}')" "$cp" "disabled" \
            "Disable with 'kernel.core_pattern=|/bin/false' or set Storage=none in /etc/systemd/coredump.conf"
    elif [[ "$cp" == *"systemd-coredump"* ]]; then
        # Check coredump.conf
        local storage="external"  # default
        if [[ -r /etc/systemd/coredump.conf ]]; then
            local s
            s=$(awk -F= '/^Storage=/ {print $2; exit}' /etc/systemd/coredump.conf)
            [[ -n "$s" ]] && storage="$s"
        fi
        case "$storage" in
            none)     report OK   "systemd-coredump Storage=none" "$storage" "none" ;;
            external) report WARN "systemd-coredump stores dumps" "$storage" "none" \
                          "Set Storage=none in /etc/systemd/coredump.conf if not needed for debugging" ;;
            *)        report WARN "systemd-coredump Storage=${storage}" "$storage" "none" ;;
        esac
    elif [[ "$cp" == "|/bin/false"* || "$cp" == "|/dev/null"* ]]; then
        report OK "Core dumps disabled" "$cp" "disabled"
    else
        report WARN "Custom core_pattern: ${cp}" "$cp" "disabled or systemd-coredump with Storage=none"
    fi

    # CVE scan with arch-audit (optional)
    if command -v arch-audit &>/dev/null; then
        local audit_out
        # Format: name | fixed-version | severity | type | CVEs
        audit_out=$(arch-audit -f "%n|%v|%s|%t|%c" 2>/dev/null || true)

        if [[ -z "$audit_out" ]]; then
            report OK "arch-audit: no known vulnerabilities in installed packages" "0 CVEs" "0"
        else
            local upgradable=() pending=()
            local pkg fix sev vtype cves line
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                IFS='|' read -r pkg fix sev vtype cves <<<"$line"
                if [[ -n "$fix" ]]; then
                    upgradable+=("${pkg}|${fix}|${sev}|${vtype}|${cves}")
                else
                    pending+=("${pkg}|${sev}|${vtype}|${cves}")
                fi
            done <<< "$audit_out"

            local total=$(( ${#upgradable[@]} + ${#pending[@]} ))
            local recommend status
            if [[ ${#upgradable[@]} -gt 0 ]]; then
                status=FAIL
                recommend="Run 'sudo pacman -Syu' to apply ${#upgradable[@]} confirmed fix(es). Other entries may also be fixed by pacman even if AVG hasn't confirmed."
            else
                # All pending — user can't act, downgrade to WARN
                status=WARN
                recommend="No actionable fixes (all entries pending upstream). Re-check periodically with 'arch-audit'."
            fi
            report "$status" "arch-audit: ${total} packages with known CVEs (AVG-confirmed fix: ${#upgradable[@]}, no fix-version yet: ${#pending[@]})" \
                "${total} affected" "0" "$recommend"

            # Color severity helper — arch-audit returns "High risk", "Medium risk", "Low risk"
            sev_color() {
                case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in
                    critical*|high*) echo "$RED" ;;
                    medium*)         echo "$YELLOW" ;;
                    low*)            echo "$CYAN" ;;
                    *)               echo "$RESET" ;;
                esac
            }

            local cap=20
            if [[ ${#upgradable[@]} -gt 0 ]]; then
                echo -e "        ${BOLD}${GREEN}Fix version confirmed in AVG${RESET} (${#upgradable[@]}):"
                local i=0 entry sc
                for entry in "${upgradable[@]}"; do
                    IFS='|' read -r pkg fix sev vtype cves <<<"$entry"
                    sc=$(sev_color "$sev")
                    printf "          ${GREEN}↑${RESET} %-18s → %-12s ${sc}[%-8s]${RESET} ${YELLOW}%s${RESET}\n            %s\n" \
                        "$pkg" "$fix" "$sev" "$vtype" "$cves"
                    i=$((i+1))
                    if [[ $i -ge $cap && ${#upgradable[@]} -gt $cap ]]; then
                        echo "          ... and $(( ${#upgradable[@]} - cap )) more"
                        break
                    fi
                done
            fi
            if [[ ${#pending[@]} -gt 0 ]]; then
                echo -e "        ${BOLD}${YELLOW}No fix-version in AVG yet${RESET} (${#pending[@]}) ${CYAN}— verify with 'pacman -Qu <pkg>'${RESET}:"
                local i=0 entry sc
                for entry in "${pending[@]}"; do
                    IFS='|' read -r pkg sev vtype cves <<<"$entry"
                    sc=$(sev_color "$sev")
                    printf "          ${YELLOW}·${RESET} %-18s                 ${sc}[%-8s]${RESET} ${YELLOW}%s${RESET}\n            %s\n" \
                        "$pkg" "$sev" "$vtype" "$cves"
                    i=$((i+1))
                    if [[ $i -ge $cap && ${#pending[@]} -gt $cap ]]; then
                        echo "          ... and $(( ${#pending[@]} - cap )) more"
                        break
                    fi
                done
            fi
        fi
    else
        report SKIP "arch-audit not installed (optional CVE scan)" "" "" \
            "Install with: pacman -S arch-audit (or AUR) for CVE scanning"
    fi
}

# --- Main ---

section "Security hardening audit"

if [[ "$EUID" -ne 0 ]]; then
    warn "Running without root — some checks (PAM, /etc/shadow, sshd_config) will be skipped."
    echo ""
fi

check_ssh
check_kernel
check_perms
check_pam
check_mounts
check_misc

# --- Summary ---

section "Summary"

total_all=0
pass_all=0
fail_all=0
warn_all=0
skip_all=0

for sec in "SSH" "Kernel / sysctl" "File permissions" "PAM / Authentication" "Mounts" "Misc"; do
    local_total="${SECTION_TOTAL[$sec]:-0}"
    local_pass="${SECTION_PASS[$sec]:-0}"
    local_fail="${SECTION_FAIL[$sec]:-0}"
    local_warn="${SECTION_WARN[$sec]:-0}"
    local_skip="${SECTION_SKIP[$sec]:-0}"

    total_all=$((total_all + local_total))
    pass_all=$((pass_all + local_pass))
    fail_all=$((fail_all + local_fail))
    warn_all=$((warn_all + local_warn))
    skip_all=$((skip_all + local_skip))

    printf "    %-22s ${GREEN}%d${RESET}/${BOLD}%d${RESET} passed" "$sec" "$local_pass" "$local_total"
    [[ "$local_fail" -gt 0 ]] && printf "  ${RED}(%d FAIL)${RESET}" "$local_fail"
    [[ "$local_warn" -gt 0 ]] && printf "  ${YELLOW}(%d WARN)${RESET}" "$local_warn"
    [[ "$local_skip" -gt 0 ]] && printf "  ${CYAN}(%d SKIP)${RESET}" "$local_skip"
    echo ""
done

scored=$((total_all - skip_all))
percent=0
[[ "$scored" -gt 0 ]] && percent=$((100 * pass_all / scored))

echo ""
printf "    Total: ${BOLD}%d/%d${RESET} (%d%%)\n" "$pass_all" "$scored" "$percent"
echo ""
echo -e "    ${GREEN}OK:   ${pass_all}${RESET}    ${YELLOW}WARN: ${warn_all}${RESET}    ${RED}FAIL: ${fail_all}${RESET}    ${CYAN}SKIP: ${skip_all}${RESET}"

if [[ "$GLOBAL_FAIL" -eq 1 ]]; then
    echo ""
    warn "FAILs require attention. Re-run with --verbose to see current/expected values."
    exit 1
fi

exit 0
