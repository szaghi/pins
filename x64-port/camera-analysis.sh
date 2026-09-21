#!/usr/bin/env bash
# Acquire bias and flat frames to calibrate the ToupTek ATR2600C, on astrobit.
#
# Why this exists: the camera publishes ElectronsPerADU = NaN, so PINS knows
# nothing about its own conversion gain, and the gain axis is ToupTek's NATIVE
# PERCENT scale -- 100 = unity, 10000 = 100x -- not the ZWO 0.1 dB scale that
# every SharpCap guide and ASI2600 forum post assumes. Offset, read noise and
# the HCG knee therefore cannot be looked up. They have to be measured here.
#
# This script only ACQUIRES. camera_analysis.py does the maths; run its
# --selftest first if you want to see the estimators recover known values.
#
# RUN THIS ON ASTROBIT. It drives the camera through ninaAPI on port 1888.
# It is camera-only: it never touches /framing/slew or /equipment/mount/*.
#
# Stages:
#   --setup      create the venv and install numpy/astropy/matplotlib
#   --bias       sweep gain x offset, N bias frames each (the offset hunt)
#   --flat-auto  flat pairs at four exposure-set levels per gain, unattended
#   --flat       flat pairs, you dim the panel between levels (the old way)
#   --linearity  exposure ramp past saturation; fits and reports the departure
#   --analyse    run camera_analysis.py over whatever has been collected
#   --all        setup, bias, analyse  (flats need a panel, so not in --all)
#
# --flat-auto supersedes --flat. It holds the illumination FIXED and sets the
# signal level with exposure time, probing the reference exposure per gain
# rather than taking it on trust, so it needs no operator at the panel and
# repeats to the millisecond. --flat is kept for a dimmable panel.
#
# Gain and offset are written into the ACTIVE PROFILE and persist. The script
# records the original values at start and restores them from an EXIT trap, so
# an interrupted run does not leave the camera mis-set. Do not kill it with
# SIGKILL; the trap cannot run.
#
# Exit: 0 done, 1 acquisition/analysis failure, 2 bad usage,
#       3 camera not connected or API unreachable, 4 refused: cooling not ready.

set -uo pipefail

# ---------------------------------------------------------------- settings --
# ninaAPI, not Touch-N-Stars: different server, different route namespace. A
# 404 from one says nothing about the other. 1888 = ninaAPI, 5000 = TNS.
CAMANA_API="${CAMANA_API:-http://localhost:1888/v2/api}"
CAMANA_ROOT="${CAMANA_ROOT:-$HOME/camera-analysis}"
CAMANA_VENV="${CAMANA_VENV:-$CAMANA_ROOT/.venv}"
CAMANA_FRAMES="${CAMANA_FRAMES:-$CAMANA_ROOT/frames}"
CAMANA_OUT="${CAMANA_OUT:-$CAMANA_ROOT/out}"
CAMANA_MANIFEST="${CAMANA_MANIFEST:-$CAMANA_ROOT/manifest.json}"

# Where PINS writes its FITS. Must match the active profile's
# ImageFileSettings.FilePath; the mtime-scan fallback searches this tree.
CAMANA_IMAGE_PATH="${CAMANA_IMAGE_PATH:-$HOME/Documents/N.I.N.A}"

# ToupTek NATIVE PERCENT scale, range 100..10000. NOT the ZWO 0.1 dB scale.
CAMANA_GAINS="${CAMANA_GAINS:-100 200 300 500 800 1000 1500 2000 3000 5000}"
# ADU on the camera's 0..7936 offset scale (7936 = 31*256).
# 0 is in the list deliberately, even though it is already known to clip ~40%
# of pixels at gain 100. Without a TOO LOW case in the series the analyser can
# only report the lowest offset it tested, not that it is genuinely the
# minimum adequate one. One clipping row per gain is what makes "minimum"
# a measurement rather than an artefact of where the sweep started.
CAMANA_OFFSETS="${CAMANA_OFFSETS:-0 200 500 1000 1500 2000 2500}"

CAMANA_NBIAS="${CAMANA_NBIAS:-8}"
CAMANA_EXPOSURE="${CAMANA_EXPOSURE:-0.0001}"   # camera ExposureMin
# LED panels are PWM-dimmed. An exposure shorter than a few PWM periods
# integrates a varying number of pulses, so two "identical" flats differ by
# far more than shot noise and the conversion gain comes out nonsense. 2 s is
# the floor; longer is safer.
CAMANA_FLAT_EXPOSURE="${CAMANA_FLAT_EXPOSURE:-2.0}"
CAMANA_FLAT_GAINS="${CAMANA_FLAT_GAINS:-100 1000 3000}"
CAMANA_FLAT_OFFSET="${CAMANA_FLAT_OFFSET:-500}"
CAMANA_READOUT="${CAMANA_READOUT:-}"           # empty: leave the camera's own

# -- exposure-driven flats (--flat-auto) -------------------------------------
# The flat box on astrobit is bright and flicker-free: the sigma of a flat
# pair difference measured 228.2 ADU against 225.3 expected from pure shot
# noise, i.e. the variance is photon noise and nothing else. So illumination
# can stay FIXED and the signal level be set by EXPOSURE TIME, which needs no
# operator at the panel and is reproducible to the millisecond.
#
# The reference exposure per gain is not hardcoded: probe_exposure() finds the
# one giving CAMANA_FLAT_TARGET_PCT of full scale, so the stage transfers to a
# different flat panel, a different filter or a different camera unchanged.
#
# The ceiling matters. HCG's full well is 3x smaller than LCG's, so the
# right-hand tail of a flat reaches 65535 while the median is still only ~74%
# of full scale. The first HCG flat run reused the LCG exposures and saturated
# two of its four levels; saturation truncates the distribution, variance
# collapses, and signal/variance explodes -- e-/ADU came out 0.25, 0.26, 1.51,
# 1.16 at one gain, whose mean sits plausibly near the LCG value and is
# completely wrong. Drop CAMANA_FLAT_TARGET_PCT to about 58 for HCG.
CAMANA_FLAT_TARGET_PCT="${CAMANA_FLAT_TARGET_PCT:-70}"
# Fractions OF THE PROBED REFERENCE, not of full scale. Four levels spanning
# the photon-transfer curve: the low point anchors the read-noise end, the
# high one the shot-noise end, and the fit needs both.
CAMANA_FLAT_FRACTIONS="${CAMANA_FLAT_FRACTIONS:-0.14 0.35 0.68 0.95}"
CAMANA_FLAT_PAIRS="${CAMANA_FLAT_PAIRS:-2}"    # flats, and bias, per level
# How much light a flat-stage "bias" may carry before it is called out, in ADU
# above the offset. 20 is well under the point where conversion gain suffers;
# these frames are never valid for read noise at any leak level.
CAMANA_BIAS_LEAK_WARN="${CAMANA_BIAS_LEAK_WARN:-20}"

# -- linearity ramp (--linearity) --------------------------------------------
# Full well is usually quoted as e-/ADU * 65535, which assumes the response
# stays linear to the ADC ceiling. On this sensor it does (measured
# 2026-09-21, +-0.35% in both modes) -- but that is a measurement, not an
# assumption to inherit. Single frames, not pairs: this needs median versus
# exposure, not variance.
CAMANA_LIN_GAIN="${CAMANA_LIN_GAIN:-100}"
CAMANA_LIN_OFFSET="${CAMANA_LIN_OFFSET:-$CAMANA_FLAT_OFFSET}"
CAMANA_LIN_STEPS="${CAMANA_LIN_STEPS:-20}"
CAMANA_LIN_EMAX="${CAMANA_LIN_EMAX:-}"         # empty: probe it
# The ramp must run PAST saturation or there is nothing to fit a departure
# against. 1.4 x the target-percent exposure puts the top of the ramp at
# roughly 98% of full scale when the target is 70%, and flat on the ceiling
# for the last few steps.
CAMANA_LIN_OVERSHOOT="${CAMANA_LIN_OVERSHOOT:-1.4}"
# Where the straight line is fitted. Below this fraction of full scale the
# response is unambiguously linear on any sane sensor; extending the fit into
# the region under test would drag the reference towards the data and hide
# exactly the departure being looked for.
CAMANA_LIN_FIT_PCT="${CAMANA_LIN_FIT_PCT:-40}"

CAMANA_TIMEOUT="${CAMANA_TIMEOUT:-120}"        # seconds to wait for one frame
# Wedge avoidance and recovery. The SDK gives out after ~50 consecutive
# captures; one gain block at 7 offsets x 8 frames is 56, so the pause lands
# roughly where the trouble starts. Raise CAMANA_BLOCK_PAUSE if blocks still
# wedge, or drop CAMANA_NBIAS to shorten them.
CAMANA_BLOCK_PAUSE="${CAMANA_BLOCK_PAUSE:-45}"   # idle seconds between gain blocks
CAMANA_RECOVERY_PAUSE="${CAMANA_RECOVERY_PAUSE:-30}"  # idle seconds when recovering
CAMANA_MAX_RECOVERY="${CAMANA_MAX_RECOVERY:-3}"  # in-place recoveries before giving up
CAMANA_SETPOINT="${CAMANA_SETPOINT:-0}"          # re-applied after a reconnect
CAMANA_RECOOL="${CAMANA_RECOOL:-120}"            # seconds to re-reach the set point
FORCE=""

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
ANALYSER="${CAMANA_ANALYSER:-$SCRIPT_DIR/camera_analysis.py}"

