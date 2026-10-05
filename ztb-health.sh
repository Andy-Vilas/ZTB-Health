#!/usr/bin/env bash
#
# ztb-health.sh — Zero Trust Branch appliance health check
#
# Connects to a ZTB gateway's operator CLI (zcli) over SSH, runs a set of
# read-only commands, and prints a PASS/WARN/FAIL report.
#
# ---------------------------------------------------------------------------
# NOT AN OFFICIAL ZSCALER TOOL
#
#   This script is in development and is a personal, unofficial project. It
#   is NOT a Zscaler product, is NOT endorsed, maintained or supported by
#   Zscaler in any way, and carries no warranty of any kind. Zscaler Support
#   will not accept cases arising from its use. You run it at your own risk
#   and are responsible for validating its output against the appliance.
# ---------------------------------------------------------------------------
#
# Read-only: every command issued is a show/query, and a deny-list (see
# MUTATING-COMMAND GUARD) aborts before connecting if a state-changing
# command is ever added to the list.
#
# ---------------------------------------------------------------------------
# WHY A SINGLE INTERACTIVE SESSION
#
#   zcli applies a *narrower* allowlist to non-interactive execution
#   (ssh host "cmd"). uptime, ps, top and ifconfig are all refused with
#   'command "X" is not permitted for non-interactive execution', and every
#   fallback is sealed too: /proc/{uptime,loadavg} are outside the diagnostic
#   path sandbox, 'docker stats' is not permitted, and journalctl
#   --list-boots is filtered. Non-interactive mode also runs exactly one
#   command per connection — ';' and newlines do not chain.
#
#   Piping a command list into one interactive session avoids both limits:
#   one login, full command set. The cost is terminal echo and ANSI redraw
#   in the transcript, which scrub() removes.
#
# HOW THE PASSWORD IS HANDLED
#
#   ssh reads the password from /dev/tty, not from stdin — so when a terminal
#   is present we let ssh prompt directly while the command list flows in on
#   stdin. Nothing is written to disk and no helper is needed, which is also
#   what makes this path work on macOS.
#
#   Unattended runs (no terminal) have no such luxury. Key auth is not an
#   option — the appliance is locked down and zcli has no way to install an
#   authorized key — so a password must be delivered by one of:
#     - sshpass                 (if installed)
#     - setsid + SSH_ASKPASS    (Linux, OpenSSH 8.4+; password written to a
#                                0600 file in a 0700 dir, removed on exit)
#   Neither exists on Windows Git Bash, so unattended runs are Linux/macOS.
#
# REQUIREMENTS
#   bash 3.2+, OpenSSH, awk, sed, grep. GNU coreutils NOT required.
#   Tested against ZTB OS 8.1.2 (b226) and 8.1.2-P1 (b323).
# ---------------------------------------------------------------------------
set -o pipefail

VERSION="1.5"
HOST="${ZTB_HOST:-}"
USER_NAME=""
PASSWORD=""
CRED_FILE=""
USE_COLOR="auto"
VERBOSE=0
KEEP_TRANSCRIPT=0
EVIDENCE=0
CONNECT_TIMEOUT=20
SESSION_TIMEOUT=180
CERT_WARN_DAYS=90
TUNNEL_STATS=1        # --no-tunnel-stats turns off the byte-counter sampling
MAX_ROUTES=25         # per-protocol route lines printed; 0 = no limit

usage() {
    cat <<USAGE
ztb-health.sh v$VERSION — Zero Trust Branch health check

In development. Unofficial and NOT supported by Zscaler — no warranty;
validate anything it reports before acting on it.

Usage: $0 [-H <appliance-address>] [options]

With no arguments it asks for the address, username and password.

  -H, --host HOST         appliance management address (prompted if omitted,
                          or set \$ZTB_HOST)
  -u, --user USER         login user               (prompted, default: admin)
  -c, --credentials FILE  read 'user X' / 'password Y' from FILE
                          (unattended use only — prefer the interactive prompt)
  -t, --timeout SECS      session timeout          (default: $SESSION_TIMEOUT)
      --cert-days N       warn on certs expiring within N days (default: $CERT_WARN_DAYS)
      --no-tunnel-stats   skip the per-tunnel byte-counter sampling and the
                          judgements drawn from it (idle / one-way / RX errors).
                          The control-plane tunnel checks — BGP adjacency, IPsec
                          SAs, ZPA broker sessions, WireGuard underlay — still
                          run, as does the kernel overlay-interface check.
                          Also drops two 'show ip -s link' calls from the session.
      --max-routes N      max route lines listed per protocol (default: $MAX_ROUTES,
                          0 = list everything)
      --no-color          plain text output
      --evidence          append the raw command output behind the provisional
                          checks, for review
      --keep-transcript   leave the raw CLI transcript on disk for inspection
  -v, --verbose           show progress detail
  -h, --help              this message

Authentication:
  With a terminal, ssh prompts for the password directly and nothing is
  stored. Unattended runs need \$ZTB_PASSWORD or --credentials; SSH keys are
  not available on this appliance.

Examples:
  $0                                 # prompts for everything
  $0 -H 192.0.2.10
  ZTB_HOST=192.0.2.10 $0
  $0 -H 192.0.2.10 --no-color > branch-health.txt
  $0 -H 192.0.2.10 --no-tunnel-stats     # skip tunnel counters
  $0 -H 192.0.2.10 --max-routes 0        # full routing inventory

Exit: 0 all pass, 1 warnings only, 2 one or more failures, 3 could not connect.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        -H|--host)         HOST="$2"; shift 2 ;;
        -u|--user)         USER_NAME="$2"; shift 2 ;;
        -c|--credentials)  CRED_FILE="$2"; shift 2 ;;
        -t|--timeout)      SESSION_TIMEOUT="$2"; shift 2 ;;
        --cert-days)       CERT_WARN_DAYS="$2"; shift 2 ;;
        --no-tunnel-stats) TUNNEL_STATS=0; shift ;;
        --max-routes)      MAX_ROUTES="$2"; shift 2 ;;
        --no-color)        USE_COLOR="never"; shift ;;
        --keep-transcript) KEEP_TRANSCRIPT=1; shift ;;
        --evidence)        EVIDENCE=1; shift ;;
        -v|--verbose)      VERBOSE=1; shift ;;
        -h|--help)         usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 64 ;;
    esac
done

case "$MAX_ROUTES" in
    ''|*[!0-9]*) echo "--max-routes wants a non-negative integer" >&2; exit 64 ;;
esac

# ---------------------------------------------------------------- colours ---
if [ "$USE_COLOR" = "never" ] || { [ "$USE_COLOR" = "auto" ] && [ ! -t 1 ]; }; then
    C_RST=""; C_B=""; C_DIM=""; C_GRN=""; C_YEL=""; C_RED=""; C_CYN=""; C_MAG=""
else
    C_RST=$'\033[0m'; C_B=$'\033[1m'; C_DIM=$'\033[2m'
    C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_RED=$'\033[31m'
    C_CYN=$'\033[36m'; C_MAG=$'\033[35m'
fi

N_PASS=0; N_WARN=0; N_FAIL=0; N_INFO=0; N_PROV=0

# ------------------------------------------------- interactive parameters ---
# Anything not supplied on the command line is asked for, provided there is a
# terminal to ask on. The password is deliberately NOT prompted for here —
# ssh prompts for it itself on /dev/tty, which keeps it off disk and out of
# the process table. See "HOW THE PASSWORD IS HANDLED" in the header.
# Gate on stdin only: prompts are written to stderr and ssh reads the
# password from /dev/tty, so redirecting stdout (> report.txt) must not
# disable prompting.
INTERACTIVE=0
[ -t 0 ] && INTERACTIVE=1

ask() {   # ask <prompt> <default>  -> echoes the answer
    local prompt="$1" default="$2" reply=""
    if [ -n "$default" ]; then
        printf '%s%s [%s]: %s' "$C_B" "$prompt" "$default" "$C_RST" >&2
    else
        printf '%s%s: %s' "$C_B" "$prompt" "$C_RST" >&2
    fi
    IFS= read -r reply || reply=""
    reply=$(printf '%s' "$reply" | tr -d '[:space:]')
    [ -z "$reply" ] && reply="$default"
    printf '%s' "$reply"
}

if [ -z "$HOST" ]; then
    if [ "$INTERACTIVE" = "1" ]; then
        attempt=0
        while [ -z "$HOST" ] && [ "$attempt" -lt 3 ]; do
            HOST=$(ask "Appliance management address" "")
            attempt=$((attempt + 1))
        done
    fi
    if [ -z "$HOST" ]; then
        echo "No appliance address given. Use -H <address> or set \$ZTB_HOST." >&2
        echo "Try '$0 --help'." >&2
        exit 64
    fi
fi



# emit <PASS|WARN|FAIL|INFO> <label> <detail> [continuation...]
emit() {
    local st="$1" label="$2" detail="$3"; shift 3
    local tag colour
    case "$st" in
        PASS) tag="PASS"; colour="$C_GRN"; N_PASS=$((N_PASS+1)) ;;
        WARN) tag="WARN"; colour="$C_YEL"; N_WARN=$((N_WARN+1)) ;;
        FAIL) tag="FAIL"; colour="$C_RED"; N_FAIL=$((N_FAIL+1)) ;;
        INFO) tag="INFO"; colour="$C_CYN"; N_INFO=$((N_INFO+1)) ;;
        # PROV = observed, deliberately NOT scored. The semantics are not yet
        # confirmed, so turning it into PASS/FAIL would invent a judgement.
        # Never affects the exit code.
        PROV) tag="PROV"; colour="$C_MAG"; N_PROV=$((N_PROV+1)) ;;
    esac
    printf '  %s[%s]%s %-26s %s\n' "$colour" "$tag" "$C_RST" "$label" "$detail"
    local extra
    for extra in "$@"; do
        printf '  %-6s %-26s %s%s%s\n' "" "" "$C_DIM" "$extra" "$C_RST"
    done
}

section() { printf '\n%s%s%s\n' "$C_B$C_MAG" "$1" "$C_RST"; }

