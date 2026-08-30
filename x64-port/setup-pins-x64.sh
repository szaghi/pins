#!/usr/bin/env bash
# Build and install PINS for x86-64 Linux, from nothing to a running binary.
#
# Encodes everything learned porting PINS to linux-x64 on 2026-08-26/28.
# Intended to be run on a fresh machine: a test laptop, or the mini PC that
# will drive the rig.
#
# Supported distro families:
#   debian  Debian / Ubuntu / Mint / Pop / Raspbian   (apt)
#   arch    Arch / CachyOS / EndeavourOS / Manjaro    (pacman)
#
# Stages (each can be run alone, see --help):
#   deps      distro packages needed to build and run
#   indi      INDI core + indi_toupbase
#   pins      clone PINS, build linux-x64, publish
#   external  populate External/linux-x64 (vendor SDKs + SOFA/NOVAS)
#   verify    check the result actually runs
#
# INDI core comes from the distro where the distro has a current version, and
# from source where it does not:
#
#   arch    extra/libindi is 2.2.4.2 (checked 2026-08-28) -- install it.
#   debian  Ubuntu 24.04 ships indi-bin 1.9.9 (2022). indi-3rdparty's toupbase
#           calls INDI::HotPlugManager, which only exists in INDI >= 2.x, and
#           the mutlaqja PPA's noble pocket is EMPTY (dists/noble/Release lists
#           Packages with the md5 of an empty file). So the distro route cannot
#           produce a working indi_toupbase and we build core from source.
#
# indi_toupbase itself is ALWAYS built from source, on both families. The Arch
# alternatives were both rejected:
#   aur/indi-3rdparty-drivers  builds the whole 1.2 GB tree single-threaded and
#                              drags in limesuite/urjtag/gpsd/pigpio.
#   aur/libindi-toupcam        hard-pins libindi=2.2.3.1 while extra ships
#                              2.2.4.2, so it conflicts with the core package.
# Building the two subdirectories we need takes a few minutes and avoids both.

set -euo pipefail

# ---------------------------------------------------------------- settings --
INDI_VERSION="${INDI_VERSION:-v2.2.4.2}"
PINS_REPO="${PINS_REPO:-https://github.com/nitr57/pins.git}"
PINS_BRANCH="${PINS_BRANCH:-develop}"
EXTERNAL_REPO="${EXTERNAL_REPO:-https://github.com/nitr57/pins.external.git}"
DOTNET_VERSION="${DOTNET_VERSION:-10.0.302}"   # must match PINS global.json

WORK="${WORK:-$HOME/pins-build}"
PUBLISH="${PUBLISH:-$HOME/pins-run}"
DOTNET_ROOT="${DOTNET_ROOT:-$HOME/.dotnet}"

# PINS_SRC is derived from WORK, so it must be computed AFTER option parsing,
# not here: --work-dir would otherwise leave it pointing at the old default.
PINS_SRC=

# Where a from-source INDI lands.
INDI_PREFIX="${INDI_PREFIX:-/usr/local}"

log()  { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '\033[1;33m   WARN %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m   FAIL %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
    sed -n '2,35p' "$0" | sed 's/^# \?//'
    cat <<EOF

Usage: $0 [options] [stage]

Stages: deps | indi | pins | external | verify | all   (default: all)

Options:
  -w, --work-dir DIR     scratch tree for clones and build output
                         (default: \$HOME/pins-build)
  -p, --publish-dir DIR  where the PINS publish tree lands
                         (default: \$HOME/pins-run)
  -h, --help             this text

Environment overrides (flags win):
  INDI_VERSION PINS_REPO PINS_BRANCH EXTERNAL_REPO DOTNET_VERSION
  WORK PUBLISH DOTNET_ROOT INDI_PREFIX INDI_FROM_SOURCE

Reusing an existing build tree matters: the indi-core and indi-3rdparty
clones are ~1.2 GB and the core build takes tens of minutes, so point
--work-dir at a tree that already has them rather than re-cloning. On the
dev host that tree is x64-port/indi-build:

  $0 --work-dir "\$(dirname "\$0")/indi-build" indi
EOF
    exit 0
}

# ------------------------------------------------------- package-manager --
# One indirection layer so the stages below never name apt or pacman directly.

