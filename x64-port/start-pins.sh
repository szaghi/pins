#!/usr/bin/env bash
# Start PINS cleanly and confirm it is actually serving.
#
# The two failure modes this removes:
#
#   1. Starting while an old instance still holds the ports. Kestrel cannot
#      bind 4782, the new process aborts with a core dump, and the log fills
#      with a stack trace that says nothing about the real cause. So: stop
#      first, unless --no-stop says otherwise.
#
#   2. Assuming "it started" because the process exists. PINS forks its
#      indiserver and brings up three servers asynchronously; the process can
#      be alive for tens of seconds before the UI answers. So: wait for all
#      three ports and say so.
#
# Usage: start-pins.sh [--foreground] [--no-stop] [--publish-dir DIR]

set -uo pipefail

PUBLISH="${PUBLISH:-$HOME/pins-run}"
LOGFILE="${PINS_LOG:-/tmp/pins.log}"
WAIT_SECONDS="${WAIT_SECONDS:-90}"

# 1888 ninaAPI REST, 5000 Touch-N-Stars UI, 4782 PINS Kestrel/SignalR.
# All three matter: with only 4782 missing the UI loads but the setup wizard
# silently bounces, which is a miserable thing to debug.
PORTS=(1888 5000 4782)

log()  { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '\033[1;33m   WARN %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m   FAIL %s\033[0m\n' "$*" >&2; exit 1; }

FOREGROUND=0 NO_STOP=0
while (( $# )); do
    case "$1" in
        -f|--foreground) FOREGROUND=1; shift ;;
        -n|--no-stop)    NO_STOP=1;    shift ;;
        -p|--publish-dir)
            [[ ${2:-} ]] || die "--publish-dir needs a directory"
            PUBLISH="$2"; shift 2 ;;
        --publish-dir=*) PUBLISH="${1#*=}"; shift ;;
        -h|--help)
            sed -n '2,17p' "$0" | sed 's/^# \?//'
            echo
            echo "Options:"
            echo "  -f, --foreground       run in this terminal with the log on screen"
            echo "                         (Ctrl-C stops it; the profile is still saved)"
            echo "  -n, --no-stop          do not stop a running instance first"
            echo "  -p, --publish-dir DIR  where PINS is published (default: \$HOME/pins-run)"
            echo "  -h, --help             this text"
            echo
            echo "Environment: PINS_LOG (default /tmp/pins.log), WAIT_SECONDS (90)"
            exit 0 ;;
        *) die "unknown option '$1' (see --help)" ;;
    esac
done

[[ -x "$PUBLISH/NINA" ]] || die "no PINS binary at $PUBLISH/NINA (run the installer's pins stage)"

# ------------------------------------------------------------------- stop ---
if (( ! NO_STOP )); then
    if pgrep -x NINA >/dev/null 2>&1; then
        log "Stopping the running instance first"
        stopper="$(dirname "$(readlink -f "$0")")/stop-pins.sh"
        if [[ -x "$stopper" ]]; then
            "$stopper" >/dev/null 2>&1 || warn "stop-pins.sh reported a problem; continuing"
            info "stopped"
        else
            warn "stop-pins.sh not found beside this script; using SIGTERM directly"
            pkill -TERM -x NINA 2>/dev/null
            for (( i = 0; i < 15; i++ )); do
                pgrep -x NINA >/dev/null 2>&1 || break
                sleep 1
            done
            pgrep -x NINA >/dev/null 2>&1 && { warn "forcing"; pkill -9 -x NINA; sleep 2; }
        fi
    fi
fi

# ------------------------------------------------------------------ start ---
log "Starting PINS"
info "publish: $PUBLISH"

if (( FOREGROUND )); then
    info "foreground; Ctrl-C to stop (SIGINT still saves the profile)"
    echo
    cd "$PUBLISH" && exec ./NINA
fi

info "log: $LOGFILE"
# setsid + </dev/null so it survives this shell and an SSH session closing.
#
# The redirections on the SUBSHELL matter as much as the ones on ./NINA.
# Without them the subshell inherits the caller's stdout and stderr, setsid
# holds those descriptors open, and an ssh invocation of this script never
# returns -- it waits for a pipe that only closes when PINS exits.
( cd "$PUBLISH" && setsid nohup ./NINA > "$LOGFILE" 2>&1 < /dev/null & ) \
    >/dev/null 2>&1 < /dev/null

# ------------------------------------------------------------------- wait ---
log "Waiting for the servers"

port_up() { ss -tln 2>/dev/null | grep -qE ":$1\b"; }

deadline=$(( SECONDS + WAIT_SECONDS ))
declare -A seen=()
while (( SECONDS < deadline )); do
    all=1
    for p in "${PORTS[@]}"; do
        if port_up "$p"; then
            [[ -z "${seen[$p]:-}" ]] && { info "port $p up"; seen[$p]=1; }
        else
            all=0
        fi
    done
    (( all )) && break

    # Fail fast rather than waiting the full timeout on a process that died.
    if ! pgrep -x NINA >/dev/null 2>&1; then
        warn "PINS exited during startup"
        warn "last lines of $LOGFILE:"
        tail -15 "$LOGFILE" 2>/dev/null | sed 's/^/        /'
        die "startup failed"
    fi
    sleep 2
done

missing=()
for p in "${PORTS[@]}"; do port_up "$p" || missing+=("$p"); done

if (( ${#missing[@]} )); then
    warn "not listening after ${WAIT_SECONDS}s: ${missing[*]}"
    case " ${missing[*]} " in
        *" 5000 "*) warn "5000 is Touch-N-Stars: is its plugin deployed? (setup-pins-x64.sh plugins)" ;;
    esac
    case " ${missing[*]} " in
        *" 1888 "*) warn "1888 is ninaAPI: is its plugin deployed? (setup-pins-x64.sh plugins)" ;;
    esac
    warn "see $LOGFILE"
    exit 1
fi

# ---------------------------------------------------------------- summary ---
log "Running"
info "pid: $(pgrep -x NINA | tr '\n' ' ')"

# `paste -sd', '` cycles through the delimiter's characters one per join, so a
# two-character separator comes out wrong. Use tr on a single char instead.
plugins=$(grep -a 'Successfully loaded plugin' "$LOGFILE" 2>/dev/null \
          | sed 's/.*Successfully loaded plugin //; s/ version.*//' \
          | paste -sd'|' - | sed 's/|/, /g')
[[ -n "$plugins" ]] && info "plugins: $plugins"

ip=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -1)
echo
echo "   Touch-N-Stars:  http://${ip:-<this-host>}:5000"
echo "   API:            http://${ip:-<this-host>}:1888/v2/api/version"
echo "   Log:            $LOGFILE"
echo "   Stop with:      $(dirname "$(readlink -f "$0")")/stop-pins.sh"