# emit_lines <PASS|WARN|FAIL|INFO> <label> <detail> [fixed-line...]  — list on stdin
# Same as emit(), but the continuation lines are read from stdin and capped at
# $MAX_ROUTES so a gateway holding a full BGP table cannot flood the report.
# Any argument after <detail> is a fixed line (a column header, a caveat) that
# prints ahead of the list and does NOT count against the cap — otherwise
# --max-routes 1 would spend its whole budget on the header.
# MUST be fed with a here-string, never a pipe: a pipe would run emit() in a
# subshell and the PASS/WARN/FAIL tallies would be lost.
emit_lines() {
    local st="$1" label="$2" detail="$3"; shift 3
    local line n=0 total=0
    local extra=("$@")
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        total=$((total + 1))
        if [ "$MAX_ROUTES" -eq 0 ] || [ "$n" -lt "$MAX_ROUTES" ]; then
            extra+=("$line"); n=$((n + 1))
        fi
    done
    [ "$total" -gt "$n" ] && \
        extra+=("... and $((total - n)) more — re-run with --max-routes 0")
    emit "$st" "$label" "$detail" "${extra[@]}"
}

# ---------------------------------------------------------------- commands ---
# Every entry MUST be read-only. Guarded below.
COMMANDS=(
    "show ip -s link"
    "show version"
    "show configuration"
    "show device-identifiers"
    "show appliance-status"
    "show system services"
    "software version"
    "software show"
    "show ztp activation-state"
    "uptime"
    "top -b -n 1"
    "docker info"
    "docker ps"
    "show ip -br link"
    "show ip -br addr"
    "show ip route"
    "show ip neigh"
    "vyos show ip route vrf all"
    "vyos show ip ospf vrf all neighbor"
    "show ip xfrm policy"
    "show zpa config"
    "show zpa certificates"
    "show zpa ip"
    "show zpa fqdn"
    "show zpa appsegments"
    "show dnsproxy show metrics"
    "show iptables"
    "show iptables -t nat"
    "dhcpcli -a get-mastership"
    "show ip xfrm state"
    "vyos show bgp vrf all summary"
    "conntrack -L | include dport=443"
    "conntrack -L | include 51820"
    "journalctl -n 200"
    "show ip -s link"
)

# 'show ip -s link' appears twice on purpose — once at each end of the session —
# so the gap between the two samples is a free measurement window. It exists
# solely for the tunnel counters, so --no-tunnel-stats removes both copies and
# the session gets two commands shorter.
if [ "$TUNNEL_STATS" = "0" ]; then
    _keep=()
    for _c in "${COMMANDS[@]}"; do
        [ "$_c" = "show ip -s link" ] && continue
        _keep+=("$_c")
    done
    COMMANDS=("${_keep[@]}")
    unset _keep
fi

# MUTATING-COMMAND GUARD -------------------------------------------------
# A typo turning a query into 'run reboot' would be unrecoverable over SSH,
# so the command list is validated against a deny-list before anything is
# sent. zcli itself would also refuse some of these, but not all.
for _c in "${COMMANDS[@]}"; do
    case "$_c" in
        run\ *|config\ *|clear\ web-proxy|software\ install*|software\ activate*|\
        software\ mkdefault*|software\ remove*|*set-debug-level*|zscaler-console*)
            echo "REFUSING: mutating command in list: $_c" >&2; exit 64 ;;
    esac
done
unset _c

# ------------------------------------------------------------ credentials ---
# A credentials file is NEVER picked up implicitly — it must be named with
# -c. An earlier version defaulted to ./ssh.txt, which quietly turns any
# copy of this directory into a credential leak.
AUTH_MODE=""          # tty | password | none
if [ -n "$CRED_FILE" ]; then
    if [ ! -r "$CRED_FILE" ]; then
        echo "Cannot read credentials file: $CRED_FILE" >&2; exit 64
    fi
    case "$(ls -l "$CRED_FILE" 2>/dev/null | cut -c1-10)" in
        *r--r--*|*rw-rw-*|*r--*r--) 
            echo "Warning: $CRED_FILE is readable by other users." >&2 ;;
    esac
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"          # such files often arrive from Windows (CRLF)
        case "$line" in
            user\ *)     [ -z "$USER_NAME" ] && USER_NAME="${line#user }" ;;
            password\ *) PASSWORD="${line#password }" ;;
        esac
    done < "$CRED_FILE"
fi
if [ -z "$USER_NAME" ] && [ "$INTERACTIVE" = "1" ]; then
    USER_NAME=$(ask "Username" "admin")
fi
[ -z "$USER_NAME" ] && USER_NAME="admin"
[ -z "$PASSWORD" ] && PASSWORD="${ZTB_PASSWORD:-}"

if [ -n "$PASSWORD" ]; then
    AUTH_MODE="password"
elif [ -t 0 ]; then
    # ssh reads the password from /dev/tty, so it can prompt while stdin
    # carries the command list. Nothing touches disk. Works on macOS.
    AUTH_MODE="tty"
else
    # No terminal and no password. There is nothing left to try: the
    # appliance offers no usable key auth, so this run will fail. ssh is
    # still invoked so the failure comes from the server with a real
    # message rather than from a guess here.
    AUTH_MODE="none"
fi

# --------------------------------------------------------------- workspace ---
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ztb-health.XXXXXX")" || exit 3
chmod 700 "$WORK"
cleanup() {
    rm -f "$WORK/pw" "$WORK/askpass.sh" 2>/dev/null
    if [ "$KEEP_TRANSCRIPT" = "1" ] && [ -f "$WORK/transcript.txt" ]; then
        printf '\n%sTranscript kept: %s%s\n' "$C_DIM" "$WORK/transcript.txt" "$C_RST"
    else
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT INT TERM

# ------------------------------------------------- portability shims ---
# GNU coreutils are not assumed: 'timeout' and 'setsid' are used only if
# present, and all date arithmetic is done in awk (see days_until()).
TIMEOUT_CMD=""
if command -v timeout  >/dev/null 2>&1; then TIMEOUT_CMD="timeout"
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_CMD="gtimeout"; fi
# 'timeout' runs its child in a NEW PROCESS GROUP. A child that then reads
# /dev/tty — ssh asking for a password — is a background process group and
# is stopped by SIGTTIN: the prompt never appears and the run hangs until
# the timeout fires. --foreground keeps the child in our process group.
TIMEOUT_FG=""
if [ -n "$TIMEOUT_CMD" ] && $TIMEOUT_CMD --foreground 1 true >/dev/null 2>&1; then
    TIMEOUT_FG="$TIMEOUT_CMD --foreground"
fi
HAVE_SETSID=0;  command -v setsid  >/dev/null 2>&1 && HAVE_SETSID=1
HAVE_SSHPASS=0; command -v sshpass >/dev/null 2>&1 && HAVE_SSHPASS=1

# Literal control characters, so the sed expressions below need no \x
# escapes (those are a GNU sed extension and absent on BSD/macOS sed).
ESC=$(printf '\033'); BEL=$(printf '\007'); BS=$(printf '\b'); CR=$(printf '\r')

# Decide how the password will be delivered for unattended runs.
if [ "$AUTH_MODE" = "password" ]; then
    if [ "$HAVE_SSHPASS" = "1" ]; then
        AUTH_MODE="sshpass"
        printf '%s\n' "$PASSWORD" > "$WORK/pw"; chmod 600 "$WORK/pw"
    elif [ "$HAVE_SETSID" = "1" ]; then
        AUTH_MODE="askpass"
        printf '%s\n' "$PASSWORD" > "$WORK/pw"; chmod 600 "$WORK/pw"
        printf '#!/bin/sh\ncat %s/pw\n' "$WORK" > "$WORK/askpass.sh"
        chmod 700 "$WORK/askpass.sh"
    else
        echo "A password was supplied but this system has neither sshpass nor setsid," >&2
        echo "so it cannot be delivered non-interactively." >&2
        echo "Run from a terminal (the password will be prompted for), or install" >&2
        echo "sshpass. SSH keys are not available on this appliance." >&2
        exit 3
    fi
fi
PASSWORD=""

# ----------------------------------------------------------------- session ---
# Strip ANSI CSI/OSC sequences, split on CR, then collapse each line-redraw
# (everything before the last backspace) so only the settled text survives.
scrub() {
    # Strip ANSI CSI/OSC sequences, split on CR, then collapse each line
    # redraw (everything before the last backspace) so only settled text
    # survives. Uses literal control chars for BSD/macOS sed compatibility.
    sed -e "s/${ESC}\[[0-9;?]*[A-Za-z]//g" \
        -e "s/${ESC}\][^${BEL}]*${BEL}//g" \
        -e "s/${ESC}[()][B0]//g" \
        | sed -e "s/${CR}$//" \
        | tr '\r' '\n' \
        | sed -e "s/.*${BS}//" \
        | cat -s
}

run_session() {
    local script="$WORK/cmds.in"
    : > "$script"
    local c
    for c in "${COMMANDS[@]}"; do printf '%s\n' "$c" >> "$script"; done
    printf 'exit\n' >> "$script"

    # -tt forces a pty so zcli behaves as an interactive session.
    set -- -tt \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$WORK/known_hosts" \
        -o ConnectTimeout="$CONNECT_TIMEOUT" \
        -o LogLevel=ERROR
    case "$AUTH_MODE" in
        none) set -- "$@" -o BatchMode=yes -o PasswordAuthentication=no ;;
        *)   set -- "$@" -o NumberOfPasswordPrompts=1 ;;
    esac

    # Only the tty path reads /dev/tty, so only it needs --foreground. If this
    # timeout cannot do that, run without one rather than hang at an invisible
    # password prompt (ssh's own ConnectTimeout still applies).
    local TO=""
    if [ "$AUTH_MODE" = "tty" ]; then
        [ -n "$TIMEOUT_FG" ] && TO="$TIMEOUT_FG $SESSION_TIMEOUT"
    elif [ -n "$TIMEOUT_CMD" ]; then
        TO="$TIMEOUT_CMD $SESSION_TIMEOUT"
    fi

    case "$AUTH_MODE" in
        tty)
            # ssh prompts on /dev/tty; the command list arrives on stdin.
            [ "$VERBOSE" = "1" ] && printf '%susing terminal password prompt%s\n' "$C_DIM" "$C_RST" >&2
            $TO ssh "$@" "$USER_NAME@$HOST" < "$script" 2>&1 | scrub > "$WORK/transcript.txt"
            ;;
        sshpass)
            SSHPASS="$(cat "$WORK/pw" 2>/dev/null)" \
            $TO sshpass -e ssh "$@" -o PreferredAuthentications=password \
                -o PubkeyAuthentication=no "$USER_NAME@$HOST" \
                < "$script" 2>&1 | scrub > "$WORK/transcript.txt"
            ;;
        askpass)
            SSH_ASKPASS="$WORK/askpass.sh" SSH_ASKPASS_REQUIRE=force DISPLAY="${DISPLAY:-:0}" \
            setsid -w $TO ssh "$@" -o PreferredAuthentications=password \
                -o PubkeyAuthentication=no "$USER_NAME@$HOST" \
                < "$script" 2>&1 | scrub > "$WORK/transcript.txt"
            ;;
        none)
            $TO ssh "$@" "$USER_NAME@$HOST" < "$script" 2>&1 | scrub > "$WORK/transcript.txt"
            ;;
    esac
    return $?
}