# Saved at startup, restored by the EXIT trap.
ORIG_GAIN=""
ORIG_OFFSET=""
ORIG_READOUT=""

# Diagnostics go to stderr, never stdout. capture_frame returns the FITS path
# by printing it, so anything else written to stdout from inside it is
# captured into the caller's variable and ends up in the manifest. That is not
# hypothetical: a warn() added on the 500 path put
#   "\033[1;33m   WARN capture returned 500 ...\033[0m\n/path/to/frame.fits"
# into the `file` field of all 84 records of a run, every one of them
# unopenable, while the frames themselves sat valid on disk. stderr keeps the
# operator's view identical and the data path clean.
log()  { printf '\n\033[1;34m== %s\033[0m\n' "$*" >&2; }
info() { printf '   %s\n' "$*" >&2; }
warn() { printf '\033[1;33m   WARN %s\033[0m\n' "$*" >&2; }
bad()  { printf '\033[1;31m   NO   %s\033[0m\n' "$*" >&2; }
good() { printf '\033[1;32m   OK   %s\033[0m\n' "$*" >&2; }
# die <message> [exit-code]. The code is a SEPARATE positional, so the message
# must be $1 alone -- "$*" would print the code as part of the text.
die()  { printf '\033[1;31m   FAIL %s\033[0m\n' "$1" >&2; exit "${2:-1}"; }

