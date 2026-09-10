#!/usr/bin/env bash
# ============================================================
# aur-gate.sh
# Description : Pre-build security gate for AUR packages. Installed as
#               yay's makepkg (yay --makepkg), it reviews each PKGBUILD
#               before makepkg sources it: maintainer changes, orphans,
#               switches from a signed repo build to the AUR, known-
#               compromised packages and — for updates — only the lines
#               added since the installed version (named npm/bun/pip
#               installs, pipe-to-shell, decoding, install-time network
#               access, new download origins, disabled checksums).
#               Red findings block the build until confirmed.
#               Also works standalone: check, pending, init.
# Dependencies: git, curl, jq, pacman, makepkg; yay (install/pending)
# Compatibility: Arch-based
# ============================================================

SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

REAL_MAKEPKG="${AUR_GATE_MAKEPKG:-/usr/bin/makepkg}"
AUR_URL="${AUR_URL:-https://aur.archlinux.org}"
COMPROMISED_URL="${AUR_GATE_COMPROMISED_URL:-https://raw.githubusercontent.com/lenucksi/aur-malware-check/master/data/campaigns/aur-infected/packages.txt}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cachyos-scripts/aur-gate"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/cachyos-scripts/aur-gate"
# yay captures makepkg's stdout, so the gate talks to the terminal directly.
GATE_IN="${AUR_GATE_IN:-/dev/tty}"
GATE_OUT="${AUR_GATE_OUT:-/dev/tty}"

NEW_PACKAGE_DAYS=30   # younger AUR packages get a warning
LOW_VOTES=5           # new installs below this many votes get a warning
REJECT_TTL=900        # seconds a refusal sticks: yay calls makepkg again after a failure

SEP=$'\037'           # field separator inside RULES and FINDINGS
NL=$'\036'            # line separator inside a finding's detail

# --- Content rules ---
# rule <severity in PKGBUILD/sources> <severity in .install> <ERE> <description>
# "-" disables a rule for that file type. .install scriptlets run as root, hence
# the harsher second column. Each line is reported once, under the first rule it
# matches, so the red rules come first.
RULES=()
rule() { RULES+=("$1${SEP}$2${SEP}$3${SEP}$4"); }

rule RED RED 'atomic-lockfile|js-digest|lockfile-js|nextfile-js' \
    'names a known malicious npm package'
rule RED RED '(npm|pnpm|yarn|bun)[[:space:]]+(install|i|add)[[:space:]]+[@a-zA-Z]' \
    'installs a named npm/bun package (the Atomic Arch vector)'
rule RED RED '(npx|bunx|pnpx|pnpm[[:space:]]+dlx)[[:space:]]+[@a-zA-Z]' \
    'runs a package straight from the npm registry'
rule RED RED 'pip3?[[:space:]]+install[[:space:]]+[a-zA-Z]' \
    'installs a named PyPI package'
rule RED RED '(curl|wget)[^|#]*\|[[:space:]]*(sudo[[:space:]]+)?(ba|da|z|k)?sh([[:space:]]|$)' \
    'pipes a download straight into a shell'
rule RED RED 'base64[[:space:]]+(-d|--decode|-D)|xxd[[:space:]]+-r|openssl[[:space:]]+(enc|base64)[^|]*[[:space:]]-d' \
    'decodes embedded data'
rule RED RED '/dev/(tcp|udp)/' \
    'opens a raw network socket'
rule RED RED 'https?://[0-9]{1,3}(\.[0-9]{1,3}){3}' \
    'downloads from a bare IP address'
rule RED RED 'pastebin\.com|paste\.ee|hastebin|transfer\.sh|0x0\.st|termbin\.com|discordapp\.(com|net)|gofile\.io|bit\.ly|tinyurl\.com' \
    'uses a paste, file-drop or URL-shortener host'
rule YELLOW RED '(curl|wget)[[:space:]]|git[[:space:]]+clone' \
    'network access outside source=()'
rule YELLOW RED 'crontab|/etc/cron|authorized_keys|\.bashrc|\.zshrc|\.profile|/etc/profile|ld\.so\.preload|LD_PRELOAD|\.local/bin|/sys/fs/bpf|bpftool' \
    'touches persistence or preload paths'
rule YELLOW RED 'chmod[[:space:]]+([ugoa]*[+=][rwxt]*s|[2-7][0-7]{3}([^0-9]|$))|install[[:space:]].*-[A-Za-z]*m[[:space:]]*[2-7][0-7]{3}' \
    'sets setuid/setgid bits'
rule YELLOW YELLOW '(npm|pnpm|yarn|bun)[[:space:]]+(install|i|ci)([[:space:]]|$)' \
    'runs npm/bun install scripts at build time'
rule YELLOW YELLOW '(^|[;&|[:space:]])eval[[:space:]]' \
    'uses eval'
rule YELLOW YELLOW '\|[[:space:]]*(sudo[[:space:]]+)?(ba|da|z)?sh([[:space:]]|$)' \
    'pipes into a shell'