# Split the transcript into one file per command, keyed by the echoed
# '<gateway># <command>' prompt line.
split_blocks() {
    awk -v dir="$WORK" '
        /^[A-Za-z0-9][A-Za-z0-9._-]*# / {
            cmd = substr($0, index($0, "# ") + 2)
            gsub(/[ \t]+$/, "", cmd)
            if (cmd == "" ) next
            n++
            file = sprintf("%s/blk_%03d", dir, n)
            print cmd > (dir "/manifest")
            printf "%d\t%s\n", n, cmd >> (dir "/index")
            current = file
            next
        }
        current { print >> current }
    ' "$WORK/transcript.txt"
}

# block <command> -> stdout
block() {
    local want="$1" idx
    idx=$(awk -F'\t' -v w="$want" '$2 == w {print $1; exit}' "$WORK/index" 2>/dev/null)
    [ -n "$idx" ] && cat "$WORK/$(printf 'blk_%03d' "$idx")" 2>/dev/null
}

# block_last <command> -> the LAST block for a command issued more than once
# (the counter sample is taken at both ends of the session, so the gap between
# them is the whole run — a free measurement window).
block_last() {
    local want="$1" idx
    idx=$(awk -F'\t' -v w="$want" '$2 == w {i=$1} END {print i}' "$WORK/index" 2>/dev/null)
    [ -n "$idx" ] && cat "$WORK/$(printf 'blk_%03d' "$idx")" 2>/dev/null
}

# field <block-command> <regex-label> -> value after the colon
field() {
    block "$1" | grep -m1 -E "$2" | sed 's/^[^:]*:[[:space:]]*//' | sed 's/[[:space:]]*$//'
}


# days_until "<Weekday>, <Month> <D>, <YYYY> at <time> <TZ>" -> integer days
# GNU 'date -d' cannot be assumed (BSD/macOS date has no such flag), so the
# civil-date arithmetic is done in awk instead.
days_until() {
    awk -v s="$1" -v today="$(date -u '+%Y %m %d')" '
        function dfc(y, m, d,   era, yoe, doy, doe) {
            if (m <= 2) y--
            era = int((y >= 0 ? y : y - 399) / 400)
            yoe = y - era * 400
            doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
            doe = yoe * 365 + int(yoe/4) - int(yoe/100) + doy
            return era * 146097 + doe - 719468
        }
        BEGIN {
            split("January February March April May June July August " \
                  "September October November December", mn, " ")
            for (i = 1; i <= 12; i++) M[mn[i]] = i
            # tolerate a leading weekday and any trailing time/zone text
            if (match(s, /[A-Z][a-z]+ [0-9]{1,2}, [0-9]{4}/) == 0) { print "NA"; exit }
            part = substr(s, RSTART, RLENGTH)
            split(part, a, /[ ,]+/)
            if (!(a[1] in M)) { print "NA"; exit }
            split(today, t, " ")
            print dfc(a[3] + 0, M[a[1]], a[2] + 0) - dfc(t[1] + 0, t[2] + 0, t[3] + 0)
        }'
}

# ================================================================= COLLECT ===
printf '%sZTB health check%s  connecting to %s@%s ...\n' "$C_B" "$C_RST" "$USER_NAME" "$HOST" >&2
run_session
rc=$?
# Turn an ssh/zcli failure into a specific, actionable message rather than a
# generic parse error — these are the cases seen in testing.
diagnose_failure() {
    local t="$WORK/transcript.txt"
    if [ ! -s "$t" ]; then
        echo "No response from $HOST (ssh rc=$rc) — connection timed out." >&2
    elif grep -qi 'permission denied\|authentication fail' "$t"; then
        if [ "$AUTH_MODE" = "none" ]; then
            echo "No password was supplied and there is no terminal to prompt on," >&2
            echo "so $HOST had nothing to authenticate with." >&2
            echo "Supply one via \$ZTB_PASSWORD or --credentials, or run from a terminal." >&2
        else
            echo "Authentication failed for $USER_NAME@$HOST — check the password." >&2
        fi
    elif grep -qi 'no route to host\|network is unreachable' "$t"; then
        echo "$HOST is unreachable — no route to host." >&2
    elif grep -qi 'connection refused' "$t"; then
        echo "$HOST refused the connection — is SSH listening on port 22?" >&2
    elif grep -qi 'connection timed out\|operation timed out' "$t"; then
        echo "Connection to $HOST timed out after ${CONNECT_TIMEOUT}s." >&2
    elif grep -qi 'host key verification failed' "$t"; then
        echo "Host key verification failed for $HOST." >&2
    elif grep -qi 'invalid characters' "$t"; then
        echo "SSH rejected the username '$USER_NAME' — check the credentials file for stray characters." >&2
    else
        echo "Connected to $HOST but the CLI transcript could not be parsed." >&2
        echo "The prompt format may differ on this build. First lines received:" >&2
        head -3 "$t" | sed 's/^/    /' >&2
    fi
    echo "Re-run with --keep-transcript to inspect the raw capture." >&2
}

if [ ! -s "$WORK/transcript.txt" ]; then
    diagnose_failure
    exit 3
fi
split_blocks
if [ ! -s "$WORK/index" ]; then
    diagnose_failure
    exit 3
fi
if [ "$VERBOSE" = "1" ]; then
    printf '%sCollected %s command blocks%s\n' "$C_DIM" "$(wc -l < "$WORK/index")" "$C_RST" >&2
fi

# Guard against a truncated session (timeout mid-way)
COLLECTED=$(wc -l < "$WORK/index")
EXPECTED=$(( ${#COMMANDS[@]} + 1 ))   # +1 for 'exit'
if [ "$COLLECTED" -lt "$EXPECTED" ]; then
    TRUNCATED=1
else
    TRUNCATED=0
fi

# ================================================================== HEADER ===
GW_NAME=$(field "show configuration" '^[[:space:]]*Gateway Name')
SITE=$(field "show configuration" '^[[:space:]]*Site Name')
PORTAL=$(field "show configuration" '^[[:space:]]*Management Portal')
WAN_IF=$(field "show configuration" '^[[:space:]]*WAN Interface')
WAN_IP=$(field "show configuration" '^[[:space:]]*WAN IP Address')
WAN_GW=$(field "show configuration" '^[[:space:]]*WAN Default Gateway')
WAN_DNS=$(field "show configuration" '^[[:space:]]*WAN Nameservers')
WEB_PROXY=$(field "show configuration" '^[[:space:]]*Web Proxy')
[ -z "$GW_NAME" ] && GW_NAME="(unknown)"

printf '\n%s%s ZTB HEALTH CHECK %s\n' "$C_B" "$C_CYN" "$C_RST"
printf '%s%s%s  (%s)   site %s\n' "$C_B" "$GW_NAME" "$C_RST" "$HOST" "${SITE:-unknown}"
printf '%s%s%s\n' "$C_DIM" "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$C_RST"

if [ "$TRUNCATED" = "1" ]; then
    printf '\n%s  ! session truncated: %s of %s commands returned — results below are partial%s\n' \
        "$C_YEL" "$COLLECTED" "$EXPECTED" "$C_RST"
fi

# ==================================================== IDENTITY & SOFTWARE ===
section "IDENTITY & SOFTWARE"

OS_VER=$(block "show version" | grep -m1 -E 'Version' | sed 's/^[[:space:]]*//')
[ -n "$OS_VER" ] && emit INFO "OS version" "$OS_VER" \
    || emit WARN "OS version" "could not read 'show version'"

MODEL=$(field "show device-identifiers" '^Device Model Type')
SERIAL=$(field "show device-identifiers" '^System Serial Number')
[ -n "$MODEL" ] && emit INFO "Model" "$MODEL"
case "$SERIAL" in
    ""|"Not Specified") emit INFO "Serial number" "not specified (virtual appliance)" ;;
    *)                  emit INFO "Serial number" "$SERIAL" ;;
esac

ACTIVE_V=$(block "software version"  | grep -m1 'Active Version'  | sed 's/.*:[[:space:]]*//')
DEFAULT_V=$(block "software version" | grep -m1 'Default Version' | sed 's/.*:[[:space:]]*//')
PREV_V=$(block "software version"    | grep -m1 'Previous Version'| sed 's/.*:[[:space:]]*//')
if [ -n "$ACTIVE_V" ] && [ -n "$DEFAULT_V" ]; then
    if [ "$ACTIVE_V" = "$DEFAULT_V" ]; then
        emit PASS "Boot image" "active = default ($ACTIVE_V)"
    else
        # The default image is NOT what the next reboot uses. Reboots keep the
        # active version; the default only takes effect on a factory reset. So
        # this is configuration drift to clean up, not an imminent outage --
        # WARN, not FAIL.
        emit WARN "Boot image" "default ($DEFAULT_V) != active ($ACTIVE_V)" \
            "reboots stay on $ACTIVE_V; a factory reset would revert to $DEFAULT_V" \
            "fix with: software mkdefault $ACTIVE_V"
    fi
    [ -n "$PREV_V" ] && emit INFO "Previous image" "$PREV_V"
else
    emit WARN "Boot image" "could not read 'software version'"
fi

emit INFO "Management portal" "${PORTAL:-unknown}"

# ============================================================ CONNECTIVITY ===
section "CONNECTIVITY"

AS=$(block "show appliance-status")
GW_STATE=$(echo "$AS" | grep -m1 'Gateway State' | sed 's/.*:[[:space:]]*//')
case "$GW_STATE" in
    "")          emit WARN "Gateway state" "not reported" ;;
    STANDALONE)  emit PASS "Gateway state" "STANDALONE (not in an HA pair)" ;;
    *ACTIVE*|*PRIMARY*) emit PASS "Gateway state" "$GW_STATE" ;;
    *)           emit WARN "Gateway state" "$GW_STATE — confirm this is expected" ;;