usage() {
    # The banner is every comment line from the shebang down to the first
    # blank line. A hardcoded line range went stale the first time a stage was
    # added to the header and printed half a sentence; this cannot.
    sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
    cat <<EOF

Usage: $0 [options] <stage>

Stages:
  --setup      create \$CAMANA_VENV and install numpy astropy matplotlib
  --bias       acquire the gain x offset bias sweep
  --flat-auto  acquire flat pairs, exposure-driven and unattended  [preferred]
  --flat       acquire flat pairs (interactive: you dim the panel between
               levels). Kept for a dimmable panel; --flat-auto is the
               recommended path and needs no operator.
  --linearity  exposure ramp past saturation; fits the line and reports the
               slope, the max deviation below saturation and where the
               sensor first clips
  --analyse    run the analyser over the manifest
  --all        setup, bias, analyse

Options:
  -f, --force  proceed even though the cooler is off or not settled
  -h, --help   this text

Environment overrides:
  CAMANA_API          ninaAPI base   (default: http://localhost:1888/v2/api)
  CAMANA_ROOT         working tree   (default: \$HOME/camera-analysis)
  CAMANA_VENV         venv location  (default: \$CAMANA_ROOT/.venv)
  CAMANA_FRAMES       frame copies   (default: \$CAMANA_ROOT/frames)
  CAMANA_OUT          plots + report (default: \$CAMANA_ROOT/out)
  CAMANA_MANIFEST     manifest JSON  (default: \$CAMANA_ROOT/manifest.json)
  CAMANA_IMAGE_PATH   where PINS writes FITS; must match the active profile
  CAMANA_GAINS        gain sweep, ToupTek percent scale
  CAMANA_OFFSETS      offset sweep, ADU on the 0..7936 scale
  CAMANA_NBIAS        frames per (gain, offset)   (default: 8)
  CAMANA_FLAT_GAINS   gains for both flat stages
  CAMANA_FLAT_OFFSET  offset used during flats
  CAMANA_FLAT_EXPOSURE  --flat only: seconds, >= 2 for PWM-dimmed LED panels
  CAMANA_READOUT      readout mode index to force; empty leaves it alone
  CAMANA_TIMEOUT      per-frame wait, seconds  (default: 120)

--flat-auto:
  CAMANA_FLAT_TARGET_PCT  probed reference level, % of full scale
                          (default: $CAMANA_FLAT_TARGET_PCT; use ~58 for HCG,
                          whose 3x smaller full well saturates the tail first)
  CAMANA_FLAT_FRACTIONS   levels as fractions of that reference
                          (default: $CAMANA_FLAT_FRACTIONS)
  CAMANA_FLAT_PAIRS       flats, and bias, per level  (default: $CAMANA_FLAT_PAIRS)
  CAMANA_FLAT_PROBE_SEED  first probe exposure, seconds  (default: 0.05)

--linearity:
  CAMANA_LIN_GAIN      gain for the ramp        (default: $CAMANA_LIN_GAIN)
  CAMANA_LIN_OFFSET    offset for the ramp      (default: \$CAMANA_FLAT_OFFSET)
  CAMANA_LIN_STEPS     points in the ramp       (default: $CAMANA_LIN_STEPS)
  CAMANA_LIN_EMAX      top of the ramp, seconds; empty probes it
  CAMANA_LIN_OVERSHOOT probed reference x this  (default: $CAMANA_LIN_OVERSHOOT)
                       must carry the ramp PAST saturation
  CAMANA_LIN_FIT_PCT   fit the line below this % of full scale
                       (default: $CAMANA_LIN_FIT_PCT)

The sweep is set with ENVIRONMENT VARIABLES, not flags. There is
deliberately no --gains/--offsets: the sweep belongs with the other
CAMANA_* settings, and an env var survives being wrapped in a script or
recalled from shell history without retyping.

As currently configured: $(wc -w <<<"$CAMANA_GAINS") gains x $(wc -w <<<"$CAMANA_OFFSETS") offsets x $CAMANA_NBIAS frames
= $(( $(wc -w <<<"$CAMANA_GAINS") * $(wc -w <<<"$CAMANA_OFFSETS") * CAMANA_NBIAS )) frames, roughly $(( $(wc -w <<<"$CAMANA_GAINS") * $(wc -w <<<"$CAMANA_OFFSETS") * CAMANA_NBIAS * 50 / 1024 )) GB at ~50 MB per 26 Mpx frame.

  gains  : $CAMANA_GAINS
  offsets: $CAMANA_OFFSETS

To scout first, narrow it:

  CAMANA_GAINS="100 1000" CAMANA_OFFSETS="0 200 500" CAMANA_NBIAS=4 $0 --bias
EOF
    exit 0
}

# ------------------------------------------------------------------- api ---
# One indirection so no stage builds a URL by hand.

api_get() {
    # $1 endpoint (leading slash), rest: raw query string already encoded
    local endpoint="$1"; shift
    local query="${1:-}"
    local url="$CAMANA_API$endpoint"
    [[ -n "$query" ]] && url="$url?$query"
    curl -sS --max-time "$CAMANA_TIMEOUT" "$url" 2>/dev/null
}

# Pull one field out of a ninaAPI JSON response. python3 is guaranteed present
# on astrobit (3.14.7) and jq is not, so parse with python rather than adding
# a dependency for three lookups.
json_field() {
    # $1 json, $2 dotted path under .Response  (e.g. Gain, or Temperature)
    python3 -c '
import json, sys
try:
    doc = json.loads(sys.argv[1])
except Exception:
    sys.exit(1)
node = doc.get("Response", doc)
for key in sys.argv[2].split("."):
    if not isinstance(node, dict) or key not in node:
        sys.exit(1)
    node = node[key]
print(node)
' "$1" "$2" 2>/dev/null
}

camera_info() { api_get /equipment/camera/info; }

# --------------------------------------------------------------- preflight --

check_camera() {
    log "Camera"
    local info connected
    info=$(camera_info)
    [[ -n "$info" ]] || die "no answer from $CAMANA_API -- is PINS running?" 3

    connected=$(json_field "$info" Connected)
    if [[ "$connected" != "True" && "$connected" != "true" ]]; then
        die "camera reports Connected=$connected; connect it in Touch-N-Stars first" 3
    fi

    local name gain offset mode temp target target_src cooler
    name=$(json_field "$info" Name)
    gain=$(json_field "$info" Gain)
    offset=$(json_field "$info" Offset)
    mode=$(json_field "$info" ReadoutMode)
    temp=$(json_field "$info" Temperature)
    cooler=$(json_field "$info" CoolerOn)

    # The camera publishes TWO temperature targets and they disagree.
    # TemperatureSetPoint is what the cooler is actually regulating to;
    # TargetTemp is a separate profile field that the cooler may be ignoring
    # entirely. Observed on astrobit 2026-09-20: SetPoint -5, TargetTemp -10,
    # sensor holding -4.9 with the cooler at 70% -- i.e. settled on SetPoint
    # while 5C from TargetTemp. Checking TargetTemp rejected a properly
    # cooled camera. Regulate against the set point, fall back to TargetTemp
    # only when the set point is missing.
    local setpoint
    setpoint=$(json_field "$info" TemperatureSetPoint)
    target="$setpoint"
    if [[ -z "$target" || "$target" == "null" ]]; then
        target=$(json_field "$info" TargetTemp)
        target_src="TargetTemp (no set point published)"
    else
        target_src="TemperatureSetPoint"
    fi

    good "connected: ${name:-unknown}"
    info "gain $gain   offset $offset   readout mode $mode"
    info "temperature ${temp}C   target ${target}C ($target_src)   cooler $cooler"

    ORIG_GAIN="$gain"; ORIG_OFFSET="$offset"; ORIG_READOUT="$mode"

    # -- cooling ----------------------------------------------------------
    # Read noise depends weakly on temperature and dark current depends on it
    # exponentially. More to the point, a calibration library is only valid at
    # the temperature it was taken at, so an uncooled run produces numbers
    # that describe one evening and nothing else.
    local cold=1
    if [[ "$cooler" != "True" && "$cooler" != "true" ]]; then
        cold=0
    elif [[ -n "$temp" && -n "$target" ]]; then
        cold=$(python3 -c "
import sys
try:
    print(1 if abs(float(sys.argv[1]) - float(sys.argv[2])) <= 2.0 else 0)
except ValueError:
    print(0)
" "$temp" "$target")
    fi

    if (( cold == 0 )); then
        echo
        warn "############################################################"
        if [[ "$cooler" != "True" && "$cooler" != "true" ]]; then
            warn "COOLER IS OFF (sensor ${temp}C)"
        else
            warn "COOLER ON BUT NOT SETTLED: ${temp}C vs ${target}C set point"
        fi
        warn "############################################################"
        warn "Read noise, and far more so dark current, depend on sensor"
        warn "temperature. Frames taken now describe THIS sensor at THIS"
        warn "temperature and nothing else: the results will NOT be"
        warn "comparable across sessions, and the master bias you build"
        warn "from them will not match a cooled light frame."
        warn ""
        warn "Turn the cooler on, let it settle within 2C of target, and"
        warn "re-run. If you are only scouting the offset sweep and will"
        warn "redo it cooled, pass --force."
        [[ -n "$FORCE" ]] || die "refusing to acquire uncooled (use --force)" 4
        warn "--force given: continuing UNCOOLED. Treat the output as a"
        warn "rehearsal, not as a calibration."
    else
        good "cooled and settled"
    fi

    # -- the modes the API cannot see -------------------------------------
    # Camera custom actions are not exposed: /equipment/camera/action returns
    # 404 HTML, so SupportedActions ("Ultra Mode", "High Fullwell Mode",
    # "Bin Average", ...) can be listed but not read. Their state changes
    # conversion gain and full well outright, which means a report without
    # them recorded is not reproducible.
    echo
    warn "############################################################"
    warn "RECORD THESE BY HAND -- THE API CANNOT READ THEM"
    warn "############################################################"
    warn "  Ultra Mode          : ____________"
    warn "  High Fullwell Mode  : ____________"
    warn "  Bin Average         : ____________"
    warn ""
    warn "These are camera custom actions. ninaAPI exposes no route to"
    warn "query them (/equipment/camera/action 404s), so this script"
    warn "cannot log them for you. They change conversion gain and full"
    warn "well, so results are meaningless without knowing their state."
    warn "Check them in the ToupTek/INDI control panel and write them"
    warn "into $CAMANA_OUT/modes.txt before you trust the report."
    echo
}

# --------------------------------------------------- settings save/restore --

# Gain and offset reach the camera by two DIFFERENT routes, and neither is
# the obvious one. Verified against the ninaAPI source and live hardware on
# 2026-09-20:
#
#   /equipment/camera/set-gain    DOES NOT EXIST -> 404
#   /equipment/camera/set-offset  DOES NOT EXIST -> 404
#
# Gain is a query parameter of /equipment/camera/capture ([QueryField] int
# gain, Camera.cs:556) and is therefore set per exposure.
#
# Offset is NOT a capture parameter. It is only reachable as the profile
# default, /profile/change-value?settingpath=CameraSettings-Offset, which
# CameraVM.DefaultOffset backs and Capture() applies via SetOffset().
#
# THE OFFSET WRITE LIES. change-value answers {"Response":"Updated setting",
# "StatusCode":200} and /equipment/camera/info KEEPS REPORTING THE OLD VALUE,
# because info reads cam.GetInfo().Offset -- the driver's value -- while the
# write lands on the profile. Confirmed: profile set to 400, info still said
# 0, and the resulting frame carried OFFSET = 400 in its FITS header.
#
# So the API cannot confirm the offset. Only the written file can, which is
# why capture_frame verifies GAIN/OFFSET from the FITS header and treats a
# mismatch as a failed frame. Trusting the 200 here would have produced a
# full sweep of identically-offset frames and a confident, wrong report.

# Gain travels with each capture request, so there is nothing to set ahead of
# time and nothing to restore: a gain written for one exposure does not stick.
# Kept as a named no-op so the call sites read the same as set_offset's and
# nobody re-adds a 404 route here.
set_gain() { : "$1"; }

set_offset() {
    local response
    response=$(api_get /profile/change-value \
        "settingpath=CameraSettings-Offset&newValue=$1")
    if [[ "$response" != *'"Success":true'* ]]; then
        warn "offset write rejected for $1: ${response:0:160}"
        return 1
    fi
    # The profile write is asynchronous with respect to the next capture.
    sleep 0.4
    return 0
}

set_readout() {
    # THREE readout routes exist and only one affects captures:
    #
    #   /set-readout           -> cam.SetReadoutMode(mode)            WRONG
    #   /set-readout/image     -> ReadoutModeForNormalImages = mode   RIGHT
    #   /set-readout/snapshot  -> ReadoutModeForSnapImages = mode
    #
    # Verified 2026-09-21 by reading READOUTM out of the resulting FITS:
    # `/set-readout?mode=1` answered 200 "Readout mode updated" and the next
    # frame still carried "Low Conversion Gain". `/set-readout/image?mode=1`
    # produced "High Conversion Gain".
    #
    # And, as with offset, /equipment/camera/info does not reflect the write:
    # after a successful /set-readout/image it still reported ReadoutMode 0
    # and ReadoutModeForNormalImages 0 while the frames were genuinely HCG.
    # The FITS header is the only honest source -- third instance of that
    # pattern on this API, after the offset write and the 500-with-a-valid-
    # frame case.
    local response
    response=$(api_get /equipment/camera/set-readout/image "mode=$1")
    if [[ -z "$response" || "$response" == *"<html"* || "$response" == *"404"* ]]; then
        warn "set-readout/image not available on this ninaAPI build"
        warn "set the readout mode by hand in Touch-N-Stars and re-run;"
        warn "the manifest will record whatever the frames report"
        return 1
    fi
    return 0
}

restore_settings() {
    local status=$?
    # Gain and offset live in the ACTIVE PROFILE and persist across restarts.
    # Leaving the camera at gain 5000 offset 1500 after an interrupted sweep
    # would silently corrupt the next imaging session.
    if [[ -n "$ORIG_GAIN" ]]; then
        printf '\n\033[1;34m== Restoring camera settings\033[0m\n'
        set_gain "$ORIG_GAIN"
        set_offset "$ORIG_OFFSET"
        info "gain $ORIG_GAIN, offset $ORIG_OFFSET restored"
        if [[ -n "$CAMANA_READOUT" && -n "$ORIG_READOUT" ]]; then
            set_readout "$ORIG_READOUT" && info "readout mode $ORIG_READOUT restored"
        fi
    fi
    exit "$status"
}

# ------------------------------------------------------------- acquisition --

# Newest FITS anywhere under the image tree, by mtime. The fallback path: used
# when image-history does not name a file we can resolve.
newest_fits() {
    find "$CAMANA_IMAGE_PATH" -type f \( -name '*.fits' -o -name '*.fits.fz' \) \
        -newermt "@$1" -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -1 | cut -d' ' -f2-
}

# Ask image-history where the last frame landed. Preferred over the mtime scan
# because the profile's FilePattern nests by date and image type, and a
# concurrent write elsewhere in the tree would fool a pure mtime search.
history_newest_fits() {
    local response
    response=$(api_get /image-history "all=true")
    [[ -n "$response" ]] || return 1
    python3 -c '
import json, sys
try:
    doc = json.loads(sys.argv[1])
except Exception:
    sys.exit(1)
entries = doc.get("Response") or []
if not isinstance(entries, list) or not entries:
    sys.exit(1)
last = entries[-1]
if not isinstance(last, dict):
    sys.exit(1)
# ninaAPI has used several spellings across versions; try each rather than
# pinning one and silently returning nothing.
for key in ("FilePath", "Filepath", "Path", "File", "filePath"):
    value = last.get(key)
    if value:
        print(value)
        break
else:
    sys.exit(1)
' "$response" 2>/dev/null
}

# Take one frame and return the path it was written to, on stdout.
#   $1 exposure seconds, $2 gain, $3 offset, $4 kind (bias|flat)
capture_frame() {
    local exposure="$1" gain="$2" offset="$3" kind="$4"
    local started response path

    # Wait for the camera to go idle BEFORE asking for a frame. A 26 Mpx
    # ATR2600C frame is ~52 MB and the download plus FITS write outlasts the
    # 0.1 ms exposure by a wide margin. Fire the next capture too early and
    # ninaAPI answers 409 "Camera currently exposing", writes nothing, and the
    # frame is lost. The lag accumulates across a sweep, so the failures
    # cluster towards the end of a run and look like the last settings are
    # cursed -- they are not, the camera is simply still busy. Observed as 16
    # consecutive failures at the last two offsets of a gain block.
    #
    # IsExposing can also STICK. Interrupting a run leaves PINS reporting
    # IsExposing=True with CameraState=NoState -- claiming to expose while
    # reporting no state at all -- and it never clears on its own. Observed
    # after a Ctrl-C on 2026-09-20; it survived minutes of idling and only
    # /equipment/camera/abort-exposure cleared it. So this wait is bounded,
    # and on running out it aborts the phantom exposure rather than failing
    # every remaining frame of the sweep.
    local idle_wait=0 stuck=""
    while (( idle_wait < CAMANA_TIMEOUT )); do
        local state
        state=$(json_field "$(camera_info)" IsExposing)
        [[ "$state" != "True" && "$state" != "true" ]] && break
        sleep 1
        idle_wait=$(( idle_wait + 1 ))
        if (( idle_wait == 20 )); then stuck=1; break; fi
    done
    if [[ -n "$stuck" ]]; then
        warn "IsExposing stuck True for 20s -- aborting the phantom exposure"
        api_get /equipment/camera/abort-exposure >/dev/null
        sleep 2
    fi

    started=$(date +%s)
    # omitImage=true: the FITS is read from disk, so a base64 copy of a 26 Mpx
    # frame in the JSON body is pure overhead. waitForResult blocks until the
    # exposure and save are done.
    # No offset= here: capture has no such query field (see set_offset).
    # save=true and imageType=BIAS are what get the frame written to the
    # profile's image tree at all -- without save the capture happens and
    # nothing lands on disk.
    local attempt=0
    while :; do
        # onlySaveRaw=true and skipAutoStretch=true are not optimisations,
        # they are what makes the sweep finish. Without onlySaveRaw the
        # capture task renders the full 26 Mpx frame and writes it out as a
        # PNG next to the plugin assembly (Camera.cs:690-697) on every single
        # exposure, autostretching it first. On an N97 that dominates the
        # 0.1 ms exposure completely, IsExposing stays True for the whole
        # render, and the next request comes back 409 "Camera currently
        # exposing". The frame is then lost. Measured as one failure per
        # attempt before these two were added; the camera was not stuck, it
        # was busy producing a preview image nobody asked for.
        response=$(api_get /equipment/camera/capture \
            "duration=$exposure&gain=$gain&solve=false&omitImage=true&waitForResult=true&save=true&onlySaveRaw=true&skipAutoStretch=true&imageType=$kind")

        if [[ -z "$response" ]]; then
            warn "no response from capture (gain $gain offset $offset)"
            return 1
        fi

        # A 500 "Unknown error" does NOT mean no frame was written. Observed
        # 2026-09-20: the first capture after a PINS restart answered 500 and
        # the FITS was on disk, complete and valid (GAIN 100, OFFSET 500,
        # median 501.0, no clipped pixels). Fall through and let the file and
        # header checks below decide -- they are stricter than any status code
        # and they inspect the thing we actually care about.
        if [[ "$response" == *'"StatusCode":500'* ]]; then
            warn "capture returned 500 (gain $gain offset $offset) -- checking disk anyway"
        fi

        # Two different 409s share one status code and mean opposite things:
        #   "No capture processed"    -> nothing was pending, poll for it
        #   "Camera currently exposing" -> it is still busy, back off and retry
        if [[ "$response" == *"Camera currently exposing"* ]]; then
            attempt=$(( attempt + 1 ))
            if (( attempt >= 6 )); then
                warn "camera still busy after $attempt attempts (gain $gain offset $offset)"
                return 1
            fi
            sleep $(( attempt * 2 ))
            continue
        fi
        break
    done

    if [[ "$response" == *'"StatusCode":409'* || "$response" == *"No capture processed"* ]]; then
        local waited=0
        while (( waited < CAMANA_TIMEOUT )); do
            sleep 1
            waited=$(( waited + 1 ))
            response=$(api_get /equipment/camera/capture "getResult=true&omitImage=true")
            [[ "$response" == *'"StatusCode":200'* ]] && break
        done
    fi

    # Preferred: ask where it went. Fallback: newest file since we started.
    path=$(history_newest_fits)
    if [[ -z "$path" || ! -f "$path" ]]; then
        path=$(newest_fits "$started")
    fi
    if [[ -z "$path" || ! -f "$path" ]]; then
        warn "cannot locate the written FITS for gain $gain offset $offset"
        warn "check CAMANA_IMAGE_PATH=$CAMANA_IMAGE_PATH against the profile"
        return 1
    fi

    # Verify against the FITS header, not the API. The offset write reports
    # success whether or not it took effect (see set_offset), so the header
    # is the only evidence that this frame is the frame we asked for. A
    # mismatch here is a failed frame: silently keeping it would poison the
    # whole sweep with frames filed under settings they were not taken at.
    local hdr actual_gain actual_offset
    hdr=$("$CAMANA_VENV/bin/python" - "$path" <<'PY' 2>/dev/null
import sys
from astropy.io import fits
with fits.open(sys.argv[1]) as h:
    hd = h[0].header
    print(hd.get("GAIN", ""), hd.get("OFFSET", ""))
PY
)
    read -r actual_gain actual_offset <<<"$hdr"
    if [[ -n "$actual_gain" && "$actual_gain" != "$gain" ]]; then
        warn "frame says GAIN=$actual_gain, asked $gain -- discarding"
        return 1
    fi
    if [[ -n "$actual_offset" && "$actual_offset" != "$offset" ]]; then
        warn "frame says OFFSET=$actual_offset, asked $offset -- discarding"
        warn "the profile write did not reach the camera; is a sequence running?"
        return 1
    fi
    printf '%s\n' "$path"
}

# Append one record to the manifest. Written as one JSON object per line
# during acquisition and assembled into a list at the end, so an interrupted
# run still leaves parseable data rather than a truncated JSON array.
manifest_append() {
    local gain="$1" offset="$2" mode="$3" kind="$4" exposure="$5" file="$6"

    # Belt and braces after the stdout-capture bug: refuse to record a path
    # that is not a single existing file. A record whose `file` field carries
    # a stray log line is worse than a missing record -- it survives into the
    # analyser and fails there, long after the camera has moved on.
    if [[ "$file" != /* || "$file" == *$'\n'* || ! -f "$file" ]]; then
        warn "refusing to record a malformed path for gain $gain offset $offset"
        return 1
    fi

    python3 -c '
import json, sys
record = {
    "gain": int(sys.argv[1]),
    "offset": int(sys.argv[2]),
    "readout_mode": int(sys.argv[3]),
    "kind": sys.argv[4],
    "exposure": float(sys.argv[5]),
    "file": sys.argv[6],
    "timestamp": sys.argv[7],
}
print(json.dumps(record))
' "$gain" "$offset" "$mode" "$kind" "$exposure" "$file" "$(date -Iseconds)" \
        >> "$CAMANA_MANIFEST.jsonl"
}

manifest_finalise() {
    python3 -c '
import json, sys
from pathlib import Path
lines = Path(sys.argv[1]).read_text().splitlines()
records = [json.loads(line) for line in lines if line.strip()]
Path(sys.argv[2]).write_text(json.dumps(records, indent=2))
print(len(records))
' "$CAMANA_MANIFEST.jsonl" "$CAMANA_MANIFEST" 2>/dev/null
}

current_readout() {
    # CAMANA_READOUT is what we asked for, and after set_readout the frames
    # follow it even though camera/info does not (see set_readout). Trust the
    # request over the API's own report; the analyser cross-checks the FITS
    # READOUTM keyword anyway, so a mismatch surfaces in the report rather
    # than being silently baked into the manifest.
    if [[ -n "$CAMANA_READOUT" ]]; then
        printf '%s\n' "$CAMANA_READOUT"
        return
    fi
    local mode
    mode=$(json_field "$(camera_info)" ReadoutModeForNormalImages)
    printf '%s\n' "${mode:-0}"
}

# ------------------------------------------------- exposure-driven helpers --

# Median and saturated-pixel count of one FITS, printed as "median satcount".
#
# The central region only. A flat panel is not perfectly uniform and the
# corners of a 26 Mpx APS-C frame vignette by several percent, so a
# whole-frame median mixes illumination gradient into the signal level and the
# probe converges on the wrong exposure. 2000x3000 centre is what the
# conversion-gain measurement used.
#
# Saturation is counted separately and it matters more than the median: on
# 2026-09-21 an LCG frame with 8183 saturated pixels still had a median of
# 56166 ADU sitting dead on the linear fit. The right-hand tail touches the
# ceiling long before the average pixel does, so a flat is judged by its
# saturated-pixel count, not by its median alone.
frame_stats() {
    "$CAMANA_VENV/bin/python" - "$1" <<'PY' 2>/dev/null
import sys
import numpy as np
from astropy.io import fits
with fits.open(sys.argv[1]) as handle:
    data = handle[0].data
rows, cols = data.shape[-2:]
half_r, half_c = min(1000, rows // 2), min(1500, cols // 2)
centre = data[
    rows // 2 - half_r : rows // 2 + half_r,
    cols // 2 - half_c : cols // 2 + half_c,
]
print(float(np.median(centre)), int(np.count_nonzero(data >= 65535)))
PY
}

# Find the exposure putting the central median at CAMANA_FLAT_TARGET_PCT of
# full scale, for one gain. Prints the exposure on stdout; everything else
# goes to stderr, same contract as capture_frame.
#
#   $1 gain, $2 offset, $3 readout mode
#
# Two phases. A geometric search brackets the target by doubling or halving
# from a seed, then a short bisection closes in. Bisection alone needs a
# bracket to start from and the useful exposures here span four orders of
# magnitude across gain and readout mode -- 0.2 s at LCG gain 100 down to
# 0.0033 s at HCG gain 2000 -- so guessing a bracket is what the hardcoded
# exposures in the ad-hoc scripts were doing, and what this replaces.
#
# The response is very nearly linear (measured, see --linearity), so each
# geometric step could in principle jump straight to target by scaling. It
# does not: near saturation the median stops responding to exposure at all
# and a linear extrapolation from a clipped frame overshoots wildly. Doubling
# is slower and cannot be fooled that way.
probe_exposure() {
    local gain="$1" offset="$2" mode="$3"
    local target exposure path stats median satcount
    target=$(python3 -c "print(65535.0 * $CAMANA_FLAT_TARGET_PCT / 100.0)")

    # Seed from the bias level, not from zero: the offset is already sitting
    # at $offset ADU and contributes nothing to signal.
    exposure="${CAMANA_FLAT_PROBE_SEED:-0.05}"

    local step=0 low="" high=""
    while (( step < 12 )); do
        step=$(( step + 1 ))
        if ! path=$(capture_frame "$exposure" "$gain" "$offset" flat); then
            warn "probe frame failed at ${exposure}s (gain $gain)"
            return 1
        fi
        stats=$(frame_stats "$path")
        read -r median satcount <<<"$stats"
        [[ -n "$median" ]] || { warn "cannot read $path"; return 1; }

        info "$(printf '  probe %2d: %.6fs -> median %8.1f ADU (%.0f%% FS, %d sat)' \
            "$step" "$exposure" "$median" \
            "$(python3 -c "print(100.0*$median/65535.0)")" "$satcount")"

        # Within 8% of target, and nothing clipped: good enough. The levels
        # are scaled off this exposure anyway, so a few percent of error moves
        # every level together and changes no conclusion. Chasing 1% would
        # cost several more frames against the SDK's capture budget.
        local verdict
        verdict=$(python3 -c "
median, target, sat = $median, $target, $satcount
print('high' if sat > 0 or median > target * 1.08
      else 'low' if median < target * 0.92
      else 'ok')")
        case "$verdict" in
            ok)   printf '%s\n' "$exposure"; return 0 ;;
            low)  low="$exposure" ;;
            high) high="$exposure" ;;
        esac

        if [[ -n "$low" && -n "$high" ]]; then
            exposure=$(python3 -c "print(f'{($low + $high) / 2.0:.6f}')")
        elif [[ "$verdict" == "low" ]]; then
            exposure=$(python3 -c "print(f'{$exposure * 2.0:.6f}')")
        else
            exposure=$(python3 -c "print(f'{$exposure / 2.0:.6f}')")
        fi

        # Below the camera's ExposureMin the request is silently clamped and
        # the search would spin forever comparing identical frames.
        if python3 -c "import sys; sys.exit(0 if $exposure < 0.0002 else 1)"; then
            warn "probe hit the exposure floor at gain $gain: the panel is"
            warn "too bright for this gain and readout mode. Dim it, or drop"
            warn "the gain, or lower CAMANA_FLAT_TARGET_PCT."
            return 1
        fi
    done

    warn "probe did not converge in $step frames at gain $gain"
    return 1
}

# Pause between blocks, with the sensor temperature logged. Same reasoning as
# stage_bias's inter-block pause: the SDK gives out after ~50 consecutive
# captures, so no stage may run an unbroken sequence near that. See
# BUILD-NOTES.md, "BLOCKED SWEEP: 42-FRAME BLOCKS WITH A PAUSE BETWEEN THEM".
block_pause() {
    (( CAMANA_BLOCK_PAUSE > 0 )) || return 0
    echo
    info "pausing ${CAMANA_BLOCK_PAUSE}s before $1"
    sleep "$CAMANA_BLOCK_PAUSE"
    local temp
    temp=$(json_field "$(camera_info)" Temperature)
    info "sensor at ${temp}C, resuming"
}

# One throwaway frame to prove the SDK is alive before committing to a stage.
# Lifted out of stage_bias so --flat-auto and --linearity get the same guard:
# a wedged SDK fails every capture after a 60 s timeout, so starting on one
# burns a minute per frame producing nothing, and the failure looks like a
# problem with the first setting rather than with the driver.
#
# The offset MUST be applied first. capture_frame verifies GAIN/OFFSET against
# the FITS header and discards a mismatch, so probing without setting the
# offset fails against a perfectly healthy driver -- the frame arrives
# carrying whatever offset the previous run's restore left behind. That
# misdiagnosis cost a PINS restart on 2026-09-21.
probe_sdk() {
    local offset="$1"
    info "probing the SDK before starting"
    set_offset "$offset"
    sleep 0.5
    if capture_frame "$CAMANA_EXPOSURE" 100 "$offset" bias >/dev/null; then
        good "SDK responding"
        return 0
    fi
    warn "the probe frame failed: the SDK is wedged before the stage began."
    warn "Restart PINS, reconnect the camera and let it re-cool:"
    warn "  ~/pins/build/pins/x64-port/stop-pins.sh"
    warn "  ~/pins/build/pins/x64-port/start-pins.sh"
    return 1
}

# ----------------------------------------------------------------- stages --

stage_setup() {
    log "Setting up the analysis venv"
    mkdir -p "$CAMANA_ROOT" "$CAMANA_FRAMES" "$CAMANA_OUT"

    # CachyOS/Arch is externally managed: a bare pip install fails by design.
    if [[ -x "$CAMANA_VENV/bin/python" ]]; then
        good "venv already at $CAMANA_VENV"
    else
        python3 -m venv "$CAMANA_VENV" || die "cannot create venv at $CAMANA_VENV"
        good "created $CAMANA_VENV"
    fi

    info "installing numpy astropy matplotlib (idempotent)"
    "$CAMANA_VENV/bin/pip" install --quiet --upgrade pip \
        || warn "pip self-upgrade failed; continuing"
    "$CAMANA_VENV/bin/pip" install --quiet numpy astropy matplotlib \
        || die "package install failed"

    "$CAMANA_VENV/bin/python" -c 'import numpy, astropy, matplotlib' \
        || die "packages installed but do not import"
    good "numpy, astropy, matplotlib available"

    log "Validating the estimators before any hardware is touched"
    if "$CAMANA_VENV/bin/python" "$ANALYSER" --selftest; then
        good "self-test passed: the maths recovers known values"
    else
        die "self-test FAILED -- do not trust the analyser, fix it first"
    fi
}

# Try to unstick the ToupTek SDK without restarting PINS.
#
# Observed twice on 2026-09-21: the SDK wedges after roughly 50 consecutive
# captures, whether or not the sweep is interrupted. Every capture then times
# out after 60 s with CameraDownloadFailedException while the camera still
# reports Connected. A PINS restart always clears it; this tries the cheaper
# escalation first, because a restart costs a re-cool from ambient and the
# whole run.
#
# The ladder, cheapest first:
#   1. abort-exposure        -- clears a stuck IsExposing
#   2. idle pause            -- lets whatever transfer is in flight drain
#   3. disconnect/reconnect  -- reinitialises the camera handle
# Step 3 did NOT help on 2026-09-20, so this is not expected to succeed often.
# It is worth attempting because the alternative is abandoning the run.
recover_sdk() {
    local offset="${1:-0}"
    api_get /equipment/camera/abort-exposure >/dev/null 2>&1
    sleep 3
    if capture_frame "$CAMANA_EXPOSURE" 100 "$offset" bias >/dev/null 2>&1; then
        return 0
    fi

    info "abort alone did not help; idling ${CAMANA_RECOVERY_PAUSE}s"
    sleep "$CAMANA_RECOVERY_PAUSE"
    if capture_frame "$CAMANA_EXPOSURE" 100 "$offset" bias >/dev/null 2>&1; then
        return 0
    fi

    info "idle did not help; reconnecting the camera"
    api_get /equipment/camera/disconnect >/dev/null 2>&1
    sleep 5
    api_get /equipment/camera/connect >/dev/null 2>&1
    sleep 8
    api_get /equipment/camera/cool "temperature=${CAMANA_SETPOINT}&minutes=0&cancel=false" >/dev/null 2>&1
    info "reconnected; waiting ${CAMANA_RECOOL}s for the set point"
    sleep "$CAMANA_RECOOL"
    capture_frame "$CAMANA_EXPOSURE" 100 "$offset" bias >/dev/null 2>&1
}

stage_bias() {
    check_camera
    trap restore_settings EXIT
    mkdir -p "$CAMANA_ROOT" "$CAMANA_FRAMES" "$CAMANA_OUT"

    local mode
    if [[ -n "$CAMANA_READOUT" ]]; then
        set_readout "$CAMANA_READOUT"
    fi
    mode=$(current_readout)

    local n_gains n_offsets total
    n_gains=$(wc -w <<<"$CAMANA_GAINS")
    n_offsets=$(wc -w <<<"$CAMANA_OFFSETS")
    total=$(( n_gains * n_offsets * CAMANA_NBIAS ))

    log "Bias sweep"
    info "gains  : $CAMANA_GAINS"
    info "offsets: $CAMANA_OFFSETS"
    info "$CAMANA_NBIAS frames each, ${CAMANA_EXPOSURE}s, readout mode $mode"
    info "$total frames total"
    warn "COVER THE TELESCOPE. A bias frame must see no light at all;"
    warn "a light leak raises the floor and the offset verdict comes out"
    warn "optimistic -- the one direction that matters."
    echo
    read -r -p "   Covered and ready? [y/N] " answer
    [[ "$answer" =~ ^[Yy] ]] || die "aborted at the user's request" 0

    # Prove the SDK is healthy BEFORE committing to the sweep. One throwaway
    # frame costs four seconds and tells the difference between a wedged
    # driver and a genuine problem with the first gain/offset.
    probe_sdk "${CAMANA_OFFSETS%% *}" || die "refusing to start against a wedged SDK" 1
    info "starting the sweep"

    local done=0 failed=0 consecutive=0 recoveries=0 block=0 gain offset frame path
    for gain in $CAMANA_GAINS; do
        # Pause between gain blocks. The SDK wedges after ~50 consecutive
        # captures, and a gain block here is 6 offsets x NBIAS frames, so a
        # block sits just under that threshold by design. The pause lets the
        # USB pipeline and the sensor settle between blocks -- the cheap
        # preventive measure, as opposed to recover_sdk's cure.
        if (( block > 0 )); then
            block_pause "gain $gain (block $block done)"
        fi
        block=$(( block + 1 ))
        set_gain "$gain"
        for offset in $CAMANA_OFFSETS; do
            set_offset "$offset"
            # The driver applies gain/offset on the next exposure; a short
            # settle avoids the first frame of a set carrying the previous
            # setting, which would poison exactly the pair used for read noise.
            sleep 0.5
            for (( frame = 0; frame < CAMANA_NBIAS; frame++ )); do
                if path=$(capture_frame "$CAMANA_EXPOSURE" "$gain" "$offset" bias); then
                    manifest_append "$gain" "$offset" "$mode" bias \
                        "$CAMANA_EXPOSURE" "$path"
                    done=$(( done + 1 ))
                    consecutive=0
                else
                    failed=$(( failed + 1 ))
                    consecutive=$(( consecutive + 1 ))
                    # The ToupTek SDK can wedge: every capture then times out
                    # after 60 s with CameraDownloadFailedException, the camera
                    # still reporting Connected, and disconnect/connect does
                    # NOT clear it -- the state is in the SDK loaded into the
                    # PINS process. Only stop-pins.sh + start-pins.sh does.
                    # Grinding through the rest of the sweep in that state
                    # costs an hour and yields nothing, so stop and say so.
                    if (( consecutive >= 5 )); then
                        echo
                        warn "5 captures in a row failed at gain $gain offset $offset"
                        if (( recoveries >= CAMANA_MAX_RECOVERY )); then
                            warn "already recovered $recoveries time(s); giving up."
                            warn "Restart PINS and re-run:"
                            warn "  ~/pins/build/pins/x64-port/stop-pins.sh"
                            warn "  ~/pins/build/pins/x64-port/start-pins.sh"
                            warn "$done frame(s) are already in the manifest and keep."
                            break 3
                        fi
                        recoveries=$(( recoveries + 1 ))
                        warn "attempting in-place recovery $recoveries/$CAMANA_MAX_RECOVERY"
                        if recover_sdk "$offset"; then
                            good "recovered without restarting PINS; continuing"
                            consecutive=0
                            frame=$(( frame - 1 ))   # retry this frame
                            continue
                        fi
                        warn "recovery failed -- the SDK needs a PINS restart:"
                        warn "  ~/pins/build/pins/x64-port/stop-pins.sh"
                        warn "  ~/pins/build/pins/x64-port/start-pins.sh"
                        warn "$done frame(s) are already in the manifest and keep."
                        break 3
                    fi
                fi
                printf '\r   gain %5s offset %5s  frame %2d/%d   [%d/%d done, %d failed]   ' \
                    "$gain" "$offset" "$(( frame + 1 ))" "$CAMANA_NBIAS" \
                    "$done" "$total" "$failed"
            done
        done
    done
    echo

    local count
    count=$(manifest_finalise)
    good "$done frame(s) acquired, $failed failed"
    good "manifest: $CAMANA_MANIFEST ($count records)"
    (( failed == 0 )) || warn "some captures failed; the analyser will use what exists"
}

# Report how much light a "bias" taken beside the flats is actually carrying.
#
# The flat stages need a bias pair at matching settings to subtract the
# read-noise term from the flat difference, but they run with the panel lit,
# so those frames are not dark. This measures the leak rather than assuming
# it: the median should sit at the offset, and anything above it is light.
#
# A small leak is harmless for conversion gain and fatal for read noise, which
# is the distinction the `bias_lit` kind exists to keep. This warns when the
# leak is large enough that even the conversion gain starts to suffer.
check_bias_leak() {
    local path="$1" gain="$2" median excess
    median=$("$CAMANA_VENV/bin/python" - "$path" <<'PY' 2>/dev/null
import sys
import numpy as np
from astropy.io import fits
with fits.open(sys.argv[1]) as h:
    for hdu in h:
        if hdu.data is not None and hdu.data.ndim == 2:
            print(int(np.median(hdu.data)))
            break
PY
)
    [[ -z "$median" ]] && return 0
    excess=$(( median - CAMANA_FLAT_OFFSET ))
    (( excess < 0 )) && excess=0
    if (( excess > CAMANA_BIAS_LEAK_WARN )); then
        warn "gain $gain: 'bias' median $median vs offset $CAMANA_FLAT_OFFSET"
        warn "  -> ${excess} ADU of light is reaching the sensor at ${CAMANA_EXPOSURE}s."
        warn "  Conversion gain tolerates this; read noise from these frames"
        warn "  would be wrong. Use the bias sweep for read noise."
    fi
    return 0
}

stage_flat() {
    check_camera
    trap restore_settings EXIT
    mkdir -p "$CAMANA_ROOT" "$CAMANA_FRAMES" "$CAMANA_OUT"

    local mode
    mode=$(current_readout)

    log "Flat pairs for conversion gain"
    info "gains  : $CAMANA_FLAT_GAINS   offset: $CAMANA_FLAT_OFFSET"
    info "exposure: ${CAMANA_FLAT_EXPOSURE}s, readout mode $mode"
    echo
    warn "LED PANEL FLICKER"
    warn "Panels are dimmed by PWM. An exposure shorter than a few PWM"
    warn "periods integrates a varying number of pulses, so two nominally"
    warn "identical flats differ by far more than shot noise -- and the"
    warn "conversion gain, which is signal over that variance, comes out"
    warn "wrong by whatever the flicker contributed. Keep exposures at or"
    warn "above 2 s and dim the panel by covering it, not by lowering its"
    warn "brightness setting."
    echo
    info "You will be asked to set several illumination levels. Aim for"
    info "roughly 10%, 25%, 50% and 70% of full scale (6500, 16000, 32000,"
    info "46000 ADU). Stay below 80%: the sensor departs from linearity"
    info "near saturation and the photon transfer curve bends."
    echo

    local level=0 gain path_a path_b bias_a bias_b
    while true; do
        level=$(( level + 1 ))
        echo
        read -r -p "   Set illumination level $level, then press Enter (or 'q' to stop): " answer
        [[ "$answer" =~ ^[Qq] ]] && break

        for gain in $CAMANA_FLAT_GAINS; do
            set_gain "$gain"
            set_offset "$CAMANA_FLAT_OFFSET"
            sleep 0.5

            info "gain $gain: flat pair"
            path_a=$(capture_frame "$CAMANA_FLAT_EXPOSURE" "$gain" "$CAMANA_FLAT_OFFSET" flat) \
                || { warn "flat A failed at gain $gain"; continue; }
            path_b=$(capture_frame "$CAMANA_FLAT_EXPOSURE" "$gain" "$CAMANA_FLAT_OFFSET" flat) \
                || { warn "flat B failed at gain $gain"; continue; }
            manifest_append "$gain" "$CAMANA_FLAT_OFFSET" "$mode" flat \
                "$CAMANA_FLAT_EXPOSURE" "$path_a"
            manifest_append "$gain" "$CAMANA_FLAT_OFFSET" "$mode" flat \
                "$CAMANA_FLAT_EXPOSURE" "$path_b"

            # A matching bias pair at the same settings: conversion gain needs
            # it to subtract the read-noise term from the flat difference.
            info "gain $gain: matching bias pair"
            bias_a=$(capture_frame "$CAMANA_EXPOSURE" "$gain" "$CAMANA_FLAT_OFFSET" bias_lit) \
                || { warn "bias A failed at gain $gain"; continue; }
            bias_b=$(capture_frame "$CAMANA_EXPOSURE" "$gain" "$CAMANA_FLAT_OFFSET" bias_lit) \
                || { warn "bias B failed at gain $gain"; continue; }
            check_bias_leak "$bias_a" "$gain"
            manifest_append "$gain" "$CAMANA_FLAT_OFFSET" "$mode" bias_lit \
                "$CAMANA_EXPOSURE" "$bias_a"
            manifest_append "$gain" "$CAMANA_FLAT_OFFSET" "$mode" bias_lit \
                "$CAMANA_EXPOSURE" "$bias_b"
            good "gain $gain done"
        done
    done

    local count
    count=$(manifest_finalise)
    good "manifest: $CAMANA_MANIFEST ($count records)"
}

# Exposure-driven flats. The recommended path: no operator at the panel, no
# hand-calibrated exposures, and reproducible to the millisecond.
#
# Illumination stays fixed and the signal level is set by exposure time,
# scaled off a per-gain reference that probe_exposure() measures rather than
# assumes. The ad-hoc scripts this replaces carried the reference exposures as
# literals -- 100:0.2 1000:0.02 2000:0.01 for LCG, a different triple for HCG
# -- which meant a new panel, filter or camera invalidated the script silently.
#
# Per gain: CAMANA_FLAT_PAIRS flats + the same number of bias, at each of the
# CAMANA_FLAT_FRACTIONS levels.
stage_flat_auto() {
    check_camera
    trap restore_settings EXIT
    mkdir -p "$CAMANA_ROOT" "$CAMANA_FRAMES" "$CAMANA_OUT"

    [[ -x "$CAMANA_VENV/bin/python" ]] \
        || die "no venv at $CAMANA_VENV -- run --setup first (probing needs astropy)" 1

    local mode
    if [[ -n "$CAMANA_READOUT" ]]; then
        set_readout "$CAMANA_READOUT"
    fi
    mode=$(current_readout)

    local n_gains n_levels total
    n_gains=$(wc -w <<<"$CAMANA_FLAT_GAINS")
    n_levels=$(wc -w <<<"$CAMANA_FLAT_FRACTIONS")
    total=$(( n_gains * n_levels * CAMANA_FLAT_PAIRS * 2 ))

    log "Exposure-driven flat pairs for conversion gain"
    info "gains   : $CAMANA_FLAT_GAINS   offset: $CAMANA_FLAT_OFFSET"
    info "levels  : $CAMANA_FLAT_FRACTIONS of the ${CAMANA_FLAT_TARGET_PCT}% reference"
    info "readout mode $mode, $CAMANA_FLAT_PAIRS flat + $CAMANA_FLAT_PAIRS bias per level"
    info "$total frames plus probing, ~$(( n_gains * 6 )) probe frames"
    echo
    warn "UNCOVER THE FLAT PANEL and leave it ALONE for the whole stage."
    warn "The illumination is held FIXED; the signal level is set by exposure"
    warn "time. Touching the panel mid-run decouples the levels from the"
    warn "probed reference and every conversion gain after it is wrong."
    echo
    if [[ "$mode" != "0" ]]; then
        warn "Readout mode $mode is not LCG. If this is HCG, its full well is"
        warn "3x smaller and the tail saturates while the median still looks"
        warn "safe -- set CAMANA_FLAT_TARGET_PCT=58 rather than the default"
        warn "$CAMANA_FLAT_TARGET_PCT. See BUILD-NOTES.md, 'CONVERSION GAIN MEASURED'."
        echo
    fi

    probe_sdk "$CAMANA_FLAT_OFFSET" || die "refusing to start against a wedged SDK" 1

    local done=0 failed=0 block=0 gain frac exposure reference level rep path

    for gain in $CAMANA_FLAT_GAINS; do
        if (( block > 0 )); then
            block_pause "gain $gain (block $block done)"
        fi
        block=$(( block + 1 ))

        set_gain "$gain"
        set_offset "$CAMANA_FLAT_OFFSET"
        sleep 0.5

        log "gain $gain: probing the ${CAMANA_FLAT_TARGET_PCT}% exposure"
        if ! reference=$(probe_exposure "$gain" "$CAMANA_FLAT_OFFSET" "$mode"); then
            warn "no reference exposure at gain $gain -- skipping this gain"
            failed=$(( failed + n_levels * CAMANA_FLAT_PAIRS * 2 ))
            continue
        fi
        good "gain $gain: ${CAMANA_FLAT_TARGET_PCT}% of full scale at ${reference}s"

        level=0
        for frac in $CAMANA_FLAT_FRACTIONS; do
            level=$(( level + 1 ))
            exposure=$(python3 -c "print(f'{$reference * $frac:.6f}')")
            info "gain $gain level $level/$n_levels: ${exposure}s (~$(python3 -c \
                "print(f'{$frac * $CAMANA_FLAT_TARGET_PCT:.0f}')")% of full scale)"

            for (( rep = 0; rep < CAMANA_FLAT_PAIRS; rep++ )); do
                if path=$(capture_frame "$exposure" "$gain" "$CAMANA_FLAT_OFFSET" flat); then
                    manifest_append "$gain" "$CAMANA_FLAT_OFFSET" "$mode" flat \
                        "$exposure" "$path" && done=$(( done + 1 ))
                else
                    warn "flat $((rep + 1)) failed at gain $gain level $level"
                    failed=$(( failed + 1 ))
                fi
            done

            # A matching bias pair at the SAME gain, offset and readout mode.
            # Conversion gain is signal over the shot-noise variance, and the
            # read-noise term has to come out of the flat difference:
            #   g = signal / (var(f1-f2)/2 - var(b1-b2)/2)
            # A bias pair from another gain does not subtract the right
            # amount, and at low signal levels the read-noise term is most of
            # the variance -- which is exactly where the low levels live.
            #
            # THESE ARE NOT DARK BIAS. The panel is lit and the scope is
            # uncovered, so they carry whatever light leaks in at the minimum
            # exposure. Harmless for conversion gain -- contamination enters
            # signal and variance alike and cancels in the ratio -- but it
            # makes them **useless for read noise**, and using them that way
            # overstated read noise by a factor of two on 2026-09-21 before
            # the error was caught. Recorded as `bias_lit` so nothing can
            # mistake them for the real thing; read noise comes from the bias
            # sweep, shot with the scope capped.
            for (( rep = 0; rep < CAMANA_FLAT_PAIRS; rep++ )); do
                if path=$(capture_frame "$CAMANA_EXPOSURE" "$gain" "$CAMANA_FLAT_OFFSET" bias_lit); then
                    manifest_append "$gain" "$CAMANA_FLAT_OFFSET" "$mode" bias_lit \
                        "$CAMANA_EXPOSURE" "$path" && done=$(( done + 1 ))
                    check_bias_leak "$path" "$gain"
                else
                    warn "bias $((rep + 1)) failed at gain $gain level $level"
                    failed=$(( failed + 1 ))
                fi
            done
        done
        good "gain $gain done"
    done

    local count
    count=$(manifest_finalise)
    good "$done frame(s) acquired, $failed failed"
    good "manifest: $CAMANA_MANIFEST ($count records)"

    # The analyser groups frames by (gain, offset, readout_mode, kind) and
    # uses the first pair of each group, so four exposure levels at one gain
    # collapse into one frameset and only the lowest level is measured. That
    # is not a bug to work around here -- it is a property of camera_analysis.py
    # that the operator has to know about. Say so plainly rather than letting
    # a report quietly describe one level out of four.
    echo
    warn "FOUR LEVELS PER GAIN, ONE FRAMESET PER GAIN"
    warn "camera_analysis.py keys frame sets on (gain, offset, readout mode,"
    warn "kind) and reads the first pair of each. Running --analyse over this"
    warn "manifest measures the FIRST level only; the other three are on disk"
    warn "and in the manifest but unused."
    warn ""
    warn "For the per-level photon-transfer curve, split the manifest by"
    warn "exposure and analyse each level separately:"
    warn "  python3 - <<'EOF'"
    warn "  import json, pathlib"
    warn "  recs = json.loads(pathlib.Path('$CAMANA_MANIFEST').read_text())"
    warn "  flats = sorted({r['exposure'] for r in recs if r['kind'] == 'flat'})"
    warn "  for i, e in enumerate(flats, 1):"
    warn "      keep = [r for r in recs"
    warn "              if r['kind'] == 'bias' or r['exposure'] == e]"
    warn "      pathlib.Path(f'level{i}.json').write_text(json.dumps(keep))"
    warn "  EOF"
    warn "then run --analyse with CAMANA_MANIFEST pointed at each in turn."
    warn "A large scatter in e-/ADU between levels is evidence of saturation,"
    warn "not of noise -- see BUILD-NOTES.md, 'A methodological note'."
}

# Linearity ramp: where does the response stop being a straight line, and what
# is the usable full well?
#
# Single frames, not pairs: this needs the median against exposure, not
# variance. Twenty of them stepped evenly to an exposure past saturation, a
# line fitted through the low end, and the measured median compared to it.
stage_linearity() {
    check_camera
    trap restore_settings EXIT
    mkdir -p "$CAMANA_ROOT" "$CAMANA_FRAMES" "$CAMANA_OUT"

    [[ -x "$CAMANA_VENV/bin/python" ]] \
        || die "no venv at $CAMANA_VENV -- run --setup first (the fit needs numpy)" 1

    local mode
    if [[ -n "$CAMANA_READOUT" ]]; then
        set_readout "$CAMANA_READOUT"
    fi
    mode=$(current_readout)

    log "Linearity ramp"
    info "gain $CAMANA_LIN_GAIN, offset $CAMANA_LIN_OFFSET, readout mode $mode"
    info "$CAMANA_LIN_STEPS steps, single frames"
    echo
    warn "UNCOVER THE FLAT PANEL and leave it ALONE. As with --flat-auto the"
    warn "illumination is fixed and the ramp is in exposure time; a panel"
    warn "touched mid-ramp puts a step in the data that looks like a knee."
    echo

    probe_sdk "$CAMANA_LIN_OFFSET" || die "refusing to start against a wedged SDK" 1

    set_gain "$CAMANA_LIN_GAIN"
    set_offset "$CAMANA_LIN_OFFSET"
    sleep 0.5

    # The top of the ramp. Probed unless given, then scaled up so the last
    # steps sit on the ADC ceiling -- without points past saturation there is
    # nothing for the departure from the fit to be measured against.
    local emax
    if [[ -n "$CAMANA_LIN_EMAX" ]]; then
        emax="$CAMANA_LIN_EMAX"
        info "top of ramp: ${emax}s (CAMANA_LIN_EMAX)"
    else
        log "probing the ${CAMANA_FLAT_TARGET_PCT}% exposure to scale the ramp"
        local reference
        reference=$(probe_exposure "$CAMANA_LIN_GAIN" "$CAMANA_LIN_OFFSET" "$mode") \
            || die "cannot probe the ramp: set CAMANA_LIN_EMAX by hand" 1
        emax=$(python3 -c "print(f'{$reference * $CAMANA_LIN_OVERSHOOT:.6f}')")
        good "${CAMANA_FLAT_TARGET_PCT}% at ${reference}s; ramping to ${emax}s"
    fi

    local ramp="$CAMANA_ROOT/linearity.jsonl"
    : > "$ramp"

    local step exposure path stats median satcount captured=0 failed=0
    for (( step = 1; step <= CAMANA_LIN_STEPS; step++ )); do
        # Pause partway through. A 20-step ramp is well under the ~50-capture
        # wedge threshold on its own, but the probe frames came out of the
        # same budget and --linearity is usually run straight after
        # --flat-auto in the same session.
        if (( step > 1 && step % 15 == 1 )); then
            block_pause "step $step"
        fi

        exposure=$(python3 -c "print(f'{$emax * $step / $CAMANA_LIN_STEPS:.6f}')")
        if ! path=$(capture_frame "$exposure" "$CAMANA_LIN_GAIN" "$CAMANA_LIN_OFFSET" flat); then
            warn "step $step/$CAMANA_LIN_STEPS at ${exposure}s failed"
            failed=$(( failed + 1 ))
            continue
        fi

        stats=$(frame_stats "$path")
        read -r median satcount <<<"$stats"
        if [[ -z "$median" ]]; then
            warn "cannot read $path"
            failed=$(( failed + 1 ))
            continue
        fi

        # Into the shared manifest as kind "flat" with its exposure, so the
        # frames are discoverable alongside everything else, and into a
        # dedicated JSONL carrying the measured median so the fit below and
        # any later user script need not re-open 20 FITS files.
        manifest_append "$CAMANA_LIN_GAIN" "$CAMANA_LIN_OFFSET" "$mode" flat \
            "$exposure" "$path"
        python3 -c '
import json, sys
print(json.dumps({
    "gain": int(sys.argv[1]),
    "offset": int(sys.argv[2]),
    "readout_mode": int(sys.argv[3]),
    "exposure": float(sys.argv[4]),
    "median": float(sys.argv[5]),
    "saturated": int(sys.argv[6]),
    "file": sys.argv[7],
}))' "$CAMANA_LIN_GAIN" "$CAMANA_LIN_OFFSET" "$mode" "$exposure" \
            "$median" "$satcount" "$path" >> "$ramp"

        captured=$(( captured + 1 ))
        info "$(printf 'step %2d/%d  %.6fs  median %8.1f ADU  %d saturated' \
            "$step" "$CAMANA_LIN_STEPS" "$exposure" "$median" "$satcount")"
    done

    manifest_finalise >/dev/null
    good "$captured frame(s), $failed failed"
    good "ramp: $ramp"

    (( captured >= 4 )) || die "too few points to fit a line" 1

    # The fit, reported inline. This is the number the operator reads; making
    # them run a second tool to see whether their sensor is linear would mean
    # the stage does not answer its own question.
    log "Linearity fit"
    "$CAMANA_VENV/bin/python" - "$ramp" "$CAMANA_LIN_FIT_PCT" <<'PY'
import json
import sys
from pathlib import Path

import numpy as np

FULL_SCALE = 65535.0

records = [json.loads(line) for line in
           Path(sys.argv[1]).read_text().splitlines() if line.strip()]
fit_pct = float(sys.argv[2])

exposure = np.array([r["exposure"] for r in records], dtype=float)
median = np.array([r["median"] for r in records], dtype=float)
saturated = np.array([r["saturated"] for r in records], dtype=int)
order = np.argsort(exposure)
exposure, median, saturated = exposure[order], median[order], saturated[order]

# Fit only the unambiguously linear low end. Fitting the whole ramp would drag
# the reference line towards the saturated points and hide the departure the
# ramp exists to find.
fit_mask = (median < FULL_SCALE * fit_pct / 100.0) & (saturated == 0)
if fit_mask.sum() < 2:
    print(f"   NO   fewer than 2 points below {fit_pct:.0f}% of full scale; "
          "nothing to fit against")
    raise SystemExit(1)

slope, intercept = np.polyfit(exposure[fit_mask], median[fit_mask], 1)
predicted = slope * exposure + intercept
deviation = 100.0 * (median - predicted) / np.maximum(predicted, 1.0)

# "Below saturation" means no pixel clipped, not "the median is not 65535".
# The right-hand tail reaches the ceiling long before the average pixel does:
# on 2026-09-21 an LCG frame with 8183 saturated pixels sat dead on the fit at
# a median of 56166 ADU. Judging by the median alone would have called that
# frame clean and carried its successors, which were genuinely clipped, into
# the deviation figure.
clean = saturated == 0
sat_idx = np.flatnonzero(~clean)
sat_adu = median[sat_idx[0]] if sat_idx.size else None

print(f"   slope      {slope:.1f} ADU/s")
print(f"   intercept  {intercept:.1f} ADU  (offset {records[0]['offset']})")
print(f"   fitted on  {int(fit_mask.sum())} point(s) below "
      f"{fit_pct:.0f}% of full scale")
print()
print("   exposure(s)    median(ADU)   deviation   saturated px")
for e, m, d, s in zip(exposure, median, deviation, saturated, strict=True):
    flag = "  <- clipped" if s else ""
    print(f"   {e:11.6f}   {m:11.1f}   {d:+8.2f}%   {s:12d}{flag}")
print()

if clean.any():
    worst = np.max(np.abs(deviation[clean]))
    print(f"   OK   max deviation below saturation: {worst:+.2f}% "
          f"over {int(clean.sum())} unclipped point(s)")
    if worst < 1.0:
        print("        linear to within 1%: full well = e-/ADU * 65535 is "
              "valid on this sensor")
    else:
        print("        departs by more than 1%: the shortcut "
              "full well = e-/ADU * 65535 OVERSTATES the real full well")
else:
    print("   NO   every frame carried saturated pixels; the ramp started "
          "too high")

if sat_adu is not None:
    print(f"   first saturation at median {sat_adu:.1f} ADU "
          f"({100.0 * sat_adu / FULL_SCALE:.1f}% of full scale)")
    print("        the tail clips before the median does; judge a flat by "
          "its saturated-pixel count, not its median")
else:
    print("   note the ramp never saturated: the top is below the ceiling, "
          "so the usable full well is NOT bracketed. Raise "
          "CAMANA_LIN_OVERSHOOT and re-run.")
PY
    good "multiply the slope-derived ADU by e-/ADU from --flat-auto for the"
    info "full well in electrons; dynamic range is 20*log10(full_well/read_noise_e)"
}

stage_analyse() {
    log "Analysis"
    [[ -x "$CAMANA_VENV/bin/python" ]] \
        || die "no venv at $CAMANA_VENV -- run --setup first"
    [[ -f "$ANALYSER" ]] || die "analyser not found at $ANALYSER"

    if [[ ! -f "$CAMANA_MANIFEST" ]]; then
        manifest_finalise >/dev/null 2>&1
    fi
    [[ -f "$CAMANA_MANIFEST" ]] \
        || die "no manifest at $CAMANA_MANIFEST -- run --bias first"

    mkdir -p "$CAMANA_OUT"
    "$CAMANA_VENV/bin/python" "$ANALYSER" \
        --manifest "$CAMANA_MANIFEST" \
        --out-dir "$CAMANA_OUT" \
        --pattern RGGB \
        || die "analysis failed"

    good "plots and report in $CAMANA_OUT"
    info "remember to record Ultra Mode / High Fullwell Mode in"
    info "$CAMANA_OUT/modes.txt -- the API cannot read them."
}

# ------------------------------------------------------------------- main --

main() {
    local stage=""

    while (( $# )); do
        case "$1" in
            -h|--help)   usage ;;
            -f|--force)  FORCE=1; shift ;;
            --setup|--bias|--flat|--flat-auto|--linearity|--analyse|--all)
                [[ -z "$stage" ]] || die "more than one stage given: '$stage' and '$1'" 2
                stage="${1#--}"; shift ;;
            -*) die "unknown option '$1' (see --help)" 2 ;;
            *)  die "unexpected argument '$1' (stages take a leading --)" 2 ;;
        esac
    done

    [[ -n "$stage" ]] || { usage; }

    command -v curl >/dev/null || die "curl not found" 2
    command -v python3 >/dev/null || die "python3 not found" 2

    CAMANA_ROOT=$(realpath -m -- "$CAMANA_ROOT")
    info "working tree: $CAMANA_ROOT"
    info "api         : $CAMANA_API"

    case "$stage" in
        setup)     stage_setup ;;
        bias)      stage_bias ;;
        flat)      stage_flat ;;
        flat-auto) stage_flat_auto ;;
        linearity) stage_linearity ;;
        analyse)   stage_analyse ;;
        all)       stage_setup; stage_bias; stage_analyse ;;
    esac
}

main "$@"