pm_detect() {
    case "$DISTRO_FAMILY" in
        debian) PM=apt ;;
        arch)   PM=pacman ;;
        *)      die "no package-manager mapping for family '$DISTRO_FAMILY'" ;;
    esac
}

# pm_installed <pkg> -> 0 if the package is installed
pm_installed() {
    case "$PM" in
        apt)    dpkg-query -W -f='${Status}' "$1" 2>/dev/null \
                    | grep -q 'install ok installed' ;;
        pacman) pacman -Qq "$1" >/dev/null 2>&1 ;;
    esac
}

pm_refresh() {
    case "$PM" in
        apt)    sudo apt-get update ;;
        # Deliberately NOT `pacman -Sy`. A refresh without an upgrade leaves
        # the sync DB ahead of the installed set, and the next -S then pulls a
        # package built against libraries the system has not upgraded to: the
        # classic Arch partial-upgrade breakage. On a rolling distro the only
        # safe refresh is a full -Syu, which is the user's call to make, not a
        # side effect of an installer. pacman -S below resolves against the
        # existing DB, and warns if that DB is stale.
        pacman) : ;;
    esac
}

pm_install() {
    case "$PM" in
        apt)    sudo apt-get install -y "$@" ;;
        pacman) sudo pacman -S --needed --noconfirm "$@" ;;
    esac
}

# Warn when the pacman sync DB is old enough that -S may fail on a 404 for a
# package version that has already rotated off the mirrors.
pm_staleness_check() {
    [[ "$PM" == pacman ]] || return 0
    local db=/var/lib/pacman/sync/extra.db age_days
    [[ -f "$db" ]] || return 0
    age_days=$(( ( $(date +%s) - $(stat -c %Y "$db") ) / 86400 ))
    (( age_days > 14 )) && warn "pacman sync DB is ${age_days} days old; run 'sudo pacman -Syu' first if installs 404"
    return 0
}

# The same logical dependency has a different name in each family.
# Arch bundles headers with the library, hence no -dev counterparts.
#
# icu is a PINS runtime dependency, not an INDI build one: NINA.csproj does not
# set InvariantGlobalization, so .NET needs ICU at startup. It is present on
# almost every desktop install, and when it is absent the failure is a
# globalization exception that gives no hint a package is missing -- so list it
# explicitly rather than relying on it being pulled in by something else.
pkgs_for_family() {
    case "$DISTRO_FAMILY" in
        debian)
            echo build-essential cmake git git-lfs pkg-config \
                 libnova-dev libcfitsio-dev libusb-1.0-0-dev zlib1g-dev \
                 libgsl-dev libjpeg-dev libcurl4-gnutls-dev libtheora-dev \
                 libfftw3-dev libev-dev libudev-dev \
                 libicu-dev \
                 curl rsync file
            ;;
        arch)
            # base-devel is a group; pacman --needed handles it correctly.
            # systemd-libs provides libudev; curl provides libcurl.
            echo base-devel cmake git git-lfs pkgconf \
                 libnova cfitsio libusb zlib gsl libjpeg-turbo curl libtheora \
                 fftw libev systemd-libs \
                 icu \
                 rsync file
            ;;
    esac
}

# ------------------------------------------------------------ preflight -----
preflight() {
    log "Preflight"

    [[ "$(uname -m)" == "x86_64" ]] || die "this script targets x86-64, found $(uname -m)"
    info "arch: x86_64"

    [[ -r /etc/os-release ]] || die "cannot read /etc/os-release"
    . /etc/os-release
    info "distro: ${PRETTY_NAME:-$ID ${VERSION_ID:-}}"

    # ID_LIKE is what makes derivatives work without an explicit entry:
    # CachyOS sets ID=cachyos ID_LIKE=arch, Mint sets ID_LIKE="ubuntu debian".
    DISTRO_FAMILY=""
    for id in "$ID" ${ID_LIKE:-}; do
        case "$id" in
            debian|ubuntu)                    DISTRO_FAMILY=debian; break ;;
            arch|archlinux|cachyos|manjaro)   DISTRO_FAMILY=arch;   break ;;
        esac
    done
    [[ -n "$DISTRO_FAMILY" ]] \
        || die "unsupported distro '$ID' (ID_LIKE='${ID_LIKE:-}'); expected a debian- or arch-based system"

    pm_detect
    info "family: $DISTRO_FAMILY   package manager: $PM"
    pm_staleness_check

    # Whether INDI core is built from source. Overridable either way, because
    # a user on an old Arch or a newer Debian may want the other choice.
    if [[ -z "${INDI_FROM_SOURCE:-}" ]]; then
        case "$DISTRO_FAMILY" in
            arch)   INDI_FROM_SOURCE=0 ;;
            debian) INDI_FROM_SOURCE=1 ;;
        esac
    fi
    if (( INDI_FROM_SOURCE )); then
        info "INDI core: build from source ($INDI_VERSION -> $INDI_PREFIX)"
    else
        info "INDI core: distro package"
    fi

    command -v sudo >/dev/null || die "sudo not found"
    info "cores: $(nproc)   free disk on $HOME: $(df -h --output=avail "$HOME" | tail -1 | tr -d ' ')"

    # The INDI build needs roughly 2 GB, indi-3rdparty checks out ~1.2 GB, the
    # .NET SDK is ~800 MB and the PINS publish tree is ~240 MB.
    local avail_kb
    avail_kb=$(df -k --output=avail "$HOME" | tail -1 | tr -d ' ')
    (( avail_kb > 8000000 )) || warn "less than 8 GB free; the full build may not fit"
}