esac

# Each probe prints as 'Checking <thing>...OK' / '...FAILED' / '...SKIPPED'
check_probe() {
    local pattern="$1" label="$2"
    local line result
    line=$(echo "$AS" | grep -m1 -i -- "$pattern")
    if [ -z "$line" ]; then
        emit WARN "$label" "probe not present in appliance-status"; return
    fi
    result=$(echo "$line" | grep -o -E 'OK|FAILED|FAIL|SKIPPED|ERROR' | tail -1)
    case "$result" in
        OK)      emit PASS "$label" "OK" ;;
        SKIPPED) emit INFO "$label" "skipped (not configured)" ;;
        "")      emit WARN "$label" "$(echo "$line" | sed 's/^[[:space:]]*//')" ;;
        *)       emit FAIL "$label" "$result — $(echo "$line" | sed 's/^[[:space:]]*//')" ;;
    esac
}
check_probe 'Default Gateway'            "Default gateway"
check_probe 'reachability to internet'   "Internet reachability"
check_probe 'Management Portal'          "Management portal"
check_probe 'Analytics'                  "Analytics connection"
check_probe 'Debug Port'                 "Debug port"

case "$WEB_PROXY" in
    ""|None) : ;;
    *) emit INFO "Web proxy" "$WEB_PROXY" ;;
esac

# ================================================================ SERVICES ===
section "SERVICES"

SVC=$(block "show system services")
[ -z "$SVC" ] && SVC="$AS"
SVC_ROWS=$(echo "$SVC" | awk '
    f && NF >= 2 && $0 !~ /^(Network Status|Services Status)/ {
        state = $NF; $NF = ""; sub(/[ \t]+$/, "", $0)
        if ($0 != "") printf "%s\t%s\n", $0, state
    }
    /^Service[ \t]+State/ { f = 1 }
')
if [ -z "$SVC_ROWS" ]; then
    emit WARN "Service table" "could not parse service states"
else
    svc_total=0; svc_bad=""
    while IFS=$'\t' read -r name state; do
        [ -z "$name" ] && continue
        svc_total=$((svc_total+1))
        case "$state" in
            active) ;;
            inactive|failed|dead)
                # DHCP server is legitimately inactive on sites that don't serve DHCP
                case "$name" in
                    *DHCP\ Server*) ;;
                    *) svc_bad="$svc_bad$name ($state); " ;;
                esac ;;
            *) svc_bad="$svc_bad$name ($state); " ;;
        esac
    done <<< "$SVC_ROWS"

    if [ -z "$svc_bad" ]; then
        emit PASS "System services" "$svc_total services, all active"
    else
        emit FAIL "System services" "not active: ${svc_bad%; }" \
            "investigate with: journalctl -u <service> -n 100"
    fi

    dhcp_state=$(echo "$SVC_ROWS" | grep -i 'DHCP Server' | cut -f2)
    if [ "$dhcp_state" = "inactive" ]; then
        DHCP_ROLE=$(block "dhcpcli -a get-mastership" | grep -m1 -i 'mastership role' | sed 's/^[[:space:]]*//')
        emit INFO "DHCP server" "inactive — normal unless this site serves DHCP" \
            "${DHCP_ROLE:-}"
    elif [ -n "$dhcp_state" ]; then
        emit PASS "DHCP server" "$dhcp_state"
    fi
fi

# ============================================================== CONTAINERS ===
section "CONTAINERS"

DPS=$(block "docker ps")
CON_ROWS=$(echo "$DPS" | awk 'NR > 1 && NF > 3 { print }' | grep -v '^CONTAINER ID')
if [ -z "$CON_ROWS" ]; then
    emit WARN "Container state" "could not read 'docker ps'"
else
    c_total=0; c_bad=""; c_names=""
    while IFS= read -r row; do
        [ -z "$row" ] && continue
        cname=$(echo "$row" | awk '{print $NF}')
        c_total=$((c_total+1))
        c_names="$c_names$cname "
        if ! echo "$row" | grep -qE 'Up [0-9]+|Up About|Up Less'; then
            cstate=$(echo "$row" | grep -oE 'Exited[^ ]*|Restarting[^ ]*|Created|Dead' | head -1)
            c_bad="$c_bad$cname (${cstate:-not Up}); "
        fi
    done <<< "$CON_ROWS"

    if [ -z "$c_bad" ]; then
        emit PASS "Containers running" "$c_total/$c_total up"
    else
        emit FAIL "Containers running" "$((c_total - $(echo "$c_bad" | tr ';' '\n' | grep -c .) )) of $c_total up" \
            "not running: ${c_bad%; }"
    fi
    emit INFO "Container set" "$(echo "$c_names" | sed 's/[[:space:]]*$//')" \
        "the expected set is site-specific — no IPsec to ZIA means no strongswan container"

    # Cross-check: strongswan present but no IPsec policy loaded, or vice versa
    XFRM=$(block "show ip xfrm policy" | grep -c 'dir out')
    if echo "$c_names" | grep -q strongswan; then
        if [ "${XFRM:-0}" -gt 0 ]; then
            emit PASS "IPsec (ZIA tunnel)" "$XFRM outbound policies loaded"
        else
            emit FAIL "IPsec (ZIA tunnel)" "strongswan running but no xfrm policy loaded" \
                "tunnel to the ZIA service edge is not established"
        fi
    else
        if [ "${XFRM:-0}" -gt 0 ]; then
            emit WARN "IPsec (ZIA tunnel)" "$XFRM policies present without a strongswan container"
        else
            emit INFO "IPsec (ZIA tunnel)" "not configured on this gateway"
        fi
    fi
fi

# ===================================================================== ZPA ===
section "ZPA (PRIVATE ACCESS)"

ZCONF=$(block "show zpa config")
if [ -z "$ZCONF" ] || echo "$ZCONF" | grep -qi 'not permitted\|unknown command'; then
    emit INFO "ZPA" "no ZPA configuration exposed on this build"
else
    ZBROKER=$(echo "$ZCONF" | grep -m1 '^broker:'    | sed 's/^broker:[[:space:]]*//')
    ZCLOUD=$(echo  "$ZCONF" | grep -m1 '^zpa_cloud:' | sed 's/^zpa_cloud:[[:space:]]*//')
    ZIACLOUD=$(echo "$ZCONF"| grep -m1 '^zia_cloud:' | sed 's/^zia_cloud:[[:space:]]*//')
    emit INFO "ZPA broker / cloud" "${ZBROKER:-?} / ${ZCLOUD:-?}"
    [ -n "$ZIACLOUD" ] && emit INFO "ZIA cloud" "$ZIACLOUD"

    n_seg=$(block "show zpa appsegments" | grep -cE '^[0-9]+')
    n_ip=$(block  "show zpa ip"   | grep -cE '^[0-9]+\.')
    n_fq=$(block  "show zpa fqdn" | grep -cE '^[A-Za-z.]')
    if [ "${n_seg:-0}" -gt 0 ]; then
        emit PASS "ZPA app segments" "$n_seg published"
    else
        emit WARN "ZPA app segments" "none published — connector may not have synced"
    fi
    emit INFO "ZPA published scope" "${n_ip:-0} IPs / ${n_fq:-0} FQDNs"

    # Certificate expiry
    CERTS=$(block "show zpa certificates")
    if [ -n "$CERTS" ]; then
        cert_worst=""; cert_worst_days=99999; cert_n=0; cert_bad=0
        while IFS= read -r cl; do
            case "$cl" in
                *.crt:*) cur=$(echo "$cl" | sed 's/:.*//' | sed 's/^[[:space:]]*//') ;;
                *expiry:*)
                    raw=$(echo "$cl" | sed 's/^[[:space:]]*expiry:[[:space:]]*//')
                    days=$(days_until "$raw")
                    case "$days" in
                        ''|NA|*[!0-9-]*) continue ;;
                    esac
                    cert_n=$((cert_n+1))
                    if [ "$days" -lt "$cert_worst_days" ]; then
                        cert_worst_days=$days; cert_worst="$cur"
                    fi
                    if [ "$days" -lt 0 ]; then
                        emit FAIL "Certificate expired" "$cur expired $(( -days )) days ago"
                        cert_bad=1
                    elif [ "$days" -lt "$CERT_WARN_DAYS" ]; then
                        emit WARN "Certificate expiring" "$cur in $days days ($raw)"
                        cert_bad=1
                    fi ;;
            esac
        done <<< "$CERTS"
        if [ "$cert_n" -eq 0 ]; then
            emit WARN "ZPA certificates" "none parsed"
        elif [ "$cert_bad" -eq 0 ]; then
            emit PASS "ZPA certificates" "$cert_n valid; soonest $cert_worst in $cert_worst_days days"
        fi
    fi
fi

# ================================================= NETWORK & INTERFACES ===
section "NETWORK"

LINKS=$(block "show ip -br link")
ROUTES=$(block "show ip route")
NEIGH=$(block "show ip neigh")

# WAN interface state
if [ -n "$WAN_IF" ] && [ -n "$LINKS" ]; then
    wan_line=$(echo "$LINKS" | grep -m1 -E "^${WAN_IF}[[:space:]@]")
    wan_state=$(echo "$wan_line" | awk '{print $2}')
    case "$wan_state" in
        UP)      emit PASS "WAN interface" "$WAN_IF UP — $WAN_IP" ;;
        UNKNOWN) emit PASS "WAN interface" "$WAN_IF $wan_state (virtual/tunnel) — $WAN_IP" ;;
        "")      emit WARN "WAN interface" "$WAN_IF not found in link table" ;;
        *)       emit FAIL "WAN interface" "$WAN_IF is $wan_state — $WAN_IP" ;;
    esac
