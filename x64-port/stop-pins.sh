#!/usr/bin/env bash
# Stop PINS and everything it leaves behind, in the right order.
#
# Why this exists: `pkill -9 NINA` loses data. PINS writes the active profile
# to ~/.local/share/NINA/Profiles/<guid>.profile only during a GRACEFUL
# shutdown, so a hard kill silently discards every setting changed since the
# last clean exit -- INDI driver selections, site coordinates, cooling
# durations. The symptom is a setting that "did not take effect", which looks
# like a bug in PINS rather than in how it was stopped.
#
# So: SIGTERM first, wait, and only escalate for what is genuinely stuck.
#
# It also clears what PINS cannot clean up after an unclean exit:
#   - its own indiserver on 7624 and /tmp/indiFIFO (CleanupServer does this
#     itself on a graceful exit; this is the fallback)
#   - orphaned INDI drivers, which survive a PINS restart and keep holding a
#     device name, so the next run appears to load the OLD driver
#   - the test harness on 7625 / /tmp/indiFIFO-test, which test-indi-sim.sh
#     deliberately keeps off PINS's ports
#
# Usage: stop-pins.sh [--force] [--tests-only] [--status]

set -uo pipefail   # deliberately no -e: cleanup continues past absent processes

GRACE_SECONDS="${GRACE_SECONDS:-15}"

info() { printf '   %s\n' "$*"; }
warn() { printf '\033[1;33m   WARN %s\033[0m\n' "$*"; }
log()  { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }

FORCE=0 TESTS_ONLY=0 STATUS_ONLY=0
while (( $# )); do
    case "$1" in
        -f|--force)      FORCE=1;      shift ;;
        -t|--tests-only) TESTS_ONLY=1; shift ;;
        -s|--status)     STATUS_ONLY=1; shift ;;
        -h|--help)
            sed -n '2,21p' "$0" | sed 's/^# \?//'
            echo
            echo "Options:"
            echo "  -f, --force       skip the graceful wait and SIGKILL immediately."
            echo "                    WARNING: discards unsaved profile changes."
            echo "  -t, --tests-only  stop only the test harness (port 7625), leaving"
            echo "                    PINS running"
            echo "  -s, --status      show what is running, change nothing"
            echo "  -h, --help        this text"
            echo
            echo "Environment: GRACE_SECONDS (default 15)"
            exit 0 ;;
        *) warn "unknown option '$1' (see --help)"; exit 2 ;;
    esac
done

# ---------------------------------------------------------------- status ----
show_status() {
    local found=0 p ports f

    p=$(pgrep -x NINA 2>/dev/null | tr '\n' ' ')
    [[ -n "$p" ]] && { info "PINS (NINA): $p"; found=1; }

    p=$(pgrep -x indiserver 2>/dev/null | tr '\n' ' ')
    [[ -n "$p" ]] && { info "indiserver: $p"; found=1; }

    # `[i]ndi_` so this script's own command line never matches
    p=$(pgrep -af '[i]ndi_[a-z]' 2>/dev/null | awk '{print $2}' | tr '\n' ' ')
    [[ -n "$p" ]] && { info "INDI drivers: $p"; found=1; }

    ports=$(ss -tln 2>/dev/null | grep -oE ':(1888|5000|4782|7624|7625)\b' \
            | tr -d ':' | sort -u | tr '\n' ' ')
    [[ -n "$ports" ]] && { info "ports held: $ports"; found=1; }

    for f in /tmp/indiFIFO /tmp/indiFIFO-test; do
        [[ -p "$f" ]] && { info "FIFO: $f"; found=1; }
    done

    (( found )) || info "nothing running"
    return 0
}

if (( STATUS_ONLY )); then
    log "Status"
    show_status
    exit 0
fi

