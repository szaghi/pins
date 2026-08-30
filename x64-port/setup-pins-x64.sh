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
#   indi      INDI core + indi_toupbase (camera) + indi_eqmod (mount)
#   pins      clone PINS, build linux-x64, publish
#   plugins   build ninaAPI + Touch-N-Stars (the headless UI; without this
#             PINS runs but has no API server and no user interface)
#   astap     ASTAP plate solver + star database (needed by TPPA, framing)
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

Stages: deps | indi | pins | plugins | astap | external | verify | all
        (default: all)

Options:
  -w, --work-dir DIR     scratch tree for clones and build output
                         (default: \$HOME/pins-build)
  -p, --publish-dir DIR  where the PINS publish tree lands
                         (default: \$HOME/pins-run)
  -R, --pins-repo URL    PINS repository to clone
                         (default: upstream nitr57/pins)
  -B, --pins-branch REF  branch to build
                         (default: develop)
  -h, --help             this text

The repo/branch defaults point at UPSTREAM. To build your own fork pass
--pins-repo and --pins-branch, and note that an existing clone under
--work-dir is reused as-is rather than re-cloned; the pins stage prints the
remote, branch and commit it is actually building, so check that line.

Environment overrides (flags win):
  INDI_VERSION PINS_REPO PINS_BRANCH EXTERNAL_REPO DOTNET_VERSION
  WORK PUBLISH DOTNET_ROOT INDI_PREFIX INDI_FROM_SOURCE
  ASTAP_DB (d05|d20|d50|d80, default d80) ASTAP_PREFIX

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
                 libicu-dev libraw-dev \
                 nodejs npm \
                 curl rsync file
            ;;
        arch)
            # base-devel is a group; pacman --needed handles it correctly.
            # systemd-libs provides libudev; curl provides libcurl.
            echo base-devel cmake git git-lfs pkgconf \
                 libnova cfitsio libusb zlib gsl libjpeg-turbo curl libtheora \
                 fftw libev systemd-libs \
                 icu libraw \
                 nodejs npm \
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
    log "Stage: INDI core + indi_toupbase + indi_eqmod"

    mkdir -p "$WORK"

    if (( INDI_FROM_SOURCE )); then
        indi_core_from_source
    else
        indi_core_check_distro
    fi

    indi_toupbase_from_source
    indi_eqmod_from_source
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