else
    emit WARN "WAN interface" "could not determine WAN interface"
fi

# Default route via the configured WAN
if [ -n "$ROUTES" ]; then
    def_n=$(echo "$ROUTES" | grep -c '^default via')
    if [ "$def_n" -eq 0 ]; then
        emit FAIL "Default route" "no default route present"
    else
        if echo "$ROUTES" | grep -q "^default via ${WAN_GW}.*dev ${WAN_IF}"; then
            emit PASS "Default route" "via $WAN_GW dev $WAN_IF"
        else
            emit WARN "Default route" "present but not via configured WAN ($WAN_GW/$WAN_IF)" \
                "$(echo "$ROUTES" | grep -m1 '^default via')"
        fi
        [ "$def_n" -gt 1 ] && emit INFO "Default routes" "$def_n present (multi-WAN / failover)"
    fi
else
    emit WARN "Default route" "could not read routing table"
fi

# Next-hop resolution
if [ -n "$WAN_GW" ] && [ -n "$NEIGH" ]; then
    nline=$(echo "$NEIGH" | grep -m1 -E "^${WAN_GW}[[:space:]]")
    nstate=$(echo "$nline" | awk '{print $NF}')
    case "$nstate" in
        REACHABLE|PERMANENT|NOARP) emit PASS "WAN next-hop ARP" "$WAN_GW $nstate" ;;
        STALE|DELAY|PROBE)         emit PASS "WAN next-hop ARP" "$WAN_GW $nstate (cached, normal)" ;;
        FAILED|INCOMPLETE)         emit FAIL "WAN next-hop ARP" "$WAN_GW $nstate — gateway not answering ARP" ;;
        "")                        emit INFO "WAN next-hop ARP" "$WAN_GW not in neighbour cache (idle)" ;;
        *)                         emit INFO "WAN next-hop ARP" "$WAN_GW $nstate" ;;
    esac
fi

# Physical interfaces that are down
if [ -n "$LINKS" ]; then
    phys_down=$(echo "$LINKS" | awk '$1 ~ /^ge[0-9]+$/ && $2 != "UP" {printf "%s(%s) ", $1, $2}')
    phys_up=$(echo "$LINKS"   | awk '$1 ~ /^ge[0-9]+$/ && $2 == "UP"' | wc -l)
    if [ -n "$phys_down" ]; then
        emit INFO "Physical links" "$phys_up up; down: $(echo "$phys_down" | sed 's/[[:space:]]*$//')" \
            "unused ports are normally DOWN — confirm none of these are meant to be cabled"
    else
        emit PASS "Physical links" "$phys_up up, none down"
    fi

    # Management interface consistency: the banner names a management port,
    # but the management address may actually live elsewhere (e.g. lo0).
    mgmt_route=$(echo "$ROUTES" | grep -m1 -E "(^|[[:space:]])${HOST%.*}\.|src ${HOST}([[:space:]]|$)")
    if [ -n "$mgmt_route" ]; then
        mgmt_dev=$(echo "$mgmt_route" | sed -n 's/.*dev \([^ ]*\).*/\1/p')
        emit INFO "Management address" "$HOST reached via $mgmt_dev"
    fi

    # Overlay/tunnel interface state. This is kernel fact — the device exists
    # and is administratively up — and is reported independently of the
    # evidence-based judgements in the TUNNELS section below, which rest on
    # inferences that are not yet confirmed. If those are
    # ever dropped, this check still stands on its own.
    tun_down=$(echo "$LINKS" | awk '$1 ~ /^(zia|zpa|wg|s2s|ipsec)/ && $2 == "DOWN" {printf "%s ", $1}')
    tun_up_n=$(echo "$LINKS" | awk '$1 ~ /^(zia|zpa|wg|s2s|ipsec)/ && $2 != "DOWN"' | wc -l)
    tun_names=$(echo "$LINKS" | awk '$1 ~ /^(zia|zpa|wg|s2s|ipsec)/ && $2 != "DOWN" {
                    n = $1; sub(/@.*/, "", n); printf "%s ", n }')
    if [ -n "$tun_down" ]; then
        emit WARN "Overlay interfaces" "$tun_up_n up; down: $(echo "$tun_down" | sed 's/ *$//')" \
            "$(echo "$tun_names" | sed 's/ *$//')"
    elif [ "$tun_up_n" -gt 0 ]; then
        emit PASS "Overlay interfaces" "$tun_up_n up (zia/zpa/wg/s2s)" \
            "$(echo "$tun_names" | sed 's/ *$//')"
    else
        emit INFO "Overlay interfaces" "none present"
    fi
fi


# ====================================================== ROUTING & SEGMENTS ===
# Three questions that come up on every branch call:
#   - which LAN/VLAN segments does this appliance actually terminate?
#   - what has been routed by hand?
#   - what is being learned dynamically, and from where?
#
# Two sources, and both are needed:
#
#   'show ip route'                 the KERNEL FIB — what the box forwards on.
#                                   Authoritative for reachability, but once FRR
#                                   has installed a route the kernel labels it
#                                   'proto zebra' and the origin is lost.
#   'vyos show ip route vrf all'    the FRR RIB — the only view that attributes a
#                                   route to the protocol that produced it
#                                   (C connected, S static, B BGP, O OSPF), and
#                                   the only one that reaches inside vrf-s2s,
#                                   where the site-to-site overlay's BGP lives.
#                                   'vrf all' is mandatory: without it, 'vyos
#                                   show bgp summary' answers '% BGP instance not
#                                   found' and the site looks entirely BGP-free.
#
# So: protocol attribution comes from FRR, forwarding truth from the kernel, and
# where they disagree that is itself reported rather than silently reconciled.
#
# Caveat carried into the output: only the first next-hop of an ECMP route is
# shown. Multipath continuation lines are not expanded.
section "ROUTING & SEGMENTS"

ADDRS=$(block "show ip -br addr")
FRR=$(block "vyos show ip route vrf all")
OSPFN=$(block "vyos show ip ospf vrf all neighbor")

printf '%s\n' "$LINKS"  > "$WORK/links.txt"
printf '%s\n' "$ROUTES" > "$WORK/routes.txt"
printf '%s\n' "$ADDRS"  > "$WORK/addrs.txt"