# ------------------------------------------------------------ test harness --
# test-indi-sim.sh uses port 7625 and /tmp/indiFIFO-test so it stays clear of
# PINS. Kill it by FIFO argument rather than by name: a bare `pkill indiserver`
# would take PINS's server down too.
stop_tests() {
    log "Stopping the INDI test harness"
    local pids
    pids=$(pgrep -f 'indiserver.*indiFIFO-test' 2>/dev/null | tr '\n' ' ')
    if [[ -n "$pids" ]]; then
        info "test indiserver: $pids"
        kill $pids 2>/dev/null
        sleep 2
        pids=$(pgrep -f 'indiserver.*indiFIFO-test' 2>/dev/null | tr '\n' ' ')
        [[ -n "$pids" ]] && { warn "still alive, forcing"; kill -9 $pids 2>/dev/null; }
    else
        info "no test server running"
    fi
    [[ -p /tmp/indiFIFO-test ]] && { rm -f /tmp/indiFIFO-test; info "removed /tmp/indiFIFO-test"; }
    return 0
}

stop_tests
(( TESTS_ONLY )) && exit 0

# -------------------------------------------------------------------- PINS --
log "Stopping PINS"

pins_pids=$(pgrep -x NINA 2>/dev/null | tr '\n' ' ')
if [[ -z "$pins_pids" ]]; then
    info "PINS not running"
else
    info "PINS: $pins_pids"
    if (( FORCE )); then
        warn "--force: SIGKILL, unsaved profile changes will be lost"
        kill -9 $pins_pids 2>/dev/null
        sleep 2
    else
        # SIGTERM lets PINS persist the profile, disconnect equipment and run
        # CleanupServer (which stops its indiserver and removes the FIFO).
        kill -TERM $pins_pids 2>/dev/null
        info "sent SIGTERM, waiting up to ${GRACE_SECONDS}s for a clean exit"
        for (( i = 0; i < GRACE_SECONDS; i++ )); do
            pgrep -x NINA >/dev/null 2>&1 || break
            sleep 1
        done
        if pgrep -x NINA >/dev/null 2>&1; then
            warn "did not exit in ${GRACE_SECONDS}s; escalating to SIGKILL"
            warn "profile changes since the last clean exit are lost"
            kill -9 $(pgrep -x NINA) 2>/dev/null
            sleep 2
        else
            info "exited cleanly (profile saved)"
        fi
    fi
fi

# --------------------------------------------------------- INDI leftovers ---
# Only reachable if PINS died badly; a graceful exit has already done this.
log "Clearing INDI leftovers"

srv=$(pgrep -x indiserver 2>/dev/null | tr '\n' ' ')
if [[ -n "$srv" ]]; then
    info "orphaned indiserver: $srv"
    kill $srv 2>/dev/null; sleep 2
    srv=$(pgrep -x indiserver 2>/dev/null | tr '\n' ' ')
    [[ -n "$srv" ]] && kill -9 $srv 2>/dev/null
else
    info "no orphaned indiserver"
fi

# Orphaned drivers matter more than they look: one that outlives PINS keeps
# holding its device name, so the next start appears to load the old driver
# even after the profile was changed.
drv=$(pgrep -f '[i]ndi_[a-z]' 2>/dev/null | tr '\n' ' ')
if [[ -n "$drv" ]]; then
    info "orphaned INDI drivers: $(pgrep -af '[i]ndi_[a-z]' | awk '{print $2}' | tr '\n' ' ')"
    kill $drv 2>/dev/null; sleep 2
    drv=$(pgrep -f '[i]ndi_[a-z]' 2>/dev/null | tr '\n' ' ')
    [[ -n "$drv" ]] && kill -9 $drv 2>/dev/null
else
    info "no orphaned drivers"
fi

[[ -p /tmp/indiFIFO ]] && { rm -f /tmp/indiFIFO; info "removed /tmp/indiFIFO"; }

# ------------------------------------------------------------------ verify --
log "Final state"
sleep 1
show_status

leftover=$(ss -tln 2>/dev/null | grep -cE ':(1888|5000|4782|7624|7625)\b')
if (( leftover > 0 )); then
    warn "$leftover port(s) still held; a socket in TIME_WAIT clears on its own"
    warn "but a still-listening port means something survived"
    exit 1
fi
exit 0
