#!/usr/bin/env bash
# Stage 1: verify INDI works on its own, before involving PINS.
# Starts indiserver with the CCD + telescope simulators, checks the port
# answers, and confirms the drivers announce their devices over XML.
#
# Deliberately does NOT use /tmp/indiFIFO or the default port: PINS runs
# `pkill -9 indiserver` on startup and owns port 7624, so this test uses
# port 7625 to stay out of its way.

set -uo pipefail

PORT=7625
FIFO=/tmp/indiFIFO-test
LOG=/tmp/indi-sim-test.log
DRIVERS="indi_simulator_telescope indi_simulator_ccd"

cleanup() {
    [[ -n "${SRV_PID:-}" ]] && kill "$SRV_PID" 2>/dev/null
    rm -f "$FIFO"
}
trap cleanup EXIT

echo "== 1. Tooling check =="
for bin in indiserver indi_simulator_ccd indi_simulator_telescope; do
    if command -v "$bin" >/dev/null 2>&1; then
        echo "  OK      $bin -> $(command -v "$bin")"
    else
        echo "  MISSING $bin"
        echo
        echo "Install with:  sudo apt-get install -y indi-bin libindi1"
        exit 1
    fi
done
echo "  indiserver version: $(indiserver --help 2>&1 | head -1)"

echo
echo "== 2. Start indiserver on port $PORT =="
rm -f "$FIFO"
mkfifo "$FIFO"
indiserver -v -p "$PORT" -m 1000 -f "$FIFO" >"$LOG" 2>&1 &
SRV_PID=$!
sleep 2

if ! kill -0 "$SRV_PID" 2>/dev/null; then
    echo "  FAIL indiserver died on startup. Log:"
    sed 's/^/    /' "$LOG"
    exit 1
fi
echo "  OK indiserver running, PID $SRV_PID"

echo
echo "== 3. Load simulator drivers via FIFO =="
for d in $DRIVERS; do
    # Opening a FIFO write-only blocks until a reader exists; indiserver is
    # the reader, so bound it in case the server hung.
    if timeout 5 bash -c "echo 'start $d' > '$FIFO'"; then
        echo "  sent: start $d"
    else
        echo "  FAIL timed out writing to FIFO (indiserver hung?)"
        exit 1
    fi
done
sleep 3

echo
echo "== 4. Port check =="
if timeout 3 bash -c "cat < /dev/null > /dev/tcp/127.0.0.1/$PORT" 2>/dev/null; then
    echo "  OK port $PORT accepting connections"
else
    echo "  FAIL nothing listening on $PORT"
    exit 1
fi

echo
echo "== 5. Ask the server for its device properties =="
# getProperties is the INDI handshake: the server replies with a defXxxVector
# for every property of every loaded device.
XML=$(timeout 6 bash -c "
    exec 3<>/dev/tcp/127.0.0.1/$PORT
    printf '<getProperties version=\"1.7\"/>\n' >&3
    timeout 4 cat <&3
" 2>/dev/null)

if [[ -z "$XML" ]]; then
    echo "  FAIL server returned nothing"
    exit 1
fi

echo "  received $(wc -c <<<"$XML") bytes of XML"
echo "  devices announced:"
grep -o 'device="[^"]*"' <<<"$XML" | sort -u | sed 's/^/    /'

echo
echo "== 5b. Connect the CCD and re-read =="
# CCD_EXPOSURE and the CCD1 BLOB vector are defined lazily: the driver only
# publishes them after CONNECTION is switched On. Probing the initial dump
# alone reports them missing even on a perfectly healthy server.
XML2=$(timeout 15 bash -c "
    exec 3<>/dev/tcp/127.0.0.1/$PORT
    printf '<getProperties version=\"1.7\"/>\n' >&3
    sleep 2
    printf '<newSwitchVector device=\"CCD Simulator\" name=\"CONNECTION\">
              <oneSwitch name=\"CONNECT\">On</oneSwitch>
            </newSwitchVector>\n' >&3
    sleep 3
    printf '<getProperties version=\"1.7\" device=\"CCD Simulator\"/>\n' >&3
    timeout 6 cat <&3
" 2>/dev/null)

for prop in CCD_EXPOSURE CCD1 CCD_INFO CCD_TEMPERATURE CCD_ABORT_EXPOSURE; do
    if grep -q "name=\"$prop\"" <<<"$XML2"; then
        echo "  OK      $prop"
    else
        echo "  ABSENT  $prop"
    fi
done

if grep -q '<defBLOBVector[^>]*name="CCD1"' <<<"$XML2"; then
    echo "  OK      CCD1 is a BLOB vector (the image path PINS consumes)"
else
    echo "  FAIL    no CCD1 BLOB vector; PINS will not receive images"
fi

echo
echo "== 6. indiserver log tail =="
tail -15 "$LOG" | sed 's/^/  /'

echo
echo "== DONE =="
echo "Full log: $LOG"