# --- directly connected segments -------------------------------------------
# A "directly connected" route is one the kernel installed itself when the
# address was configured: 'proto kernel scope link'. Anything with a via is by
# definition not directly connected. 802.1Q subinterfaces are named ge<N>.<vlan>,
# so the VLAN ID is simply the part after the dot — there is no separate VLAN
# table to read on this platform.
#
# Pass 1 reads the link table for admin state, pass 2 the route table for the
# prefix, pass 3 the brief address table so a VLAN that is configured but has no
# IPv4 subnet still appears instead of vanishing.
CONN=$(awk '
    FNR == NR {                                   # show ip -br link
        nm = $1; sub(/@.*/, "", nm)
        if (nm != "") { st[nm] = $2; iface[nm] = 1 }
        next
    }
    FILENAME == r {                               # show ip route
        if ($0 !~ /proto kernel/ || $0 !~ /scope link/) next
        pfx = $1; dev = ""; src = "-"
        if (pfx !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/) next
        for (i = 1; i < NF; i++) {
            if      ($i == "dev") dev = $(i + 1)
            else if ($i == "src") src = $(i + 1)
        }
        if (dev == "") next
        if (dev ~ /^(docker|br-|veth|virbr|lo$|ztbmanagement)/) next
        have[dev] = 1
        vlan = "-"
        if (dev ~ /^[a-z]+[0-9]+\.[0-9]+$/) { vlan = dev; sub(/^[^.]*\./, "", vlan) }
        printf "%-6s %-14s %-19s %-16s %s\n", vlan, dev, pfx, src,
               (st[dev] == "" ? "?" : st[dev])
        next
    }
    {                                             # show ip -br addr
        nm = $1; sub(/@.*/, "", nm)
        if (nm !~ /^[a-z]+[0-9]+\.[0-9]+$/) next
        if (nm in have) next
        if (nm in shown) next
        shown[nm] = 1
        v = nm; sub(/^[^.]*\./, "", v)
        printf "%-6s %-14s %-19s %-16s %s\n", v, nm, "(no IPv4 subnet)", "-",
               (st[nm] == "" ? "?" : st[nm])
    }
' r="$WORK/routes.txt" "$WORK/links.txt" "$WORK/routes.txt" "$WORK/addrs.txt" \
  | LC_ALL=C sort -k1,1n -k2,2)

if [ -z "$CONN" ]; then
    emit WARN "Connected segments" "none parsed from the routing table" \
        "expected at least the WAN subnet — check 'show ip route' output"
else
    conn_total=$(printf '%s\n' "$CONN" | grep -c .)
    conn_vlan=$(printf  '%s\n' "$CONN" | awk '$1 != "-"' | grep -c .)
    conn_down=$(printf  '%s\n' "$CONN" | awk '$NF != "UP" && $NF != "UNKNOWN" {printf "%s(%s) ", $2, $NF}')
    conn_hdr=$(printf '%-6s %-14s %-19s %-16s %s' "vlan" "iface" "subnet" "address" "state")
    conn_w="segments"; [ "$conn_total" -eq 1 ] && conn_w="segment"
    vlan_w="VLANs";    [ "$conn_vlan"  -eq 1 ] && vlan_w="VLAN"

    if [ -n "$conn_down" ]; then
        # A configured segment whose interface is not up serves nothing. It may
        # equally be a VLAN provisioned ahead of the switch port being trunked,
        # so this is a WARN to be confirmed against the site design, not a FAIL.
        emit_lines WARN "Connected segments" \
            "$conn_total $conn_w ($conn_vlan tagged $vlan_w) — down: $(echo "$conn_down" | sed 's/ *$//')" \
            "a down segment carries no traffic — confirm against the site design" \
            "$conn_hdr" <<< "$CONN"
    else
        emit_lines PASS "Connected segments" \
            "$conn_total $conn_w ($conn_vlan tagged $vlan_w), all up" \
            "$conn_hdr" <<< "$CONN"
    fi
fi

# --- the FRR RIB, flattened to TSV -----------------------------------------
# One line per route: code / vrf / prefix / [admin-distance/metric] / via / dev /
# age. The leading three characters of an FRR route line are the protocol code,
# the selected marker '>' and the FIB marker '*' — 'B>*' or 'B  '. Everything
# after that splits cleanly on ', ' into "<prefix> [dist/met] via <ip>",
# "<device>", "<age>".
printf '%s\n' "$FRR" | awk '
    /^VRF [^ ]+:?$/ { vrf = $2; sub(/:$/, "", vrf); next }
    /^Codes:/ { next }
    /^[A-Za-z][ >][ *]/ {
        code = substr($0, 1, 1)
        line = substr($0, 4); sub(/^[ \t]+/, "", line)
        n = split(line, p, ", ")
        head = p[1]
        split(head, h, " "); pfx = h[1]
        if (pfx !~ /\//) next
        met = "-"
        if (match(head, /\[[0-9]+\/[0-9]+\]/)) met = substr(head, RSTART, RLENGTH)
        via = "-"
        if (match(head, /via [0-9a-fA-F.:]+/))   via = substr(head, RSTART + 4, RLENGTH - 4)
        else if (head ~ /directly connected/)    via = "direct"
        dev = (n >= 2) ? p[2] : "-"
        sub(/ onlink$/, "", dev); sub(/^[ \t]+/, "", dev)
        age = (n >= 3) ? p[n] : "-"
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
               code, (vrf == "" ? "default" : vrf), pfx, met, via, dev, age
    }' > "$WORK/frr.tsv" 2>/dev/null

frr_n()   { awk -F'\t' -v c="$1" '$1 == c' "$WORK/frr.tsv" 2>/dev/null | grep -c . ; }
frr_fmt() { awk -F'\t' -v c="$1" '$1 == c {
                printf "%-10s %-19s %-8s via %-15s dev %-14s %s\n", $2, $3, $4, $5, $6, $7 }' \
            "$WORK/frr.tsv" 2>/dev/null ; }
frr_hdr=$(printf '%-10s %-19s %-8s %-19s %-18s %s' "vrf" "prefix" "[ad/met]" "via" "dev" "age")

FRR_OK=1
if [ ! -s "$WORK/frr.tsv" ]; then
    FRR_OK=0
    emit INFO "FRR routing table" "'vyos show ip route vrf all' returned nothing usable" \
        "protocol attribution below falls back to the kernel's 'proto' field," \
        "which cannot tell BGP from OSPF once FRR has installed the route"
fi

# --- static routes ----------------------------------------------------------
# The kernel marks operator-configured routes 'proto static'. On this platform
# the configured WAN default routes land there too, so they are counted out
# separately — otherwise every gateway looks like it has hand-written routes.
STATIC=$(printf '%s\n' "$ROUTES" | awk '
    /proto static/ {
        pfx = $1; via = "-"; dev = "-"; met = "-"
        for (i = 1; i < NF; i++) {
            if      ($i == "via")    via = $(i + 1)
            else if ($i == "dev")    dev = $(i + 1)
            else if ($i == "metric") met = $(i + 1)
        }
        printf "%-19s via %-15s dev %-14s metric %s\n", pfx, via, dev, met
    }')
stat_total=$(printf '%s\n' "$STATIC" | grep -c .)
stat_def=$(printf   '%s\n' "$STATIC" | grep -c '^default')
stat_user=$(( stat_total - stat_def ))
frr_static=$(frr_n S)

if [ "$stat_total" -eq 0 ] && [ "${frr_static:-0}" -eq 0 ]; then
    emit INFO "Static routes" "none configured"
else
    emit_lines INFO "Static routes" \
        "$stat_user site-specific + $stat_def default route(s) in the kernel FIB" \
        <<< "$STATIC"
    # Compared against stat_user, not stat_total: FRR classifies the WAN default
    # routes as 'K' (kernel-installed onlink) while the kernel calls them
    # 'proto static', so totals would never match and the check would fire on
    # every gateway. A genuine difference means statics FRR holds that the main
    # table does not — normally VRF-scoped, which is legitimate but worth seeing.
    if [ "$FRR_OK" = "1" ] && [ "${frr_static:-0}" -ne "$stat_user" ]; then
        emit_lines INFO "Static routes (FRR view)" \
            "${frr_static:-0} in FRR vs $stat_user site-specific in the kernel — VRF-scoped statics differ" \
            "$frr_hdr" <<< "$(frr_fmt S)"
    fi
fi

# --- dynamic routes: BGP ----------------------------------------------------
# BGP peer state is checked in TUNNELS (the S2S overlay rides on it). Here the
# question is narrower: is the adjacency actually putting prefixes in the table?
# An established session carrying nothing is a policy problem, not a link one.
bgp_est=$(block "vyos show bgp vrf all summary" \
          | awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $10 ~ /^[0-9]+$/ {n++} END {print n+0}')
bgp_routes=$(frr_n B)

if [ "${bgp_routes:-0}" -gt 0 ]; then
    emit_lines PASS "BGP-learned routes" \
        "$bgp_routes prefix(es) from ${bgp_est:-0} established peer(s)" \
        "$frr_hdr" <<< "$(frr_fmt B)"
elif [ "${bgp_est:-0}" -gt 0 ] && [ "$FRR_OK" = "1" ]; then
    # Only meaningful when the FRR view actually rendered. Without it a zero here
    # means "not measured", and blaming the peer's export policy would be a
    # fabricated diagnosis — the kernel cross-check at the end reports that case.
    emit WARN "BGP-learned routes" "0 prefixes from $bgp_est established peer(s)" \
        "the adjacency is up but nothing is being advertised to us —" \
        "check the peer's export policy, not the link"
elif [ "$FRR_OK" = "1" ]; then
    emit INFO "BGP-learned routes" "none — no BGP routes in any VRF"
fi

# --- dynamic routes: OSPF ---------------------------------------------------
ospf_routes=$(frr_n O)
ospf_avail=1
case "$OSPFN" in
    ""|*"not enabled"*|*"not permitted"*|*nknown\ command*) ospf_avail=0 ;;
esac

if [ "$ospf_avail" = "1" ]; then
    ospf_full=$(printf '%s\n' "$OSPFN" | awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $3 ~ /^Full/' | grep -c .)
    ospf_bad=$(printf  '%s\n' "$OSPFN" | awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $3 !~ /^Full/ {printf "%s(%s) ", $1, $3}')
    if [ -n "$ospf_bad" ]; then
        # Init / ExStart / Exchange / Loading are mid-negotiation states, so a
        # neighbour parked in one is a stuck adjacency. 2-Way to a non-DR
        # neighbour on a broadcast segment is normal — hence WARN, not FAIL.
        emit WARN "OSPF neighbours" "$ospf_full Full; not Full: $(echo "$ospf_bad" | sed 's/ *$//')" \
            "2-Way to a non-DR neighbour on a broadcast segment is normal;" \
            "Init / ExStart / Exchange / Loading is a stuck adjacency"
    elif [ "$ospf_full" -gt 0 ]; then
        emit PASS "OSPF neighbours" "$ospf_full Full"
    else
        emit INFO "OSPF neighbours" "OSPF is running but has no neighbours"
    fi
else
    emit INFO "OSPF" "not enabled on this gateway"
fi

if [ "${ospf_routes:-0}" -gt 0 ]; then
    emit_lines PASS "OSPF-learned routes" "$ospf_routes prefix(es)" \
        "$frr_hdr" <<< "$(frr_fmt O)"
elif [ "$ospf_avail" = "1" ] && [ "$FRR_OK" = "1" ]; then
    emit WARN "OSPF-learned routes" "OSPF is enabled but no OSPF routes are installed"
fi

# --- kernel cross-check ------------------------------------------------------
# Routes FRR pushed down carry 'proto zebra' (or proto bgp / ospf on some
# builds). If the kernel has them and FRR reported none, the FRR view did not
# render and the counts above understate reality — say so rather than report a
# confident zero.
kern_dyn=$(printf '%s\n' "$ROUTES" | grep -c -E 'proto (zebra|bgp|ospf|babel|isis)')
if [ "${kern_dyn:-0}" -gt 0 ] && [ "$(( ${bgp_routes:-0} + ${ospf_routes:-0} ))" -eq 0 ]; then
    emit WARN "Dynamic routes" "$kern_dyn dynamically-installed route(s) in the kernel FIB" \
        "but the FRR view attributed none — protocol origin could not be determined" \
        "inspect manually: vyos show ip route vrf all"
fi

# ================================================================= TUNNELS ===
# An overlay interface reporting UP only means the kernel created the device.
# It says nothing about whether the tunnel is established or carrying traffic,
# so each one is judged on evidence instead:
#   - byte counters sampled at both ends of this session (direction matters:
#     TX climbing while RX stays flat means we are transmitting into the void)
#   - the control plane behind it (BGP adjacency, broker sessions, IPsec SAs)
#   - the state of the underlay flow in conntrack
section "TUNNELS & OVERLAYS"

# Pull "<iface> <rxbytes> <txbytes> <rxerrs> <txerrs>" out of 'show ip -s link'
parse_counters() {
    awk '
        /^[0-9]+: / { name = $2; sub(/[:@].*/, "", name); next }
        # the value row may be separated from its RX:/TX: header by a blank
        # line, depending on how the pty wrapped the output
        function nextval(   r) {
            do { r = getline } while (r > 0 && $0 ~ /^[[:space:]]*$/)
            return r
        }
        /^[[:space:]]*RX:/ { nextval(); rxb = $1; rxe = $3; next }
        /^[[:space:]]*TX:/ {
            nextval(); txb = $1; txe = $3
            if (name != "" && rxb != "") print name, rxb, txb, rxe, txe
            next
        }'
}
TUN_RE='^(zia|zpa|wg|s2s|ipsec)'

# --no-tunnel-stats stops here: the two 'show ip -s link' samples were never
# collected, so there is nothing to difference. Everything below this block —
# BGP, IPsec SAs, broker sessions, WireGuard underlay — is control-plane
# evidence and runs regardless.
if [ "$TUNNEL_STATS" = "1" ]; then
    block      "show ip -s link" | parse_counters > "$WORK/ctr_first" 2>/dev/null
    block_last "show ip -s link" | parse_counters > "$WORK/ctr_last"  2>/dev/null
fi

if [ "$TUNNEL_STATS" = "0" ]; then
    emit INFO "Tunnel byte counters" "skipped (--no-tunnel-stats)" \
        "idle / one-way / RX-error judgements are derived from these and are" \
        "omitted too; the control-plane tunnel checks below are unaffected"
elif [ ! -s "$WORK/ctr_last" ]; then
    emit WARN "Tunnel counters" "could not read interface statistics"
else
    tun_n=0; tun_live=0; tun_oneway=""; tun_idle=""; tun_unused=""
    while read -r ifc rxb txb rxe txe; do
        echo "$ifc" | grep -qE "$TUN_RE" || continue
        tun_n=$((tun_n + 1))
        case "$rxb$txb" in ''|*[!0-9]*) continue ;; esac
        prev=$(awk -v i="$ifc" '$1 == i {print $2, $3}' "$WORK/ctr_first")
        prxb=$(echo "$prev" | awk '{print $1+0}'); ptxb=$(echo "$prev" | awk '{print $2+0}')
        drx=$(( rxb - prxb )); dtx=$(( txb - ptxb ))

        if [ "$rxb" -eq 0 ] && [ "$txb" -eq 0 ]; then
            tun_unused="$tun_unused$ifc "
        elif [ "$rxb" -eq 0 ] && [ "$txb" -gt 0 ]; then
            # never received a byte, still transmitting: peer is not answering
            tun_oneway="$tun_oneway$ifc "
        elif [ "$drx" -gt 0 ] || [ "$dtx" -gt 0 ]; then
            tun_live=$((tun_live + 1))
        else
            tun_idle="$tun_idle$ifc "
        fi

        # Error ratio is reported, never scored — see the PROV note below.
        if [ "${rxe:-0}" -gt 0 ] && [ "$rxb" -gt 0 ]; then
            rxp=$(awk -v e="$rxe" -v b="$rxb" 'BEGIN{ printf "%d", (e*1500*100)/(b+e*1500) }')
            [ "${rxp:-0}" -ge 5 ] && TUN_ERRS="$TUN_ERRS$ifc:$rxe "
        fi
    done < "$WORK/ctr_last"

    if [ "$tun_n" -eq 0 ]; then
        emit INFO "Overlay tunnels" "none present on this gateway"
    else
        if [ "$tun_live" -gt 0 ]; then
            emit PASS "Tunnels passing traffic" "$tun_live of $tun_n moved data during this run"
        else
            emit FAIL "Tunnels passing traffic" "0 of $tun_n moved data during this run"
        fi
        [ -n "$tun_idle" ] && emit WARN "Tunnels idle" \
            "no traffic this run: $(echo "$tun_idle" | sed 's/ *$//')" \
            "previously carried data — quiet link, or recently failed"
        [ -n "$tun_oneway" ] && emit PROV "Tunnel one-way" \
            "transmitting but never received: $(echo "$tun_oneway" | sed 's/ *$//')" \
            "peer is not answering, OR the tunnel is provisioned-but-unused" \
            "corroborate against the site design before treating this as a fault"
        [ -n "$tun_unused" ] && emit INFO "Tunnels never used" \
            "$(echo "$tun_unused" | sed 's/ *$//') — zero bytes in both directions"
        [ -n "$TUN_ERRS" ] && emit PROV "Tunnel RX errors" \
            "$(echo "$TUN_ERRS" | sed 's/ *$//')" \
            "may be normal for this encapsulation — no expected error rate has" \
            "been established, so it is reported rather than scored"
    fi
fi

# --- S2S: BGP adjacency is the authoritative signal ------------------------
# NB: 'vyos show bgp summary' reports no instance because BGP runs inside a
# VRF; 'vrf all' is required to see it.
BGP=$(block "vyos show bgp vrf all summary")
if [ -z "$BGP" ] || echo "$BGP" | grep -qi 'not found\|no such\|unknown'; then
    emit INFO "S2S BGP" "no BGP instance configured"
else
    bgp_total=0; bgp_up=0; bgp_down=""
    while read -r nb v as mr ms tv inq outq updown state rest; do
        case "$nb" in
            [0-9]*.[0-9]*.[0-9]*.[0-9]*) ;;
            *) continue ;;
        esac
        bgp_total=$((bgp_total + 1))
        case "$state" in
            ''|*[!0-9]*) bgp_down="$bgp_down$nb($state) " ;;   # Idle/Active/Connect
            *)           bgp_up=$((bgp_up + 1))
                         emit PASS "S2S BGP peer" "$nb AS$as up $updown, $state prefixes received" ;;
        esac
    done <<< "$(echo "$BGP" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')"

    if [ "$bgp_total" -eq 0 ]; then
        emit INFO "S2S BGP" "instance present, no peers configured"
    elif [ -n "$bgp_down" ]; then
        emit FAIL "S2S BGP peers down" "$(echo "$bgp_down" | sed 's/ *$//')" \
            "a non-numeric state means the adjacency is not established"
    fi