# ---------------------------------------------------------------- stage: deps
stage_deps() {
    log "Stage: distro dependencies ($PM)"

    local pkgs=() missing=() p
    read -r -a pkgs <<<"$(pkgs_for_family)"

    for p in "${pkgs[@]}"; do
        pm_installed "$p" || missing+=("$p")
    done

    # On Arch, base-devel is a group: pacman -Qq base-devel always fails even
    # when every member is installed, so it lands in `missing` every run.
    # --needed makes that a no-op rather than a reinstall.
    if (( ${#missing[@]} == 0 )); then
        info "all present"
    else
        info "installing: ${missing[*]}"
        pm_refresh
        pm_install "${missing[@]}" || {
            warn "bulk install failed, retrying individually"
            for p in "${missing[@]}"; do
                pm_install "$p" || warn "could not install $p"
            done
        }
    fi

    # Arch's libindi lives in extra and is current; grab it here rather than in
    # stage_indi so the whole distro-package story is in one place.
    if (( ! INDI_FROM_SOURCE )); then
        if pm_installed libindi; then
            info "libindi already installed"
        else
            info "installing INDI core from the distro"
            pm_install libindi || die "could not install libindi"
        fi
    fi
}

# ---------------------------------------------------------------- stage: indi
stage_indi() {
    log "Stage: INDI core + indi_toupbase"

    mkdir -p "$WORK"

    if (( INDI_FROM_SOURCE )); then
        indi_core_from_source
    else
        indi_core_check_distro
    fi

    indi_toupbase_from_source
}

# Verify the distro actually gave us INDI >= 2, which is the whole reason
# toupbase can be built at all (INDI::HotPlugManager).
indi_core_check_distro() {
    pkg-config --exists libindi 2>/dev/null \
        || die "pkg-config cannot find libindi; install it first (stage deps)"

    local v major
    v=$(pkg-config --modversion libindi)
    major=${v%%.*}
    info "libindi $v (pkg-config)"
    (( major >= 2 )) \
        || die "libindi $v is too old for indi_toupbase (needs >= 2.x)"
}

indi_core_from_source() {
    if [[ ! -d "$WORK/indi-core/.git" ]]; then
        info "cloning indi core $INDI_VERSION"
        git clone --depth 1 --branch "$INDI_VERSION" \
            https://github.com/indilib/indi.git "$WORK/indi-core"
    else
        info "indi core already cloned"
    fi

    mkdir -p "$WORK/indi-core/build"
    (
        cd "$WORK/indi-core/build"
        # FIX_WARNINGS=OFF is REQUIRED on new compilers. INDI builds with
        # -Wall -Wextra -Werror; GCC 16 emits -Wstringop-overread inside
        # glibc's own stdio2.h and -Wmaybe-uninitialized in pmc8driver.cpp /
        # astrotrac.cpp, neither of which is a real defect. Turning the switch
        # off is cleaner than patching upstream sources on every update.
        cmake -DCMAKE_INSTALL_PREFIX="$INDI_PREFIX" \
              -DCMAKE_BUILD_TYPE=Release \
              -DFIX_WARNINGS=OFF ..
        info "building indi core on $(nproc) cores (this takes a while)"
        make -j"$(nproc)"
        sudo make install
    )
    sudo ldconfig
    info "indi core installed to $INDI_PREFIX"
}

indi_toupbase_from_source() {
    # indi-3rdparty is ~1.2 GB because it bundles every vendor SDK. We build
    # exactly two of its subdirectories.
    if [[ ! -d "$WORK/indi-3rdparty/.git" ]]; then
        info "cloning indi-3rdparty (large, ~1.2 GB)"
        git clone --depth 1 https://github.com/indilib/indi-3rdparty.git \
            "$WORK/indi-3rdparty"
    else
        info "indi-3rdparty already cloned"
    fi

    # Install alongside the core, so the driver finds its library and
    # indiserver finds the driver: /usr/local for a source core, /usr for a
    # distro one.
    local prefix="$INDI_PREFIX"
    (( INDI_FROM_SOURCE )) || prefix=/usr
    info "installing toupbase into $prefix"

    # The ToupTek SDK must be installed before the driver that links it.
    mkdir -p "$WORK/build-libtoupcam"
    (
        cd "$WORK/build-libtoupcam"
        cmake -DCMAKE_INSTALL_PREFIX="$prefix" \
              -DCMAKE_BUILD_TYPE=Release \
              "$WORK/indi-3rdparty/libtoupcam"
        make -j"$(nproc)"
        sudo make install          # also installs 99-toupcam.rules for udev
    )
    sudo ldconfig

    # indi-toupbase builds one driver per ToupTek OEM rebrand -- Altair,
    # Bresser, Mallincam, Meadecam, NNcam, Ogmacam, Omegon, StarshootG,
    # SVBony, Teleskop -- and every one defaults to On with a REQUIRED
    # find_package for its own vendor SDK. We install only libtoupcam, so the
    # configure step dies on the first missing one:
    #
    #   CMake Error at cmake_modules/FindALTAIRCAM.cmake:43 (message):
    #     Altaircam not found.  Please install Altaircam Library
    #
    # Turn the other ten off rather than installing ten SDKs for cameras we do
    # not own. WITH_TOUPCAM stays On and yields indi_toupcam_ccd.
    mkdir -p "$WORK/build-toupbase"
    (
        cd "$WORK/build-toupbase"
        cmake -DCMAKE_INSTALL_PREFIX="$prefix" \
              -DCMAKE_BUILD_TYPE=Release \
              -DFIX_WARNINGS=OFF \
              -DWITH_TOUPCAM=On \
              -DWITH_ALTAIRCAM=Off \
              -DWITH_BRESSERCAM=Off \
              -DWITH_MALLINCAM=Off \
              -DWITH_MEADECAM=Off \
              -DWITH_NNCAM=Off \
              -DWITH_OGMACAM=Off \
              -DWITH_OMEGONPROCAM=Off \
              -DWITH_STARSHOOTG=Off \
              -DWITH_SVBONYCAM=Off \
              -DWITH_TSCAM=Off \
              "$WORK/indi-3rdparty/indi-toupbase"
        make -j"$(nproc)"
        sudo make install
    )
    sudo ldconfig

    # Reload udev so the camera is accessible without root on first plug-in.
    sudo udevadm control --reload-rules 2>/dev/null || true
    sudo udevadm trigger 2>/dev/null || true
}

# ---------------------------------------------------------------- stage: pins
stage_pins() {
    log "Stage: PINS linux-x64 build"

    # -- .NET SDK ----------------------------------------------------------
    if [[ ! -x "$DOTNET_ROOT/dotnet" ]]; then
        info "installing .NET SDK $DOTNET_VERSION to $DOTNET_ROOT"
        curl -fsSL -o /tmp/dotnet-install.sh https://dot.net/v1/dotnet-install.sh
        bash /tmp/dotnet-install.sh --version "$DOTNET_VERSION" --install-dir "$DOTNET_ROOT"
    else
        info ".NET already at $DOTNET_ROOT ($("$DOTNET_ROOT/dotnet" --version))"
    fi
    export PATH="$DOTNET_ROOT:$PATH"
    export DOTNET_CLI_TELEMETRY_OPTOUT=1

    # -- source ------------------------------------------------------------
    if [[ ! -d "$PINS_SRC/.git" ]]; then
        info "cloning PINS ($PINS_BRANCH)"
        git clone --recurse-submodules --branch "$PINS_BRANCH" "$PINS_REPO" "$PINS_SRC"
    else
        info "PINS already cloned at $PINS_SRC"
    fi

    (
        cd "$PINS_SRC"
        # NINA.csproj already defaults RuntimeIdentifier to linux-x64 when
        # OSArchitecture is not Arm64, so -r linux-x64 is belt and braces.
        info "building System.Windows.Compat"
        dotnet build System.Windows.Compat/System.Windows.Compat.csproj -c Release

        info "restoring linux-x64"
        dotnet restore NINA/NINA.csproj -r linux-x64

        info "building linux-x64"
        dotnet build NINA/NINA.csproj -c Release -r linux-x64 --no-restore

        info "publishing to $PUBLISH"
        rm -rf "$PUBLISH"
        dotnet publish NINA/NINA.csproj -c Release -r linux-x64 --no-build -o "$PUBLISH"
    )
}

# ------------------------------------------------------------ stage: external
stage_external() {
    log "Stage: External native libraries"

    [[ -d "$PUBLISH" ]] || die "publish dir $PUBLISH not found; run the pins stage first"

    # pins.external replaced the old cloud.astro-narren.de zip, whose share URL
    # returns HTTP 503. It uses Git LFS: fetching files through the GitHub API
    # yields 133-byte pointer files that fail at dlopen in a way that looks
    # like a corrupt library. It must be CLONED.
    if [[ ! -d "$WORK/pins.external/.git" ]]; then
        info "cloning pins.external (Git LFS)"
        git clone --depth 1 "$EXTERNAL_REPO" "$WORK/pins.external"
    else
        info "pins.external already cloned"
    fi

    local lfs_check="$WORK/pins.external/linux-x64/ToupTek/libtoupcam.so"
    if [[ -f "$lfs_check" ]] && (( $(stat -c%s "$lfs_check") < 10000 )); then
        warn "libtoupcam.so is only $(stat -c%s "$lfs_check") bytes: LFS content not pulled"
        (cd "$WORK/pins.external" && git lfs pull)
    fi

    mkdir -p "$PUBLISH/External/linux-x64"
    rsync -a "$WORK/pins.external/linux-x64/" "$PUBLISH/External/linux-x64/"
    [[ -f "$WORK/pins.external/JPLEPH" ]] && cp "$WORK/pins.external/JPLEPH" "$PUBLISH/External/JPLEPH"
    info "copied vendor SDKs + SOFA/NOVAS + JPLEPH"

    # cfitsio and libraw ship as versioned sonames only; PINS asks for the
    # unversioned name. Symlink rather than copy so distro updates are picked up.
    link_system() {
        local want="$1" dir="$2" path
        # Match the soname exactly: a bare grep for libraw.so also matches
        # libraw1394.so.11 and libraw_r.so.23 and would link the wrong library.
        # No `exit` in awk: quitting early SIGPIPEs ldconfig and, under
        # pipefail, aborts the script.
        path=$(ldconfig -p | awk -v n="$want" \
            '!done && ($1 == n || index($1, n ".") == 1) {print $NF; done=1}')
        mkdir -p "$PUBLISH/External/linux-x64/$dir"
        if [[ -n "$path" ]]; then
            ln -sf "$path" "$PUBLISH/External/linux-x64/$dir/$want"
            info "$want -> $path"
        else
            warn "$want not found on the system"
        fi
        return 0
    }
    link_system libcfitsio.so Cfitsio
    link_system libraw.so     Libraw
}

# -------------------------------------------------------------- stage: verify
stage_verify() {
    log "Stage: verify"

    local rc=0

    # -- INDI --------------------------------------------------------------
    if command -v indiserver >/dev/null; then
        local srv; srv=$(command -v indiserver)
        info "indiserver: $srv"

        # A from-source install into /usr/local sits alongside any distro
        # indiserver in /usr/bin. PATH order decides which one PINS spawns,
        # and PINS pkill -9's every indiserver on startup, so a stale 1.9.9
        # winning the PATH is a real and confusing failure mode.
        local others
        others=$(command -v -a indiserver 2>/dev/null | tail -n +2)
        if [[ -n "$others" ]]; then
            warn "more than one indiserver on PATH; '$srv' wins:"
            printf '        also: %s\n' $others
            warn "ensure the >= 2.x one is first, or indi_toupbase will not load"
        fi
    else
        warn "indiserver not on PATH"; rc=1
    fi

    # The package is called indi-toupbase but CMakeLists generates the binary
    # as indi_<brand>_ccd, so the ToupTek build produces indi_toupcam_ccd.
    local found_toup=0 b
    for b in indi_toupcam_ccd indi_toupbase; do
        if command -v "$b" >/dev/null; then
            info "toupbase driver: $(command -v "$b")"
            found_toup=1
        fi
    done
    (( found_toup )) || { warn "no toupcam driver found on PATH"; rc=1; }

    if command -v indi_simulator_ccd >/dev/null; then
        info "simulators: present"
    else
        warn "indi_simulator_ccd missing"; rc=1
    fi

    # -- PINS --------------------------------------------------------------
    if [[ -x "$PUBLISH/NINA" ]]; then
        info "PINS binary: $(file -b "$PUBLISH/NINA" | cut -c1-46)"
        # `--help` prints the banner and option list but exits 255, so judge on
        # the output, never on the exit status.
        local helpout
        helpout=$(cd "$PUBLISH" && timeout 60 ./NINA --help 2>/dev/null || true)
        if [[ -n "$helpout" ]]; then
            # The banner starts with a blank line; take the first non-empty one.
            info "runs: $(grep -m1 -v '^[[:space:]]*$' <<<"$helpout")"
        else
            warn "PINS produced no output for --help"; rc=1
        fi
    else
        warn "no PINS binary at $PUBLISH/NINA"; rc=1
    fi

    # -- native libs -------------------------------------------------------
    local lib p
    for lib in SOFA/libsofa_c.so NOVAS/libnovas_c.so ToupTek/libtoupcam.so; do
        p="$PUBLISH/External/linux-x64/$lib"
        if [[ -f "$p" ]]; then
            if ldd "$p" 2>/dev/null | grep -q 'not found'; then
                warn "$lib has unresolved dependencies"; rc=1
            else
                info "$lib OK ($(stat -c%s "$p") bytes)"
            fi
        else
            warn "$lib missing"; rc=1
        fi
    done

    # -- USB ---------------------------------------------------------------
    # WSL2 has no USB passthrough by default; on real hardware this exists.
    [[ -d /sys/bus/usb/devices ]] && info "USB subsystem present" \
        || warn "/sys/bus/usb/devices missing: no USB passthrough (WSL2?)"

    echo
    if (( rc == 0 )); then
        log "All checks passed"
        echo "   Run PINS:  cd $PUBLISH && ./NINA"
        echo "   Then open Touch-N-Stars in a browser against this host."
    else
        log "Some checks failed (see WARN above)"
    fi
    return $rc
}

# ---------------------------------------------------------------------- main
main() {
    local stage=""

    while (( $# )); do
        case "$1" in
            -h|--help)  usage ;;
            -w|--work-dir)
                [[ ${2:-} ]] || die "--work-dir needs a directory"
                WORK="$2"; shift 2 ;;
            -p|--publish-dir)
                [[ ${2:-} ]] || die "--publish-dir needs a directory"
                PUBLISH="$2"; shift 2 ;;
            --work-dir=*)    WORK="${1#*=}";    shift ;;
            --publish-dir=*) PUBLISH="${1#*=}"; shift ;;
            -*) die "unknown option '$1' (see --help)" ;;
            *)
                [[ -z "$stage" ]] || die "more than one stage given: '$stage' and '$1'"
                stage="$1"; shift ;;
        esac
    done
    stage="${stage:-all}"

    # Absolute paths: several stages cd into subshells, and a relative WORK
    # would resolve differently depending on which one is running.
    WORK=$(realpath -m -- "$WORK")
    PUBLISH=$(realpath -m -- "$PUBLISH")
    PINS_SRC="$WORK/pins"

    [[ "$WORK" != "$PUBLISH" ]] \
        || die "--work-dir and --publish-dir must differ (stage_pins wipes the publish dir)"

    preflight
    info "work dir: $WORK"
    info "publish : $PUBLISH"
    case "$stage" in
        deps)     stage_deps ;;
        indi)     stage_indi ;;
        pins)     stage_pins ;;
        external) stage_external ;;
        verify)   stage_verify ;;
        all)      stage_deps; stage_indi; stage_pins; stage_external; stage_verify ;;
        *)        die "unknown stage '$stage' (deps|indi|pins|external|verify|all)" ;;
    esac
}

main "$@"