# EQMod: the driver for SkyWatcher/Orion mounts reached through an EQDIR cable
# straight into the mount's handset port, with no SynScan handset in the chain
# (HEQ5 Pro, EQ6, AZ-EQ6, Star Adventurer GTi...).
#
# Like toupbase it lives in indi-3rdparty rather than INDI core, so a distro
# libindi does NOT provide it and `pacman -S libindi` leaves you without a
# mount driver. Core does ship indi_synscan_telescope, but that speaks the
# handset protocol: point it at an EQDIR cable and the connection fails with
#
#   [INDI Message][SynScan] [ERROR] Serial read error: Timeout error.
#
# which looks like broken hardware rather than the wrong driver.
#
# Defaults are correct: WITH_AHP_GT is already Off (an AHP GoTo controller
# upgrade), and alignment/EQMod-alignment/scope-limits are On, which is what
# EQMod users want. Only AHP_GT would pull a REQUIRED find_package we cannot
# satisfy, and it is off.
indi_eqmod_from_source() {
    [[ -d "$WORK/indi-3rdparty/.git" ]] \
        || die "indi-3rdparty not cloned; indi_toupbase_from_source runs first"

    local prefix="$INDI_PREFIX"
    (( INDI_FROM_SOURCE )) || prefix=/usr
    info "installing eqmod into $prefix"

    mkdir -p "$WORK/build-eqmod"
    (
        cd "$WORK/build-eqmod"
        cmake -DCMAKE_INSTALL_PREFIX="$prefix" \
              -DCMAKE_BUILD_TYPE=Release \
              "$WORK/indi-3rdparty/indi-eqmod"
        make -j"$(nproc)"
        sudo make install
    )
    sudo ldconfig
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
        info "cloning $PINS_REPO ($PINS_BRANCH)"
        git clone --recurse-submodules --branch "$PINS_BRANCH" "$PINS_REPO" "$PINS_SRC"
    else
        info "PINS already cloned at $PINS_SRC (not re-cloning)"
    fi

    # Always report what is actually about to be built. The defaults point at
    # UPSTREAM develop, so a run that forgets PINS_REPO/PINS_BRANCH silently
    # builds someone else's tree -- and an existing clone is reused as-is, so
    # even a "clean" work dir can be stale. Both failures look like the build
    # ignoring your changes rather than building a different source.
    (
        cd "$PINS_SRC"
        local head branch origin
        head=$(git log --oneline -1 2>/dev/null)
        branch=$(git branch --show-current 2>/dev/null)
        origin=$(git remote get-url origin 2>/dev/null)
        info "building: ${origin:-unknown}"
        info "  branch: ${branch:-<detached HEAD>}   commit: ${head:-unknown}"
    )

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

# ------------------------------------------------------------- stage: plugins
# Without this stage PINS runs but has no user interface.
#
# The headless product's UI is the Touch-N-Stars Vue app, which reaches the
# backend over HTTP through the ninaAPI plugin (AGENTS.md, "Runtime Model").
# Neither plugin is in NINA.sln and neither is referenced by NINA.csproj -- they
# are git submodules under NINA.Plugins/ -- so `dotnet publish NINA.csproj`
# produces a working binary with no API server. The symptom is nothing
# listening on port 1888 and no PluginLoader lines in the log.
#
# ninaAPI.csproj carries a net10.0 configuration that ProjectReferences the
# in-tree PINS projects, so it builds on Linux against the sources we just
# compiled. (Its net8.0-windows configuration uses NuGet PackageReferences
# instead; do not build that one here.)
#
# Layout: PluginAssemblyLoadContext resolves a plugin's dependencies from the
# directory of the plugin DLL itself, recursively (PluginLoader.cs:724). So each
# plugin gets its own subfolder containing its full dependency set. That is why
# the whole bin directory is copied rather than just the plugin assembly, and
# why doing so cannot clobber PINS's own assemblies.
# The plugin directory is keyed on PluginMinimumApplicationVersion, NOT on the
# application version. NINA.Plugin sets no such assembly metadata, so
# Constants.cs:38 falls back to "3.0.0" and stays there regardless of PINS
# being 3.3.0.1053. Deriving it from AssemblyVersion puts plugins in a folder
# PINS never scans, which fails silently: the app starts, the plugins are
# simply absent, and any copy installed from the official plugin repository
# wins instead.
plugin_folder() {
    local ver=3.0.0 meta
    meta=$(grep -oP 'PluginMinimumApplicationVersion[^0-9]*\K[0-9]+\.[0-9]+\.[0-9]+' \
               "$PINS_SRC/NINA.Plugin/NINA.Plugin.csproj" 2>/dev/null | head -1)
    [[ -n "$meta" ]] && ver="$meta"
    printf '%s/NINA/Plugins/%s' "${XDG_DATA_HOME:-$HOME/.local/share}" "$ver"
}

stage_plugins() {
    log "Stage: PINS plugins (ninaAPI + Touch-N-Stars)"

    [[ -d "$PINS_SRC" ]] || die "PINS source not found at $PINS_SRC; run the pins stage first"

    export PATH="$DOTNET_ROOT:$PATH"
    export DOTNET_CLI_TELEMETRY_OPTOUT=1
    command -v dotnet >/dev/null || die "dotnet not found; run the pins stage first"

    # Plugins live under a version-scoped folder keyed on the MAJOR.MINOR.BUILD
    # that NINA.Plugin was compiled with (Constants.cs:26, UserExtensionsFolder).
    # LocalApplicationData is ~/.local/share on Linux, giving
    # ~/.local/share/NINA/Plugins/<major.minor.build>/.
    local plugin_root
    plugin_root="$(plugin_folder)"
    info "plugin folder: $plugin_root"
    mkdir -p "$plugin_root"

    local built=0 name proj out
    # The destination folder name must match the plugin's display Name, because
    # that is the folder the official plugin repository installs into and the
    # one a previously-downloaded copy already occupies. Deploying beside it
    # under a different name leaves two copies, and the downloaded one wins.
    # Two other submodules are Windows-only and cannot be added here:
    # NINA.Joko.Plugin.TenMicron (net8.0-windows7.0) and nina.plugin.orbuculum
    # (net7.0-windows). joko.nina.plugins does build for net10.0 but is not
    # deployed by default -- add a line for it if you want it.
    #
    # Three Point Polar Alignment (TPPA) is not optional for an equatorial rig.
    # ninaAPI serves its live drift data over a WebSocket at /v2/tppa
    # (API.cs:55), and Touch-N-Stars has a TPPA view that connects to it, so
    # without the plugin the UI offers no polar alignment at all.
    #
    # Its csproj multi-targets net10.0-windows7.0;net10.0 -- pin -f net10.0 as
    # for the others. Folder name is its AssemblyTitle, "Three Point Polar
    # Alignment"; the assembly itself is NINA.Plugins.PolarAlignment.dll.
    for spec in "Advanced API:NINA.Plugins/ninaAPI/ninaAPI/ninaAPI.csproj" \
                "Touch N Stars:NINA.Plugins/Touch-N-Stars/Touch-N-Stars/Touch-N-Stars.csproj" \
                "Three Point Polar Alignment:NINA.Plugins/PolarAlignment/PolarAlignment/NINA.Plugins.PolarAlignment.csproj" \
                "Livestack:NINA.Plugins/LiveStack/nina.plugin.livestack.csproj" \
                "Phd2 Tools:NINA.Plugins/nina.plugin.phd2tools/nina.plugin.phd2tools.csproj"; do
        name=${spec%%:*}
        proj=${spec#*:}

        if [[ ! -f "$PINS_SRC/$proj" ]]; then
            warn "$name: $proj not found; submodule not checked out? skipping"
            continue
        fi

        info "building $name"
        if ! ( cd "$PINS_SRC" && dotnet build "$proj" -c Release -f net10.0 -r linux-x64 ); then
            warn "$name failed to build; skipping"
            continue
        fi

        out="$PINS_SRC/$(dirname "$proj")/bin/Release/net10.0/linux-x64"
        if [[ ! -d "$out" ]]; then
            warn "$name built but $out is missing; skipping"
            continue
        fi

        rsync -a --delete "$out/" "$plugin_root/$name/"
        info "$name -> $plugin_root/$name/"
        built=$((built + 1))
    done

    (( built > 0 )) || die "no plugins were deployed; PINS will have no API and no UI"
    info "deployed $built plugin(s)"

    deploy_webapp "$plugin_root"
}

# The Touch-N-Stars .NET plugin is only the server half. The user interface is
# a Vue app in the Touch-N-Stars submodule at the repo root, built with npm and
# served as a static folder:
#
#   TouchNStarsServer.cs:30  webAppDir = Path.Combine(assemblyFolder, "app")
#   TouchNStarsServer.cs:60  WebServer.WithStaticFolder("/", webAppDir, false)
#
# Without it the server answers but has nothing to serve, and the browser gets
#   404 - Not Found ... EmbedIO.HttpException
#   No module was able to serve the requested path.
# which looks like a routing bug rather than a missing frontend.
#
# The csproj's own deploy step is a Windows-only xcopy, and package.json's
# `testbuild` script targets %LOCALAPPDATA%, so neither helps us here.
deploy_webapp() {
    local plugin_root="$1"
    local src="$PINS_SRC/Touch-N-Stars"       # the Vue submodule, not the plugin
    # "Touch N Stars" with spaces: the plugin's display Name, which is both the
    # folder the official repository installs into and where the assembly
    # resolves its own directory from at runtime.
    local dest="$plugin_root/Touch N Stars/app"

    if [[ ! -f "$src/package.json" ]]; then
        warn "Touch-N-Stars web app sources not found at $src; submodule not checked out?"
        warn "the API will work but the browser UI will 404"
        return 0
    fi

    if ! command -v npm >/dev/null; then
        warn "npm not found: cannot build the Touch-N-Stars web UI"
        warn "install it (arch: pacman -S npm, debian: apt install npm) and re-run this stage"
        return 0
    fi

    info "installing web app dependencies (npm ci)"
    ( cd "$src" && npm ci --no-audit --no-fund ) || {
        warn "npm ci failed; skipping the web UI"
        return 0
    }

    # build:app skips the eslint pass that `build` runs first: linting is a
    # contributor gate, and a style violation upstream should not stop an
    # installer from producing a working UI.
    info "building the web app (vue-cli-service)"
    if ! ( cd "$src" && NODE_OPTIONS=--max-old-space-size=4096 npm run build:app ); then
        warn "web app build failed; the API will work but the browser UI will 404"
        return 0
    fi

    [[ -f "$src/dist/index.html" ]] || {
        warn "$src/dist/index.html missing after build; skipping deploy"
        return 0
    }

    mkdir -p "$dest"
    rsync -a --delete "$src/dist/" "$dest/"
    info "web UI -> $dest ($(du -sh "$dest" | cut -f1))"
}

# ------------------------------------------------------------ stage: external
# ------------------------------------------------------------- stage: astap
# ASTAP is the plate solver. PINS defaults PlateSolverType to ASTAP, and
# without it Three Point Polar Alignment, framing and centering all fail at
# their first solve -- TPPA solves each of its three points.
#
# Installed from the upstream .deb rather than the AUR. The AUR packages are
# effectively unmaintained (astap-bin is from 2023 with zero votes) and the
# source package builds through the Lazarus Pascal toolchain, which is a large
# dependency and a build-time risk. Extracting the .deb with ar+tar works
# identically on Arch and Debian, needs no AUR helper, and tracks upstream.
#
# We install **astap_cli**, not the GUI binary: it is statically linked (zero
# unresolved libraries, verified) whereas the GUI needs Qt5. On a headless rig
# that is one less thing to break on a distro update.
#
# The star database is mandatory and is the bulk of the download. Sizes and
# usable fields, from hnsky.org:
#   d05  100 MB  0.6-10 deg      d50  900 MB  0.2-10 deg
#   d20  400 MB  0.3-10 deg      d80  1.2 GB  0.15-10 deg
# Default d80: widest coverage, and disk is cheap next to a failed alignment.
ASTAP_DB="${ASTAP_DB:-d80}"
ASTAP_PREFIX="${ASTAP_PREFIX:-/opt/astap}"

# Count installed star-database files. D-series (d05/d20/d50/d80) uses *.1476,
# the older H-series (h17/h18) *.290; count both so either satisfies the check.
astap_db_count() {
    find "$ASTAP_PREFIX" -maxdepth 1 -type f \( -name '*.1476' -o -name '*.290' \) \
        2>/dev/null | wc -l
}

stage_astap() {
    log "Stage: ASTAP plate solver (database: $ASTAP_DB)"

    mkdir -p "$WORK/astap-dl"

    # -- the solver ---------------------------------------------------------
    if [[ -x "$ASTAP_PREFIX/astap_cli" ]]; then
        info "astap_cli already installed: $("$ASTAP_PREFIX/astap_cli" 2>&1 | head -1)"
    else
        local deb="$WORK/astap-dl/astap_amd64.deb"
        if [[ ! -f "$deb" ]]; then
            info "downloading astap_amd64.deb (~7 MB)"
            curl -fsSL -o "$deb" "https://www.hnsky.org/astap_amd64.deb" \
                || die "could not download ASTAP"
        fi
        info "installing to $ASTAP_PREFIX"
        (
            cd "$WORK/astap-dl"
            rm -rf extract && mkdir extract && cd extract
            ar x "$deb"
            tar -xf data.tar.* 
            sudo mkdir -p "$ASTAP_PREFIX"
            sudo cp -a opt/astap/. "$ASTAP_PREFIX/"
        )
        # Symlink both: PINS is pointed at astap_cli, but the GUI name is what
        # most documentation and other tools expect to find on PATH.
        sudo ln -sf "$ASTAP_PREFIX/astap_cli" /usr/local/bin/astap_cli
        [[ -x "$ASTAP_PREFIX/astap" ]] && sudo ln -sf "$ASTAP_PREFIX/astap" /usr/local/bin/astap
        info "installed: $("$ASTAP_PREFIX/astap_cli" 2>&1 | head -1)"
    fi

    # -- the star database --------------------------------------------------
    # ASTAP looks for its database files beside the binary. The extension
    # depends on the format: the D-series (d05/d20/d50/d80) ships *.1476,
    # while the older H-series (h17/h18) uses *.290. Match both, or a healthy
    # 1.3 GB install reports "0 files".
    if astap_db_count >/dev/null && (( $(astap_db_count) > 0 )); then
        info "star database already present: $(astap_db_count) files"
        return 0
    fi

    local dbdeb="$WORK/astap-dl/${ASTAP_DB}_star_database.deb"
    if [[ ! -f "$dbdeb" ]]; then
        info "downloading the $ASTAP_DB star database (this is the big one)"
        curl -fsSL -o "$dbdeb" \
            "https://sourceforge.net/projects/astap-program/files/star_databases/${ASTAP_DB}_star_database.deb/download" \
            || die "could not download the $ASTAP_DB database"
    fi

    info "installing the star database"
    (
        cd "$WORK/astap-dl"
        rm -rf dbextract && mkdir dbextract && cd dbextract
        ar x "$dbdeb"
        tar -xf data.tar.*
        # The .deb lays the files out under ./opt/astap or ./usr/share/astap
        # depending on the release; copy whichever exists.
        local src=""
        [[ -d opt/astap ]]       && src=opt/astap
        [[ -d usr/share/astap ]] && src=usr/share/astap
        [[ -n "$src" ]] || die "unexpected database .deb layout"
        sudo cp -a "$src/." "$ASTAP_PREFIX/"
    )
    info "star database: $(astap_db_count) files, $(du -sh "$ASTAP_PREFIX" | cut -f1) total"
}

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
        #
        # `type -a`, not `command -v -a`: the -a flag is a zsh/dash extension
        # that bash's builtin rejects outright, so the check silently found
        # nothing and never fired.
        #
        # Resolve each hit to its real path before comparing. On Arch /usr/sbin
        # is a symlink to /usr/bin, so the same binary is reported twice and a
        # naive count warns about a conflict that does not exist.
        local others
        others=$(type -aP indiserver 2>/dev/null \
                 | xargs -r -n1 readlink -f 2>/dev/null \
                 | sort -u | grep -Fxv "$(readlink -f "$srv")" || true)
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

    # EQMod, for SkyWatcher mounts on an EQDIR cable. Not in INDI core, so a
    # distro libindi alone leaves you with no mount driver.
    if command -v indi_eqmod_telescope >/dev/null; then
        info "eqmod driver: $(command -v indi_eqmod_telescope)"
    else
        warn "indi_eqmod_telescope not found; SkyWatcher mounts on EQDIR will not connect"
        rc=1
    fi

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

    # OpenCV sits in the publish root, not under External, and is easy to miss
    # because PINS starts and captures perfectly without it. But
    # System.Windows.Compat's Bitmap(string) is backed by Cv2.ImRead, so every
    # ninaAPI image return goes through it: when it cannot load, the request
    # never completes and the browser UI hangs after an exposure with nothing
    # useful in the log.
    #
    # The 4.11 runtime package links nine sonames no current distro ships
    # (tesseract 4, ffmpeg 4, tiff 5, OpenEXR 2.5, GTK 2). 4.13 or newer is
    # required; see the comment on the PackageReference in NINA/NINA.csproj.
    local ocv="$PUBLISH/libOpenCvSharpExtern.so"
    if [[ -f "$ocv" ]]; then
        # `|| true`: grep exits 1 when nothing is missing, and under `set -e`
        # that aborts the whole verify stage. The check would then only survive
        # when OpenCV was broken -- exactly backwards.
        local ocv_missing
        ocv_missing=$(ldd "$ocv" 2>/dev/null | grep 'not found' | awk '{print $1}' | paste -sd' ' || true)
        if [[ -n "$ocv_missing" ]]; then
            warn "libOpenCvSharpExtern.so cannot load, missing: $ocv_missing"
            warn "the UI will hang after an exposure; needs OpenCvSharp >= 4.13 (check NINA.csproj)"
            rc=1
        else
            info "libOpenCvSharpExtern.so OK (all deps resolve)"
        fi
    else
        warn "libOpenCvSharpExtern.so missing from $PUBLISH"; rc=1
    fi

    # -- plugins -----------------------------------------------------------
    # Without ninaAPI there is no HTTP server and therefore no user interface,
    # which is easy to miss because PINS itself starts and runs perfectly.
    local plugin_root
    plugin_root="$(plugin_folder)"
    if [[ -f "$plugin_root/Advanced API/ninaAPI.dll" ]]; then
        info "ninaAPI plugin: $plugin_root/Advanced API/"
    else
        warn "ninaAPI plugin missing from $plugin_root; PINS will have no API and no UI"
        warn "run the 'plugins' stage"; rc=1
    fi

    if [[ -f "$plugin_root/Touch N Stars/TouchNStars.dll" ]]; then
        info "Touch-N-Stars plugin: present"
        # The plugin is only the server; the browser UI is a separate Vue
        # build served from <plugin>/app. Without it EmbedIO refuses to start
        # the web server at all, so nothing listens on port 5000.
        [[ -f "$plugin_root/Touch N Stars/app/index.html" ]] \
            && info "Touch-N-Stars web UI: present" \
            || { warn "Touch-N-Stars web UI missing: its web server will not start (run the plugins stage)"; rc=1; }
    else
        warn "Touch-N-Stars plugin missing from $plugin_root"
    fi

    # TPPA: polar alignment. Not optional on an equatorial mount.
    [[ -f "$plugin_root/Three Point Polar Alignment/NINA.Plugins.PolarAlignment.dll" ]] \
        && info "Three Point Polar Alignment: present" \
        || warn "Three Point Polar Alignment missing: no polar alignment in the UI"

    # -- plate solver ------------------------------------------------------
    # PINS defaults PlateSolverType to ASTAP. Without the binary AND a star
    # database, TPPA, framing and centering all fail at their first solve.
    if [[ -x "$ASTAP_PREFIX/astap_cli" ]]; then
        info "astap_cli: $ASTAP_PREFIX/astap_cli"
        local ndb
        ndb=$(astap_db_count)
        if (( ndb > 0 )); then
            info "star database: $ndb file(s)"
        else
            warn "ASTAP has no star database (*.1476 or *.290); every plate solve will fail"
            rc=1
        fi
    else
        warn "astap_cli not found at $ASTAP_PREFIX; plate solving unavailable"
        warn "run the 'astap' stage"; rc=1
    fi

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
            -R|--pins-repo)
                [[ ${2:-} ]] || die "--pins-repo needs a URL"
                PINS_REPO="$2"; shift 2 ;;
            -B|--pins-branch)
                [[ ${2:-} ]] || die "--pins-branch needs a branch name"
                PINS_BRANCH="$2"; shift 2 ;;
            --pins-repo=*)   PINS_REPO="${1#*=}";   shift ;;
            --pins-branch=*) PINS_BRANCH="${1#*=}"; shift ;;
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
        plugins)  stage_plugins ;;
        astap)    stage_astap ;;
        external) stage_external ;;
        verify)   stage_verify ;;
        all)      stage_deps; stage_indi; stage_pins; stage_plugins
                  stage_astap; stage_external; stage_verify ;;
        *)        die "unknown stage '$stage' (deps|indi|pins|plugins|astap|external|verify|all)" ;;
    esac
}

main "$@"