fi

# --- ZPA: broker sessions prove the connector is attached ------------------
ZPASESS=$(block "conntrack -L | include dport=443")
WAN_BARE="${WAN_IP%%/*}"
if [ -n "$ZPASESS" ] && [ -n "$WAN_BARE" ]; then
    nbroker=$(echo "$ZPASESS" | grep -c "ESTABLISHED src=$WAN_BARE .*dport=443")
    if [ "${nbroker:-0}" -gt 0 ]; then
        emit PASS "ZPA broker sessions" "$nbroker established outbound TLS session(s)"
    else
        emit WARN "ZPA broker sessions" "none established from $WAN_BARE" \
            "the connector may not be attached to a broker"
    fi
fi

# --- IPsec SAs: policy without state means configured-but-not-established --
XSTATE=$(block "show ip xfrm state")
XPOL=$(block "show ip xfrm policy" | grep -c 'dir out')
nsa=$(echo "$XSTATE" | grep -c 'proto esp')
if [ "${XPOL:-0}" -gt 0 ] || [ "${nsa:-0}" -gt 0 ]; then
    if [ "${nsa:-0}" -gt 0 ]; then
        emit PASS "IPsec security associations" "$nsa SA(s) established"
    else
        emit FAIL "IPsec security associations" "$XPOL policies but 0 SAs" \
            "the tunnel is configured and not established"
    fi
fi

# --- WireGuard underlay: an UNREPLIED flow is a peer that never answers -----
WGFLOW=$(block "conntrack -L | include 51820")
if [ -n "$WGFLOW" ]; then
    wg_unrep=$(echo "$WGFLOW" | grep -c 'UNREPLIED')
    wg_ok=$(echo "$WGFLOW" | grep -v 'UNREPLIED' | grep -c 'dport=51820')
    if [ "${wg_unrep:-0}" -gt 0 ]; then
        emit PROV "WireGuard underlay" "$wg_unrep UDP/51820 flow(s) UNREPLIED" \
            "$(echo "$WGFLOW" | grep -m1 'UNREPLIED' | grep -oE 'dst=[0-9.]+' | head -1) is not responding" \
            "corroborates a one-way tunnel if one was reported above;" \
            "confirm whether that peer should exist"
    elif [ "${wg_ok:-0}" -gt 0 ]; then
        emit PASS "WireGuard underlay" "$wg_ok UDP/51820 flow(s) with return traffic"
    fi
fi

# ===================================================================== DNS ===
section "DNS"

DNSM=$(block "show dnsproxy show metrics")
if [ -z "$DNSM" ] || ! echo "$DNSM" | grep -q coredns; then
    emit WARN "DNS proxy metrics" "no CoreDNS metrics returned — is dnsproxy_container up?"
else
    # Counters can be in scientific notation (1.391742e+06), so let awk do the
    # arithmetic and force an integer on the way out — $(( )) cannot parse them.
    hits=$(echo "$DNSM"   | awk '/lookups_total.*result="hit"/  {s+=$NF} END{printf "%d", s+0}')
    misses=$(echo "$DNSM" | awk '/lookups_total.*result="miss"/ {s+=$NF} END{printf "%d", s+0}')
    entries=$(echo "$DNSM"| awk '/dnscache_entries/             {s+=$NF} END{printf "%d", s+0}')
    total=$(( hits + misses ))
    if [ "$total" -eq 0 ]; then
        emit WARN "DNS proxy" "0 lookups recorded — proxy may not be receiving queries" \
            "check the container: docker logs dnsproxy_container"
    else
        emit PASS "DNS proxy" "serving — $hits hits / $misses misses, $entries cached entries"
        # NOT scored: the miss counter is emitted identically under every cache
        # category (high/low/medium), so a hit-rate derived from it overcounts
        # misses ~3x. The counter semantics are unconfirmed, so it cannot yet
        # be turned into a threshold.
        emit INFO "DNS cache ratio" "not scored — miss counter is duplicated per cache category" \
            "verify the counter semantics before using it as a health signal"
    fi
fi

NATB=$(block "show iptables -t nat")
if [ -n "$NATB" ]; then
    if echo "$NATB" | grep -q '1053'; then
        emit PASS "DNS redirect" "local DNS DNAT'd to the proxy on 127.0.0.1:1053"
    else
        emit WARN "DNS redirect" "no DNAT to 127.0.0.1:1053 found in the nat table" \
            "local processes may be bypassing the DNS proxy"
    fi
fi
[ -n "$WAN_DNS" ] && emit INFO "Configured resolvers" "$WAN_DNS"

# ================================================================ FIREWALL ===
section "FIREWALL"

FW=$(block "show iptables")
if [ -z "$FW" ]; then
    emit WARN "Packet filter" "could not read the filter table"
else
    inpol=$(echo "$FW" | grep -m1 '^Chain INPUT' | sed 's/.*policy \([A-Z]*\).*/\1/')
    case "$inpol" in
        DROP|REJECT) emit PASS "INPUT policy" "$inpol (default-deny)" ;;
        ACCEPT)      emit FAIL "INPUT policy" "ACCEPT — the appliance is not default-deny on input" ;;
        *)           emit WARN "INPUT policy" "could not determine (${inpol:-none})" ;;
    esac
    for chain in SECURITY_RULES SGW_IPSEC_ZIA_RULES FIREWALL-OUTPUT; do
        echo "$FW" | grep -q "$chain" && emit INFO "Policy chain" "$chain present"
    done