rule YELLOW YELLOW '(^|[;&|[:space:]])sudo[[:space:]]' \
    'calls sudo'
rule - YELLOW 'systemctl[[:space:]]+(enable|start|restart)' \
    'enables or starts a service at install time'
rule - YELLOW 'useradd|usermod|groupadd' \
    'creates or modifies users'

# --- Usage ---
usage() {
    cat <<EOF
Usage: aur-gate.sh <command>

Pre-build security gate for AUR packages.

Commands:
  install          Make yay build through aur-gate (yay --save --makepkg) and
                   record the current AUR maintainers as the trusted baseline
  uninstall        Give yay back the plain makepkg
  status           Show whether the gate is active and what it has recorded
  check <pkg>...   Review the latest AUR revision of each package (report only)
  pending          Review every pending AUR update (report only; run by
                   full-upgrade.sh before upgrading)
  init [pkg...]    Record the current AUR maintainers as trusted (default: all
                   installed foreign packages)
  help             Show this help

Anything else is passed to makepkg after the review — that is how yay calls it.

Exit codes (check, pending): 0 nothing found, 1 review, 2 dangerous, 3 error.

Environment:
  AUR_GATE_MAKEPKG   Real makepkg (default: /usr/bin/makepkg)
  AUR_GATE_IN/OUT    Where prompts are read and reports written (default: /dev/tty)
EOF
}

# ============================================================
# Findings
# ============================================================

FINDINGS=()
# add <RED|YELLOW|INFO> <message> [detail lines joined with $NL]
add() { FINDINGS+=("$1${SEP}$2${SEP}${3:-}"); }

# 2 when anything is red, 1 when anything is yellow, else 0.
max_severity() {
    local f s=0
    for f in "${FINDINGS[@]}"; do
        case "${f%%"$SEP"*}" in
            RED)    echo 2; return ;;
            YELLOW) s=1 ;;
        esac
    done
    echo "$s"
}

# ============================================================
# Reading the revision under review
# ============================================================
# T_DIR is the package dir; T_REF a commit to read from, or empty for the
# working tree (wrapper mode, where yay has already merged the new revision and
# the user may have edited it).

T_DIR=""; T_REF=""; PKGFILE="PKGBUILD"

t_read() {
    if [[ -n "$T_REF" ]]; then
        git -C "$T_DIR" show "${T_REF}:$1" 2>/dev/null
    else
        cat -- "${T_DIR}/$1" 2>/dev/null
    fi
}

t_exists() {
    if [[ -n "$T_REF" ]]; then
        git -C "$T_DIR" cat-file -e "${T_REF}:$1" 2>/dev/null
    else
        [[ -f "${T_DIR}/$1" ]]
    fi
}

t_tracked() {
    if [[ -n "$T_REF" ]]; then
        git -C "$T_DIR" ls-tree -r --name-only "$T_REF" 2>/dev/null
    elif [[ -d "${T_DIR}/.git" ]]; then
        git -C "$T_DIR" ls-files 2>/dev/null
    else
        (cd "$T_DIR" && printf '%s\n' *.install) 2>/dev/null
    fi
}

# Package files are untrusted: drop control characters (tab and newline stay)
# so nothing quoted from them can rewrite the terminal around a warning.
clean_text() { LC_ALL=C tr -d '\000-\010\013-\037\177'; }

# --- .SRCINFO helpers (never source the PKGBUILD: that runs its code) ---
srcinfo_version() {
    awk '
        /^[[:space:]]*epoch = / && e == "" { e = $3 }
        /^[[:space:]]*pkgver = / && v == "" { v = $3 }
        /^[[:space:]]*pkgrel = / && r == "" { r = $3 }
        END { if (v != "") print (e != "" ? e ":" : "") v "-" r }'
}

srcinfo_sources() {
    sed -n 's/^[[:space:]]*source\(_[A-Za-z0-9_]*\)\{0,1\} = //p'
}

# One line per download origin: the host, plus the owner on shared forges — a
# new GitHub account matters as much as a new domain.
source_origins() {
    srcinfo_sources | sed 's/^[^:/]*:://' | grep '://' \
        | sed -E 's#^[a-z0-9]+\+##; s#^[a-z]+://##; s#^[^@/]*@##' \
        | awk -F/ '{
            h = tolower($1); sub(/:[0-9]+$/, "", h)
            if (h ~ /^(github\.com|gitlab\.com|codeberg\.org|bitbucket\.org|git\.sr\.ht)$/ && $2 != "")
                h = h "/" tolower($2)
            print h
        }' | sort -u
}

# Remote, non-VCS sources whose checksums are all SKIP: nothing verifies what
# gets downloaded. VCS sources are pinned by commit or tag instead.
unverified_sources() {
    awk '
        /^[[:space:]]*source(_[A-Za-z0-9_]+)? = / {
            k = $1; sub(/^source/, "", k)
            v = $0; sub(/^[^=]*= /, "", v)
            src[k, ++n[k]] = v
            next
        }
        /^[[:space:]]*(md5|sha1|sha224|sha256|sha384|sha512|b2|ck)sums(_[A-Za-z0-9_]+)? = / {
            k = $1; a = k; sub(/sums.*/, "", a); sub(/^[a-z0-9]+sums/, "", k)
            v = $0; sub(/^[^=]*= /, "", v)
            i = ++c[a, k]
            if (v != "SKIP") ok[k, i] = 1
        }
        END {
            for (k in n) for (i = 1; i <= n[k]; i++) {
                s = src[k, i]
                if (s !~ /:\/\//) continue
                if (s ~ /^([^:\/]*::)?(git|svn|hg|bzr|fossil)[+:]/) continue
                if (!((k, i) in ok)) print s
            }
        }'
}

# Files makepkg can run code from: the PKGBUILD, install scriptlets and local
# sources. Patches, licences and keys are left out — judging a patch to upstream
# code is beyond what patterns can do, and they are the main source of noise.
scan_files() {
    local si="$1" f
    {
        printf '%s\n' "$PKGFILE"
        sed -n 's/^[[:space:]]*install = //p' <<< "$si"
        srcinfo_sources <<< "$si" | grep -v '://' | sed 's/^.*:://'
        t_tracked | grep -E '\.install$'
    } | grep -vE '\.(patch|diff|asc|sig|gpg|pgp|png|jpe?g|svg|ico)$|(^|/)(LICEN[CS]E|COPYING)' \
      | sort -u \
      | while IFS= read -r f; do t_exists "$f" && printf '%s\n' "$f"; done
}

install_files() {
    { sed -n 's/^[[:space:]]*install = //p' <<< "$1"; t_tracked | grep -E '\.install$'; } | sort -u
}

# "file<TAB>line<TAB>text" for every line added since BASE.
added_lines() {
    local -a range=("$BASE")
    [[ -n "$T_REF" ]] && range+=("$T_REF")
    (( $# )) || return 0
    git -C "$T_DIR" diff --no-color --no-ext-diff -U0 "${range[@]}" -- "$@" 2>/dev/null | awk '
        /^\+\+\+ / { f = substr($0, 5); sub(/^b\//, "", f); next }
        /^@@ /     { match($0, /\+[0-9]+/); ln = substr($0, RSTART + 1, RLENGTH - 1) + 0; next }
        /^\+/      { print f "\t" ln "\t" substr($0, 2); ln++ }'
}

# "file<TAB>line<TAB>text" for every line of the given text files.
all_lines() {
    local f
    for f in "$@"; do
        t_read "$f" | grep -Iq . || continue
        t_read "$f" | awk -v f="$f" '{ print f "\t" NR "\t" $0 }'
    done
}

# Applies RULES to "file<TAB>line<TAB>text" lines on stdin.
# Prints "SEV<TAB>description<TAB>file:line<TAB>text" for each hit.
scan_content() {
    RULES_ENV="$(printf '%s\n' "${RULES[@]}")" INSTALL_ENV="$1" awk -F'\t' '
        BEGIN {
            n = split(ENVIRON["RULES_ENV"], r, "\n")
            for (i = 1; i <= n; i++) {
                split(r[i], f, "\037")
                sp[i] = f[1]; si[i] = f[2]; re[i] = f[3]; ds[i] = f[4]
            }
            m = split(ENVIRON["INSTALL_ENV"], x, "\n")
            for (i = 1; i <= m; i++) if (x[i] != "") inst[x[i]] = 1
        }
        {
            file = $1; ln = $2; text = $0; sub(/^[^\t]*\t[^\t]*\t/, "", text)
            if (text ~ /^[[:space:]]*#/) next
            # A line that only prints a message (no redirection, pipe or command
            # substitution) cannot run anything: the yellow rules skip it.
            msg = text ~ /^[[:space:]]*(echo|printf|note|msg2?|warning|plain|error|info)[[:space:]]/ && text !~ /[>|`]|\$\(/
            for (i = 1; i <= n; i++) {
                sev = (file in inst) ? si[i] : sp[i]
                if (sev == "-" || (msg && sev == "YELLOW")) continue
                if (text ~ re[i]) { print sev "\t" ds[i] "\t" file ":" ln "\t" text; break }
            }
        }'
}

# Turns scan_content hits into findings: one per rule, with up to 3 example lines.
group_hits() {
    local sev desc loc text key idx
    local -A slot=()
    local -a keys=() counts=() details=()

    while IFS=$'\t' read -r sev desc loc text; do
        key="${sev}${SEP}${desc}"
        if [[ -z "${slot[$key]:-}" ]]; then
            slot[$key]=${#keys[@]}
            keys+=("$key"); counts+=(0); details+=("")
        fi
        idx=${slot[$key]}
        counts[idx]=$(( counts[idx] + 1 ))
        if (( counts[idx] <= 3 )); then
            text="${text#"${text%%[![:space:]]*}"}"
            details[idx]+="${loc}: ${text:0:110}${NL}"
        fi
    done

    for idx in "${!keys[@]}"; do
        (( counts[idx] > 3 )) && details[idx]+="… and $(( counts[idx] - 3 )) more${NL}"
        add "${keys[idx]%%"$SEP"*}" "${keys[idx]#*"$SEP"}" "${details[idx]}"
    done
}

# ============================================================
# State: approvals, refusals, maintainer baseline
# ============================================================

is_approved() {
    awk -F'\t' -v b="$1" -v k="$2" '$1 == b && $2 == k { f = 1 } END { exit !f }' \
        "${STATE_DIR}/approved" 2>/dev/null
}

approved_commit() {
    awk -F'\t' -v b="$1" '$1 == b && $3 != "-" { c = $3 } END { if (c != "") print c }' \
        "${STATE_DIR}/approved" 2>/dev/null
}

record_approval() {
    mkdir -p "$STATE_DIR"
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$(date +%F)" >> "${STATE_DIR}/approved"
}

recently_rejected() {
    awk -F'\t' -v b="$1" -v k="$2" -v t="$(( $(date +%s) - REJECT_TTL ))" \
        '$1 == b && $2 == k && $3 >= t { f = 1 } END { exit !f }' "${STATE_DIR}/rejected" 2>/dev/null
}

record_rejection() {
    mkdir -p "$STATE_DIR"
    printf '%s\t%s\t%s\n' "$1" "$2" "$(date +%s)" >> "${STATE_DIR}/rejected"
}

# Prints "maintainer<TAB>co-maintainers<TAB>date"; "-" means none.
baseline_get() {
    awk -F'\t' -v b="$1" '$1 == b { m = $2; c = $3; d = $4 } END { if (m != "") print m "\t" c "\t" d }' \
        "${STATE_DIR}/maintainers" 2>/dev/null
}

baseline_set() {
    local f="${STATE_DIR}/maintainers"
    mkdir -p "$STATE_DIR"
    {
        [[ -f "$f" ]] && awk -F'\t' -v b="$1" '$1 != b' "$f"
        printf '%s\t%s\t%s\t%s\n' "$1" "${2:--}" "${3:--}" "$(date +%F)"
    } > "${f}.tmp" && mv -f "${f}.tmp" "$f"
}

count_lines() {
    if [[ -s "$1" ]]; then grep -c . "$1"; else echo 0; fi
}

# ============================================================
# Checks
# ============================================================

# AUR RPC info for the given package names (empty on failure).
aur_info() {
    local q
    q=$(jq -rn '$ARGS.positional | map("arg[]=" + @uri) | join("&")' --args "$@")
    curl -gfsS --max-time 15 "${AUR_URL}/rpc/v5/info?${q}" 2>/dev/null
}

# The Atomic Arch package list, refreshed once a day.
compromised_list() {
    local f="${CACHE_DIR}/compromised.txt"
    if [[ ! -s "$f" || -n "$(find "$f" -mmin +1440 2>/dev/null)" ]]; then
        mkdir -p "$CACHE_DIR"
        if curl -fsSL --max-time 20 "$COMPROMISED_URL" -o "${f}.tmp" 2>/dev/null; then
            mv -f "${f}.tmp" "$f"
        else
            rm -f "${f}.tmp"
        fi
    fi
    [[ -s "$f" ]] && grep -vE '^[[:space:]]*(#|$)' "$f" | awk '{ print $1 }'
}

check_compromised() {
    local list n
    list=$(compromised_list)
    if [[ -z "$list" ]]; then
        add INFO "Known-compromised list unavailable — check skipped."
        return
    fi
    for n in "$PKGBASE" "${PKGNAMES[@]}"; do
        if grep -qxF -- "$n" <<< "$list"; then
            add RED "${n} is on the Atomic Arch compromised-package list."
            return
        fi
    done
}

# A package that comes from a signed repo today and would be rebuilt from the
# AUR changes who you are trusting — the AUR entry may have been taken over by
# anyone after the repo dropped it.
check_repo_switch() {
    local n validated
    for n in "${PKGNAMES[@]}"; do
        if pacman -Si "$n" &>/dev/null; then
            add RED "${n} is also in a configured repo — this AUR build would replace it."
            SWITCH=true
            continue
        fi
        validated=$(LC_ALL=C pacman -Qi "$n" 2>/dev/null | sed -n 's/^Validated By *: //p')
        if [[ "$validated" == *Signature* ]]; then
            add RED "${n} is installed from a signed repo build; this replaces it with an AUR build."
            SWITCH=true
        fi
    done
}

check_metadata() {
    local json info votes first age base_m base_c base_d c
    json=$(aur_info "${PKGNAMES[@]}")
    if [[ -z "$json" ]]; then
        add YELLOW "AUR API unreachable — maintainer checks skipped."
        return
    fi
    info=$(jq -c --arg b "$PKGBASE" '[.results[] | select(.PackageBase == $b)][0] // empty' <<< "$json" 2>/dev/null)
    if [[ -z "$info" ]]; then
        add YELLOW "Not found in the AUR (deleted or renamed)."
        return
    fi

    META_OK=true
    CUR_MAINT=$(jq -r '.Maintainer // "-"' <<< "$info")
    CUR_COMAINT=$(jq -r '(.CoMaintainers // []) | sort | join(",")' <<< "$info")
    votes=$(jq -r '.NumVotes // 0' <<< "$info")
    first=$(jq -r '.FirstSubmitted // 0' <<< "$info")
    age=$(( ($(date +%s) - first) / 86400 ))

    [[ "$CUR_MAINT" == "-" ]] && add YELLOW "Orphaned: anyone can adopt it and push the next update."

    IFS=$'\t' read -r base_m base_c base_d < <(baseline_get "$PKGBASE")
    if [[ -n "$base_m" ]]; then
        [[ "$base_c" == "-" ]] && base_c=""
        if [[ "$CUR_MAINT" != "$base_m" && "$CUR_MAINT" != "-" ]]; then
            if [[ ",${base_c}," == *",${CUR_MAINT},"* ]]; then
                add YELLOW "Maintainer changed: ${base_m} → ${CUR_MAINT} (already a co-maintainer)."
            else
                add RED "Maintainer changed: ${base_m} → ${CUR_MAINT} since ${base_d} — this is how Atomic Arch took packages over."
            fi
        fi
        for c in ${CUR_COMAINT//,/ }; do
            [[ ",${base_c}," == *",${c},"* || "$c" == "$base_m" ]] || add YELLOW "New co-maintainer ${c}: can push updates."
        done
    else
        add INFO "No maintainer baseline yet (maintainer: ${CUR_MAINT})."
    fi

    (( age < NEW_PACKAGE_DAYS )) && add YELLOW "Package created ${age} day(s) ago."
    if [[ -z "$INST_VER" ]] && (( votes < LOW_VOTES )); then
        add YELLOW "Only ${votes} vote(s): little community exposure."
    fi
}

# The commit the installed build came from: the last approved commit when it is
# an ancestor of the target, else the oldest commit whose .SRCINFO version equals
# the installed one — the oldest, so a change pushed without a version bump on
# top of it still shows up in the diff.
find_base() {
    local want="$1" rec c ver found=""
    [[ -d "${T_DIR}/.git" ]] || return 1

    rec=$(approved_commit "$PKGBASE")
    if [[ -n "$rec" ]] && git -C "$T_DIR" merge-base --is-ancestor "$rec" "${T_REF:-HEAD}" 2>/dev/null; then
        echo "$rec"
        return 0
    fi

    [[ -n "$want" ]] || return 1
    while read -r c; do
        ver=$(git -C "$T_DIR" show "${c}:.SRCINFO" 2>/dev/null | srcinfo_version)
        if [[ "$ver" == "$want" ]]; then
            found="$c"
        elif [[ -n "$found" ]]; then
            break
        fi
    done < <(git -C "$T_DIR" log --format=%H -n 200 "${T_REF:-HEAD}" -- .SRCINFO 2>/dev/null)
    [[ -n "$found" ]] && echo "$found"
}

# Update-only checks that compare the target with BASE as a whole.
check_update_extras() {
    local si="$1" base_si st f new before after patches
    local -a range=("$BASE")
    [[ -n "$T_REF" ]] && range+=("$T_REF")
    base_si=$(git -C "$T_DIR" show "${BASE}:.SRCINFO" 2>/dev/null)

    # Install scriptlets run as root: any change is worth reading.
    while IFS=$'\t' read -r st f; do
        [[ "$f" == *.install ]] || continue
        if [[ "$st" == A ]]; then
            add YELLOW "Install scriptlet ${f} added — it runs as root."
        else
            add YELLOW "Install scriptlet ${f} changed — it runs as root."
        fi
    done < <(git -C "$T_DIR" diff --name-status "${range[@]}" 2>/dev/null)

    new=$(comm -13 <(source_origins <<< "$base_si") <(source_origins <<< "$si") | paste -sd' ')
    [[ -n "$new" ]] && add YELLOW "Downloads from a new origin: ${new}"

    before=$(unverified_sources <<< "$base_si" | grep -c .)
    after=$(unverified_sources <<< "$si" | grep -c .)
    if (( after > before )); then
        add YELLOW "Checksum verification disabled for a download." \
            "$(unverified_sources <<< "$si" | paste -sd"$NL")"
    fi

    patches=$(git -C "$T_DIR" diff --name-only "${range[@]}" -- '*.patch' '*.diff' 2>/dev/null | paste -sd' ')
    [[ -n "$patches" ]] && add INFO "Patches added or changed (not pattern-checked): ${patches}"
}

check_review_extras() {
    local si="$1" list
    list=$(unverified_sources <<< "$si")
    [[ -n "$list" ]] && add YELLOW "Downloads without checksum verification." "$(paste -sd"$NL" <<< "$list")"
    list=$(source_origins <<< "$si" | paste -sd' ')
    [[ -n "$list" ]] && add INFO "Downloads from: ${list}"
}

# --- Full analysis of T_DIR/T_REF ---
analyze() {
    FINDINGS=(); BASE=""; MODE="review"; SWITCH=false; META_OK=false
    INST_VER=""; CUR_MAINT=""; CUR_COMAINT=""
    PKGBASE=""; PKGNAMES=(); NEW_VER="?"

    local si n v inst
    local -a files=()

    si=$(t_read .SRCINFO | clean_text)
    if [[ -n "$si" ]]; then
        PKGBASE=$(sed -n 's/^pkgbase = //p' <<< "$si" | head -n 1)
        mapfile -t PKGNAMES < <(sed -n 's/^pkgname = //p' <<< "$si")
        NEW_VER=$(srcinfo_version <<< "$si")
    fi
    [[ -n "$PKGBASE" ]] || PKGBASE="${T_DIR##*/}"
    (( ${#PKGNAMES[@]} )) || PKGNAMES=("$PKGBASE")

    for n in "${PKGNAMES[@]}"; do
        v=$(pacman -Q "$n" 2>/dev/null) || continue
        INST_VER="${v#* }"
        break
    done

    check_repo_switch
    check_compromised
    if git -C "$T_DIR" remote get-url origin 2>/dev/null | grep -q 'aur\.archlinux\.org'; then
        check_metadata
    else
        add INFO "Not an AUR clone — maintainer checks skipped."
    fi
    [[ -n "$si" ]] || add YELLOW "No .SRCINFO — source and checksum checks skipped."

    mapfile -t files < <(scan_files "$si")
    inst=$(install_files "$si")

    # A package switching over from a repo was never reviewed as an AUR package,
    # even if an AUR commit happens to carry the same version.
    if [[ -n "$INST_VER" ]] && ! $SWITCH; then
        BASE=$(find_base "$INST_VER")
    fi

    if [[ -n "$BASE" ]]; then
        MODE="update"
        group_hits < <(added_lines "${files[@]}" | clean_text | scan_content "$inst")
        check_update_extras "$si"
    else
        if [[ -n "$INST_VER" ]] && ! $SWITCH; then
            add INFO "No known revision matches the installed ${INST_VER} — reviewing the whole PKGBUILD."
        fi
        group_hits < <(all_lines "${files[@]}" | clean_text | scan_content "$inst")
        check_review_extras "$si"
    fi
}

print_report() {
    local what ver want f sev msg detail line sym

    if [[ "$INST_VER" == "$NEW_VER" ]]; then
        ver="installed ${INST_VER}, no version change"
    else
        ver="${INST_VER} → ${NEW_VER}"
    fi
    if [[ -z "$INST_VER" ]]; then
        what="new install ${NEW_VER}"
    elif [[ "$MODE" == update ]]; then
        what="update, ${ver}"
    else
        what="full review, ${ver}"
    fi

    echo ""
    printf '%b── aur-gate: %s%b (%s)\n' "$BOLD" "$PKGBASE" "$RESET" "$what"
    for want in RED YELLOW INFO; do
        for f in "${FINDINGS[@]}"; do
            IFS="$SEP" read -r sev msg detail <<< "$f"
            [[ "$sev" == "$want" ]] || continue
            case "$sev" in
                RED)    sym="$ERR" ;;
                YELLOW) sym="$WARN" ;;
                *)      sym="$INFO" ;;
            esac
            # Findings quote package files: print them as data, never as escapes.
            printf '  %b %s\n' "$sym" "$msg"
            while IFS= read -r line; do
                [[ -n "$line" ]] && printf '        %s\n' "$line"
            done <<< "${detail//"$NL"/$'\n'}"
        done
    done

    case "$(max_severity)" in
        2) echo -e "  ${RED}${BOLD}Verdict: BLOCK${RESET} — review the red items before building." ;;
        1) echo -e "  ${YELLOW}${BOLD}Verdict: REVIEW${RESET} — nothing clearly malicious, but read the notes." ;;
        *) echo -e "  ${GREEN}${BOLD}Verdict: OK${RESET} — nothing suspicious found." ;;
    esac
}

# ============================================================
# Commands
# ============================================================

need_cmds() {
    local c
    local -a missing=()
    for c in "$@"; do
        command -v "$c" &>/dev/null || missing+=("$c")
    done
    (( ${#missing[@]} == 0 )) && return 0
    error "aur-gate needs: ${missing[*]}"
    return 1
}

# Asks on the terminal and stores the reply in ANSWER. Returns 1 when there is
# no terminal to ask — callers decide whether that means yes or no.
ask() {
    local rc
    ANSWER=""
    { exec 5<"$GATE_IN"; } 2>/dev/null || return 1
    printf '%s' "$1"
    IFS= read -r ANSWER <&5
    rc=$?
    [[ -t 5 ]] || echo ""
    exec 5<&-
    return "$rc"
}

# Hash of every tracked file as it is in the working tree, so an edit made in
# yay's edit menu needs its own approval.
content_key() {
    if [[ -d .git ]]; then
        git ls-files -z | xargs -0 -r sha256sum 2>/dev/null
    else
        sha256sum -- "$PKGFILE" ./*.install 2>/dev/null
    fi | sha256sum | cut -d' ' -f1
}

# --- makepkg wrapper (how yay runs it) ---
wrapper() {
    local arg i key base script="PKGBUILD"
    local -a args=("$@")

    for arg in "$@"; do
        [[ "$arg" == -V || "$arg" == --version ]] && exec "$REAL_MAKEPKG" "$@"
    done
    for (( i = 0; i < ${#args[@]}; i++ )); do
        [[ "${args[i]}" == -p ]] && script="${args[i + 1]:-PKGBUILD}"
    done
    if [[ ! -f "$script" ]]; then
        (( $# )) || { usage; exit 0; }
        exec "$REAL_MAKEPKG" "$@"   # makepkg reports the missing PKGBUILD itself
    fi

    # yay captures makepkg's stdout: report on the terminal, or stderr without one.
    if { exec 4>"$GATE_OUT"; } 2>/dev/null; then
        exec 3>&1 1>&4 4>&-
    else
        exec 3>&1 1>&2
    fi

    T_DIR="$PWD"; T_REF=""; PKGFILE="$script"
    key=$(content_key)
    base=$(sed -n 's/^pkgbase = //p' .SRCINFO 2>/dev/null | head -n 1 | clean_text)
    base="${base:-${PWD##*/}}"

    if is_approved "$base" "$key"; then
        exec 1>&3 3>&-
        exec "$REAL_MAKEPKG" "$@"
    fi
    if recently_rejected "$base" "$key"; then
        error "aur-gate: ${base} was refused — not building it."
        exit 1
    fi
    if ! need_cmds git curl jq; then
        error "Refusing to build ${base} unchecked. Install them, or run: ${SCRIPT_PATH} uninstall"
        exit 1
    fi

    analyze
    print_report

    case "$(max_severity)" in
        2)
            if ! ask "$(printf '  %bBuild %s anyway?%b Type "yes" to continue: ' "$RED" "$base" "$RESET")" \
                    || [[ "$ANSWER" != yes ]]; then
                record_rejection "$base" "$key"
                error "aur-gate: ${base} blocked."
                exit 1
            fi
            ;;
        1)
            if ask "  Continue? [Y/n] " && [[ "$ANSWER" =~ ^[Nn] ]]; then
                record_rejection "$base" "$key"
                error "aur-gate: ${base} skipped."
                exit 1
            fi
            ;;
    esac

    local commit="-"
    [[ -d .git ]] && commit=$(git rev-parse -q --verify HEAD 2>/dev/null || echo -)
    record_approval "$base" "$key" "$commit"
    $META_OK && baseline_set "$PKGBASE" "$CUR_MAINT" "$CUR_COMAINT"

    exec 1>&3 3>&-
    exec "$REAL_MAKEPKG" "$@"
}

TMP_ROOT=""
cleanup_tmp() { [[ -n "$TMP_ROOT" ]] && rm -rf -- "$TMP_ROOT"; }

# Points T_DIR/T_REF at the newest AUR revision of NAME: the helper's clone after
# a fetch (its working tree is left alone) or a fresh clone. Sets T_BASE.
prepare_target() {
    local name="$1" d
    T_DIR=""; T_REF=""; PKGFILE="PKGBUILD"
    T_BASE=$(aur_info "$name" | jq -r '.results[0].PackageBase // empty' 2>/dev/null)
    T_BASE="${T_BASE:-$name}"

    while IFS= read -r d; do
        [[ -d "${d}/${T_BASE}/.git" ]] && { T_DIR="${d}/${T_BASE}"; break; }
    done < <(aur_cache_dirs)

    if [[ -n "$T_DIR" ]]; then
        timeout 30 git -C "$T_DIR" fetch -q origin 2>/dev/null \
            || warn "Could not fetch ${T_BASE}; reviewing the last fetched revision."
        T_REF=$(git -C "$T_DIR" rev-parse -q --verify '@{u}' 2>/dev/null \
            || git -C "$T_DIR" rev-parse -q --verify HEAD)
        return 0
    fi

    [[ -n "$TMP_ROOT" ]] || TMP_ROOT=$(mktemp -d)
    if ! timeout 60 git clone -q "${AUR_URL}/${T_BASE}.git" "${TMP_ROOT}/${T_BASE}" 2>/dev/null; then
        error "Could not clone ${T_BASE} from the AUR."
        return 1
    fi
    T_DIR="${TMP_ROOT}/${T_BASE}"
    T_REF=$(git -C "$T_DIR" rev-parse -q --verify HEAD 2>/dev/null)
    if [[ -z "$T_REF" ]]; then
        error "${name}: not found in the AUR."
        return 1
    fi
}

cmd_check() {
    (( $# )) || { usage >&2; return 3; }
    need_cmds git curl jq || return 3
    trap cleanup_tmp EXIT

    local name s worst=0 errors=0
    for name in "$@"; do
        prepare_target "$name" || { errors=1; continue; }
        analyze
        print_report
        s=$(max_severity)
        (( s > worst )) && worst=$s
    done
    (( worst == 2 )) && return 2
    (( errors )) && return 3
    return "$worst"
}

cmd_pending() {
    local helper name s worst=0 errors=0
    local -a names=()
    local -A seen=()

    helper=$(command -v yay || command -v paru) || { info "No AUR helper found — nothing to review."; return 0; }
    need_cmds git curl jq || return 3
    trap cleanup_tmp EXIT

    mapfile -t names < <("$helper" -Qua 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | awk 'NF >= 3 { print $1 }')
    if (( ${#names[@]} == 0 )); then
        ok "No pending AUR updates."
        return 0
    fi

    info "Reviewing ${#names[@]} pending AUR update(s)…"
    for name in "${names[@]}"; do
        prepare_target "$name" || { errors=1; continue; }
        [[ -n "${seen[$T_BASE]:-}" ]] && continue   # split package already reviewed
        seen[$T_BASE]=1
        analyze
        s=$(max_severity)
        if (( s == 0 )); then
            printf '%b %s: %s → %s — nothing suspicious.\n' "$OK" "$PKGBASE" "${INST_VER:-new}" "$NEW_VER"
        else
            print_report
        fi
        (( s > worst )) && worst=$s
    done
    (( worst == 2 )) && return 2
    (( errors )) && return 3
    return "$worst"
}

cmd_init() {
    local i json base maint co recorded=0
    local -a names=("$@")
    local -A seen=()

    need_cmds curl jq || return 3
    (( ${#names[@]} )) || mapfile -t names < <(pacman -Qmq)
    if (( ${#names[@]} == 0 )); then
        info "No foreign packages installed."
        return 0
    fi

    for (( i = 0; i < ${#names[@]}; i += 100 )); do
        json=$(aur_info "${names[@]:i:100}")
        if [[ -z "$json" ]]; then
            error "AUR API unreachable."
            return 3
        fi
        while IFS=$'\t' read -r base maint co; do
            [[ -n "${seen[$base]:-}" ]] && continue
            seen[$base]=1
            baseline_set "$base" "$maint" "$co"
            recorded=$(( recorded + 1 ))
        done < <(jq -r '.results[] | [.PackageBase, (.Maintainer // "-"),
                        ((.CoMaintainers // []) | sort | join(","))] | @tsv' <<< "$json")
    done
    ok "Recorded the current maintainer of ${recorded} AUR package base(s) as trusted."
}

cmd_install() {
    if ! command -v yay &>/dev/null; then
        info "yay not found. For paru, add under [bin] in paru.conf:  Makepkg = ${SCRIPT_PATH}"
        return 1
    fi
    need_cmds git curl jq || return 1
    # -V keeps yay from running its default operation (a full -Syu) after saving.
    if ! yay -V --save --makepkg "$SCRIPT_PATH" >/dev/null; then
        error "Could not update yay's configuration."
        return 1
    fi
    ok "yay now builds AUR packages through aur-gate."
    info "Recording the current AUR maintainers as the trusted baseline…"
    cmd_init
    info "yay stores this path: re-run 'install' if you move the repo."
    info "Undo with: ${SCRIPT_PATH} uninstall"
}

cmd_uninstall() {
    command -v yay &>/dev/null || { info "yay not found — nothing to undo."; return 0; }
    yay -V --save --makepkg makepkg >/dev/null && ok "yay uses the plain makepkg again."
}

cmd_status() {
    local bin=""
    command -v yay &>/dev/null && bin=$(yay -Pg 2>/dev/null | jq -r '.makepkgbin // empty' 2>/dev/null)
    if [[ "$bin" == "$SCRIPT_PATH" ]]; then
        ok "Active: yay builds through ${bin}"
    else
        warn "Not active: yay's makepkg is '${bin:-unknown}'. Enable with: ${SCRIPT_PATH} install"
    fi
    info "Maintainer baseline: $(count_lines "${STATE_DIR}/maintainers") package base(s)"
    info "Approved builds:     $(count_lines "${STATE_DIR}/approved")"
    info "State:               ${STATE_DIR}"
}

# --- Main ---
case "${1:-}" in
    install)        cmd_install ;;
    uninstall)      cmd_uninstall ;;
    status)         cmd_status ;;
    check)          shift; cmd_check "$@"; exit $? ;;
    pending)        cmd_pending; exit $? ;;
    init)           shift; cmd_init "$@"; exit $? ;;
    help|-h|--help) usage ;;
    *)              wrapper "$@" ;;
esac