fi

# ======================================================== ZTP / ACTIVATION ===
section "PROVISIONING"

ZTP=$(block "show ztp activation-state")
if [ -z "$ZTP" ]; then
    emit WARN "ZTP state" "could not read activation state"
else
    auth=$(echo  "$ZTP" | grep -m1 'Authentication State' | sed 's/.*:[[:space:]]*//')
    isztp=$(echo "$ZTP" | grep -m1 'ZTP Device'           | sed 's/.*:[[:space:]]*//')
    case "$auth" in
        true)  emit PASS "ZTP authentication" "true" ;;
        false) emit WARN "ZTP authentication" "false" \
                   "also seen on appliances that are otherwise healthy — not a" \
                   "reliable fault signal on its own" \
                   "confirm whether 'false' is expected post-activation" ;;
        *)     emit INFO "ZTP authentication" "${auth:-unknown}" ;;
    esac
    emit INFO "ZTP device" "${isztp:-unknown}"
fi

# ================================================================ RESOURCES ===
# uptime / top are refused for non-interactive execution, which is exactly why
# this script uses a single interactive session — see the header comment.
section "RESOURCES"

UPT=$(block "uptime" | grep -m1 'load average')
TOPB=$(block "top -b -n 1")
NCPU=$(block "docker info" | grep -m1 -E '^[[:space:]]*CPUs:' | sed 's/.*:[[:space:]]*//')

if [ -n "$UPT" ]; then
    up_for=$(echo "$UPT" | sed -e 's/.*up[[:space:]]*//' -e 's/,[[:space:]]*[0-9]* user.*//')
    load1=$(echo "$UPT" | sed 's/.*load average:[[:space:]]*//' | cut -d, -f1 | tr -d ' ')
    emit INFO "Uptime" "$up_for"
    # recent reboot is worth surfacing during triage
    if echo "$up_for" | grep -qE '^[0-9]+:[0-5][0-9]$|min'; then
        emit WARN "Recent restart" "up less than a day ($up_for) — was this planned?"
    fi
    if [ -n "$load1" ] && [ -n "$NCPU" ]; then
        # integer compare: load*100 vs cpus*100
        l100=$(echo "$load1" | awk '{printf "%d", $1*100}')
        hi=$(( NCPU * 100 )); warn=$(( NCPU * 70 ))
        if   [ "$l100" -ge "$hi" ];  then emit FAIL "CPU load" "1-min load $load1 exceeds $NCPU CPUs"
        elif [ "$l100" -ge "$warn" ];then emit WARN "CPU load" "1-min load $load1 on $NCPU CPUs (>70%)"
        else                              emit PASS "CPU load" "1-min load $load1 on $NCPU CPUs"
        fi
    elif [ -n "$load1" ]; then
        emit INFO "CPU load" "1-min load $load1"
    fi
else
    emit WARN "Uptime / load" "not collected" \
        "expected if the session fell back to non-interactive mode"
fi

MEMLINE=$(echo "$TOPB" | grep -m1 -E '^MiB Mem')
if [ -n "$MEMLINE" ]; then
    m_total=$(echo "$MEMLINE" | sed 's/.*: *\([0-9.]*\) total.*/\1/')
    m_free=$(echo  "$MEMLINE" | sed 's/.*, *\([0-9.]*\) free.*/\1/')
    m_used=$(echo  "$MEMLINE" | sed 's/.*, *\([0-9.]*\) used.*/\1/')
    if [ -n "$m_total" ] && [ -n "$m_used" ]; then
        pct=$(awk -v u="$m_used" -v t="$m_total" 'BEGIN{ if(t>0) printf "%d", u*100/t; else print 0 }')
        # buff/cache is not pressure; only flag genuinely high 'used'
        if   [ "$pct" -ge 90 ]; then emit FAIL "Memory" "${pct}% used (${m_used}/${m_total} MiB)"
        elif [ "$pct" -ge 80 ]; then emit WARN "Memory" "${pct}% used (${m_used}/${m_total} MiB)"
        else                         emit PASS "Memory" "${pct}% used (${m_used}/${m_total} MiB, ${m_free} free)"
        fi
    fi
fi

SWAPLINE=$(echo "$TOPB" | grep -m1 -E '^MiB Swap')
if [ -n "$SWAPLINE" ]; then
    s_used=$(echo "$SWAPLINE" | sed 's/.*, *\([0-9.]*\) used.*/\1/')
    case "$s_used" in
        0.0|0|"") : ;;
        *) emit WARN "Swap in use" "${s_used} MiB — memory pressure" ;;
    esac
fi

TASKS=$(echo "$TOPB" | grep -m1 -E '^Tasks:')
if [ -n "$TASKS" ]; then
    zomb=$(echo "$TASKS" | grep -oE '[0-9]+ zombie' | awk '{print $1}')
    [ -n "$zomb" ] && [ "$zomb" -gt 0 ] && emit WARN "Zombie processes" "$zomb"
fi

# ===================================================================== LOGS ===
section "LOGS"

JL=$(block "journalctl -n 200")
if [ -z "$JL" ]; then
    emit INFO "Recent log errors" "journal not collected"
else
    jl_lines=$(echo "$JL" | grep -c .)
    err_n=$(echo "$JL" | grep -icE '\b(error|failed|failure|panic|fatal)\b')
    if   [ "$err_n" -eq 0 ]; then emit PASS "Recent log errors" "none in the last $jl_lines journal lines"
    elif [ "$err_n" -lt 10 ]; then
        emit WARN "Recent log errors" "$err_n in the last $jl_lines journal lines" \
            "$(echo "$JL" | grep -iE '\b(error|failed|failure|panic|fatal)\b' | tail -1 | cut -c1-90)"
    else
        emit FAIL "Recent log errors" "$err_n in the last $jl_lines journal lines" \
            "$(echo "$JL" | grep -iE '\b(error|failed|failure|panic|fatal)\b' | tail -1 | cut -c1-90)" \
            "review with: journalctl -n 200 | include -i error"
    fi
fi

# ================================================================= SUMMARY ===
printf '\n%s%s%s\n' "$C_DIM" "$(printf '%.0s─' $(seq 1 64))" "$C_RST"

if   [ "$N_FAIL" -gt 0 ]; then VERDICT="${C_RED}${C_B}UNHEALTHY${C_RST}"; EXIT=2
elif [ "$N_WARN" -gt 0 ]; then VERDICT="${C_YEL}${C_B}DEGRADED${C_RST}";  EXIT=1
else                           VERDICT="${C_GRN}${C_B}HEALTHY${C_RST}";   EXIT=0
fi

printf '  %s   %s%d FAIL%s   %s%d WARN%s   %s%d PASS%s   %s%d prov%s   %s%d info%s\n' \
    "$VERDICT" \
    "$C_RED" "$N_FAIL" "$C_RST" \
    "$C_YEL" "$N_WARN" "$C_RST" \
    "$C_GRN" "$N_PASS" "$C_RST" \
    "$C_MAG" "$N_PROV" "$C_RST" \
    "$C_DIM" "$N_INFO" "$C_RST"
printf '  %s%s — %s%s\n' "$C_DIM" "$GW_NAME" "$(date -u '+%Y-%m-%d %H:%M UTC')" "$C_RST"

if [ "$TRUNCATED" = "1" ]; then
    printf '  %s! partial run — %s of %s commands returned%s\n' "$C_YEL" "$COLLECTED" "$EXPECTED" "$C_RST"
    [ "$EXIT" -lt 1 ] && EXIT=1
fi

# PROV items are observations whose meaning is not yet agreed. They do not
# affect the verdict or the exit code; they are collected here so the same
# question can be answered across several gateways at once.
if [ "$N_PROV" -gt 0 ]; then
    printf '\n  %s%d provisional observation(s)%s — not scored, pending confirmation.\n' \
        "$C_MAG" "$N_PROV" "$C_RST"
    printf '  %sRun with --evidence to include the raw output behind them.%s\n' "$C_DIM" "$C_RST"
fi

# --------------------------------------------------------------- evidence ---
if [ "$EVIDENCE" = "1" ]; then
    printf '\n\n%s%s RAW EVIDENCE %s\n' "$C_B" "$C_MAG" "$C_RST"
    printf '%sGateway %s (%s) — %s%s\n' "$C_DIM" "$GW_NAME" "$HOST" \
        "$(date -u '+%Y-%m-%d %H:%M UTC')" "$C_RST"
    printf '%sUnedited command output behind the tunnel and routing checks, for review.%s\n' \
        "$C_DIM" "$C_RST"
    EV_LIST="show ip xfrm state
show ip xfrm policy
vyos show bgp vrf all summary
vyos show ip route vrf all
vyos show ip ospf vrf all neighbor
show ip route
show ip -br addr
conntrack -L | include 51820
show ip -br link"
    [ "$TUNNEL_STATS" = "1" ] && EV_LIST="show ip -s link
$EV_LIST"
    while IFS= read -r ev; do
        [ -z "$ev" ] && continue
        printf '\n%s----- %s -----%s\n' "$C_B" "$ev" "$C_RST"
        out=$(block_last "$ev")
        if [ -z "$out" ]; then
            printf '(no output)\n'
        else
            printf '%s\n' "$out"
        fi
    done <<< "$EV_LIST"

    if [ "$TUNNEL_STATS" = "1" ] && [ -s "$WORK/ctr_last" ]; then
        printf '\n%s----- counter delta across this run -----%s\n' "$C_B" "$C_RST"
        printf '%-18s %16s %16s %12s %12s\n' IFACE RX_BYTES TX_BYTES D_RX D_TX
        while read -r ifc rxb txb rxe txe; do
            echo "$ifc" | grep -qE "$TUN_RE" || continue
            prev=$(awk -v i="$ifc" '$1 == i {print $2, $3}' "$WORK/ctr_first")
            prxb=$(echo "$prev" | awk '{print $1+0}'); ptxb=$(echo "$prev" | awk '{print $2+0}')
            printf '%-18s %16s %16s %12s %12s\n' "$ifc" "$rxb" "$txb" \
                "$(( rxb - prxb ))" "$(( txb - ptxb ))"
        done < "$WORK/ctr_last"
    fi
fi

printf '\n'
exit "$EXIT"
