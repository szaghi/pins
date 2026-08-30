# PINS linux-x64 port — build notes

## Baseline
- Fork: `szaghi/pins` (origin), upstream `nitr57/pins`
- Branch: `linux-x64`
- Baseline commit: 75e49f03ee1a90f7d24e888dbc520619cca4ae04 (upstream/develop, 2026-08-05)
- Target: Intel N100/N150 class x86-64 mini PC

## Toolchain
- .NET SDK 10.0.302 installed to `~/.dotnet` (global.json pins 10.0.302, rollForward latestPatch)
- Add to PATH: `export PATH="$HOME/.dotnet:$PATH"`

## Build sequence (verified working, zero source changes)
```bash
export PATH="$HOME/.dotnet:$PATH"
cd ~/pins
dotnet build   System.Windows.Compat/System.Windows.Compat.csproj -c Release
dotnet restore NINA/NINA.csproj -r linux-x64
dotnet build   NINA/NINA.csproj -c Release -r linux-x64 --no-restore
dotnet publish NINA/NINA.csproj -c Release -r linux-x64 --no-build -o <outdir>
```

## Result (2026-08-26)
- System.Windows.Compat: 0 errors, 71 warnings
- NINA linux-x64 build:  0 errors, 426 warnings
- Publish payload: 236 MB self-contained
- `NINA` = ELF 64-bit LSB pie executable, x86-64
- `./NINA --help` runs, reports 3.3.0.1053-nightly

**No source changes were required.** `NINA/NINA.csproj:15` already defaults to
`linux-x64` when OSArchitecture is not Arm64.

## OPEN BLOCKER: NINA/External native SDK bundle
`NINA/External` is empty in the repo and is NOT a git submodule. The CI workflow
`.github/workflows/build-pins-package.yml` downloads it as a zip from the
maintainer's Nextcloud:

    https://cloud.astro-narren.de/public.php/dav/files/7tEAZoEpCMCYyeX/?accept=zip

Status 2026-08-26: host root returns 200, but the share endpoint returns **HTTP 503**
and `/s/7tEAZoEpCMCYyeX` returns **404**. Tried twice, hours apart. Upstream CI
"Build and Test" has been failing on every run since at least 2026-07-28 — consistent
with this link being dead for everyone, not just us.

The bitbucket submodule `Isbeorn/nina.external` (present under
`NINA.Plugins/PolarAlignment/.../External`) is **Windows-only**: `x64/` and `x86/`
contain PE32+ DLLs (toupcam.dll, qhyccd.dll, ...). Zero `.so` files, no Linux branch.
Useful only as a manifest of which vendor SDKs are expected.

### What External must contain
`DllLoader.cs` resolves `External/linux-{arch}/<Vendor>/<lib>.so` at runtime, i.e.
`External/linux-x64/` for us. 26 LoadDll call sites reference:
ToupTek (libtoupcam.so), ASI, QHYCCD, SVBony, PlayerOne, Atik, Altair, Omegon,
OGMA, Risingcam, MallinCam, Oasis, Nitecrawler, Wanderer, Cfitsio, Libraw,
SOFA, NOVAS, plus system libs (libudev.so.1, libhidapi-hidraw.so, libusb-1.0.so.0).

There is a system fallback: if the bundled lib is missing, DllLoader tries the
plain library name via LD_LIBRARY_PATH. So system-installed .so files can work.

### For the ATR2600C specifically
`toupcam.cs:34` -> `DLLNAME = "libtoupcam.so"`. ToupTek ships x86_64 Linux SDKs;
x86_64 is their primary Linux test platform. This one is low-risk to source.

## THE BLOCKER DOES NOT APPLY TO THE INDI PATH (verified 2026-08-26)

`NINA.INDI` never loads a vendor `.so`. Evidence:

- `NINA.INDI.csproj` references only `NINA.Core` and `NINA.Astrometry`
- zero `DllLoader` / `External` matches across all 38 files in `NINA.INDI/`
- `INDIClient.cs:59` uses `TcpClient`; `INDIClient.cs:50` binds port 7624
- images arrive as base64 BLOBs via `setBLOBVector` (`INDICamera.cs:62`)
- `NINA.INDI/ARCHITECTURE.md`: PINS spawns
  `indiserver -v -p 7624 -m 1000 -f /tmp/indiFIFO` in FIFO mode and loads
  drivers by writing `start <driver>` into the FIFO

The vendor SDK therefore lives inside the **INDI driver process**
(`indi_toupbase`), installed from distro packages, not inside PINS.
PINS only speaks line-oriented XML over TCP.

=> For an INDI-attached ATR2600C, `External/linux-x64/` is not needed at all.

### Field-test note
`INDICamera.cs:38-46`: INDI's `setBLOBVector` carries no per-exposure
correlation id, so PINS debounces stale BLOBs with a 500 ms window after abort
(`StaleBlobDebounce`). With 52 MB ATR2600C frames this is a real code path.
Exercise sequence aborts deliberately during testing.

## Upstream issue filed
https://github.com/nitr57/pins/issues/187 (2026-08-26)
Reports the External 503 and the linux-x64 build result; asks whether a
`linux-x64` leg in the packaging workflow would be accepted as a PR.

## RUNTIME TEST RESULTS (2026-08-26)

### Stage 1: INDI standalone -- PASS
Ubuntu 24.04 `universe` package `indi-bin` 1.9.9 (NOT `libindi1`, which does not
exist on noble; the runtime libs are `libindidriver1`/`libindiclient1`/
`libindi-data` and `indi-bin` pulls them in automatically).

IMPORTANT: the `mutlaqja` PPA publishes a `noble` suite but it is EMPTY.
`dists/noble/Release` lists `main/binary-amd64/Packages` with md5
`d41d8cd98f00b204e9800998ecf8427e` (= empty file) and `Packages.gz` at 20 bytes
(= empty gzip). Publishing has moved to Ubuntu 26.04. Do not rely on that PPA
for 24.04.

Verified: both simulators load, 23 KB property XML returned, and after sending
CONNECTION=On the CCD Simulator defines CCD_EXPOSURE, CCD1, CCD_INFO,
CCD_TEMPERATURE, CCD_FRAME, CCD_BINNING, CCD_ABORT_EXPOSURE, with
`<defBLOBVector device="CCD Simulator" name="CCD1" label="Image Data">`.

NOTE: CCD_EXPOSURE/CCD1 are defined LAZILY, only after CONNECTION is switched
On. Probing the initial property dump reports them missing on a healthy server.
`test-indi-sim.sh` step 5b handles this.

### Stage 2: PINS x64 runtime -- PASS (with SOFA/NOVAS compiled locally)

First run crashed:
```
System.DllNotFoundException: Unable to load shared library 'libsofa_c.so'
  at NINA.Astrometry.SOFA.SOFA_Dtf2d(...)
  at NINA.Astrometry.AstroUtil.DeltaT(...)
```
This is the `External` blocker, hit on SOFA rather than a camera SDK.

**Resolved without the Nextcloud bundle.** SOFA and NOVAS are open source and
their full C sources ship IN THIS REPO:

```bash
# SOFA: 248 .c files in SOFA/SOFA/src (exclude the t_sofa_c.c test harness)
cd SOFA/SOFA/src
gcc -shared -fPIC -O2 -std=c99 -I. -o libsofa_c.so \
    $(ls *.c | grep -v '^t_sofa_c.c$') -lm

# NOVAS: the repo already ships a Linux shared-object Makefile
cd NOVAS31 && make          # produces libnovas_c.so + cio_ra.bin
```
Both produce `ELF 64-bit LSB shared object, x86-64`. Verified `libsofa_c.so`
exports `iauDtf2d`, `iauAtco13`, `iauEpv00`, matching the `EntryPoint` names in
`NINA.Astrometry/SOFA.cs`.

Expected layout (from `SOFA.cs:33` / `NOVAS.cs:45` + `DllLoader` arch mapping):
```
<publish>/External/linux-x64/SOFA/libsofa_c.so
<publish>/External/linux-x64/NOVAS/libnovas_c.so
<publish>/External/linux-x64/NOVAS/cio_ra.bin
<publish>/External/linux-x64/Cfitsio/libcfitsio.so -> /lib/x86_64-linux-gnu/libcfitsio.so.10
<publish>/External/linux-x64/Libraw/libraw.so     -> /lib/x86_64-linux-gnu/libraw.so.23
```
cfitsio and libraw exist on Ubuntu as versioned sonames only; PINS asks for the
unversioned name, hence the symlinks.

After staging these, PINS ran for the full 90 s test window and shut down
cleanly through every subsystem (INDI, camera, mount, focuser, filter wheel,
rotator, dome, switch, weather, safety monitor). 544 log lines, no crash.
It started its own indiserver: `port: 7624, using FIFO: /tmp/indiFIFO`.

### Non-fatal errors that remain (expected, safe to ignore for INDI use)
- `libASICamera2.so`, `libatikcameras.so`, `libaltaircam.so` etc.: vendor SDKs
  we did not supply. Caught per provider in `CameraChooserVM.GetEquipment`;
  the app survives.
- `libhidapi-hidraw.so`: not installed. Only needed for MGEN autoguider.
- `Ephemeris file not found at <publish>/External/JPLEPH`: the JPL ephemeris.
  It IS present in the bitbucket external submodule (13 MB, arch-independent
  binary data) and can be copied from there if precise ephemerides are wanted.
- `USB devices path not found: /sys/bus/usb/devices`: WSL2 has no USB passthrough
  by default. Will not occur on the real mini PC.

## OPERATIONAL WARNING
`INDIClient` runs `pkill -9 indiserver` on startup (`KillExistingServer`, called
from `StartServerInFifoMode` at `INDIClient.cs:1349`) and claims port 7624 with
`/tmp/indiFIFO`. PINS assumes it OWNS the machine's indiserver. Running
KStars/Ekos at the same time will make them fight over the same daemon.
`test-indi-sim.sh` therefore uses port 7625 and `/tmp/indiFIFO-test`.

## RESOLVED: External now comes from a git repo (2026-08-26)

Answer arrived on issue #187 from **JohannesWorks** (another user, not the
maintainer): "The 'External' packages are now built from the repositories",
pointing at https://github.com/acocalypso/pinsx64

The dead Nextcloud zip has been replaced by a real git repo:

    https://github.com/nitr57/pins.external      (branch: main, Git LFS)

Layout: `JPLEPH`, `linux-arm64/`, `linux-x64/`. It IS Git LFS -- a plain API
fetch returns 133-byte pointer files. Clone it, do not download blobs:

```bash
git clone --depth 1 https://github.com/nitr57/pins.external.git
rsync -a pins.external/linux-x64/ <publish>/External/linux-x64/
cp      pins.external/JPLEPH      <publish>/External/JPLEPH
```

### Verified contents of linux-x64 (all genuine ELF x86-64)
ASI/libASICamera2.so, ASI/libEAFFocuser.so, ASI/libEFWFilter.so,
Nitecrawler/libNitecrawlerSDK.so, NOVAS/libnovas_c.so,
Oasis/liboasisfilterwheel.so, Oasis/liboasisfocuser.so, SOFA/libsofa_c.so,
**ToupTek/libtoupcam.so (60.6 MB, 215 Toupcam_* symbols exported)**,
Wanderer/libWandererCoverSDK.so, Wanderer/libWandererRotatorSDK.so

=> The ATR2600C has a NATIVE SDK path on x86-64, not only the INDI path.
   `ldd` on libtoupcam.so shows no unresolved dependencies.

Confirmed at runtime:
```
DllLoader: Loading bundled library: .../External/linux-x64/SOFA/libsofa_c.so
DllLoader: Loading bundled library: .../External/linux-x64/NOVAS/libnovas_c.so
DllLoader: Loading bundled library: .../External/linux-x64/ToupTek/libtoupcam.so
```
The "Ephemeris file not found" error also disappears once JPLEPH is copied.

Still absent (not shipped in pins.external, non-fatal, irrelevant to our gear):
libqhyccd, libPlayerOneCamera, libSVBCameraSDK, libaltaircam, libatikcameras,
libmallincam, libnncam, libogmacam, libomegonprocam, libgphoto2.

NOTE: our own `build-external-x64.sh` remains useful and is NOT obsolete --
it builds SOFA/NOVAS from the in-repo sources and is the fallback if the
LFS repo is unavailable. Both approaches produce working x86-64 libraries;
`pins.external` additionally provides the proprietary vendor SDKs we cannot
compile ourselves.

## acocalypso/pinsx64 -- prior art for the x64 port
https://github.com/acocalypso/pinsx64 (created 2026-05-06, last push
2026-06-28, no license file). NOT a fork of pins; a separate automation repo:
- `build-scripts/build-and-install-pins-x64.sh` (2148 lines) -- full x64 build
- `build-scripts/install-trixie-x64-from-release.sh` -- installs prebuilt .deb
- 23 GitHub Actions workflows, incl. `build-indi-trixie-package.yml` (builds
  INDI 2.1.9.x as .deb) and per-plugin package builds

Target OS is **Debian Trixie x64**, not Ubuntu. It installs OpenCV 4.11,
verifies INDI 2.1.9.x, installs ASTAP, sets up the FramingAssistant cache.
Relevant to our open `indi_toupbase` problem: it builds INDI from source
rather than relying on distro packages.

## Next steps
1. Install INDI on Ubuntu 24.04 and validate PINS against `indi_simulator_ccd`
   before touching real hardware. NOTE: distro `indi-bin` is 1.9.9 (old);
   the correct package source still needs to be determined -- the
   `mutlaqja` PPA index probe returned 20-byte stubs, so it was NOT verified.
2. Later test: assemble `External/linux-x64/` starting with ToupTek, to make
   the native-SDK camera path work independently of INDI.

## Multi-distro installer (2026-08-28)

Target set is now three machines:

| Role | Machine | OS |
|---|---|---|
| build/dev host | WSL2 | Ubuntu 24.04 |
| test target | quark mini laptop | CachyOS (Arch) |
| final target | astrobit minipc | undecided |

`setup-pins-x64.sh` is a single distro-detecting script rather than one script
per distro. Family is resolved from `ID` **and `ID_LIKE`**, which is what makes
derivatives work without being named: CachyOS sets `ID=cachyos ID_LIKE=arch`,
Mint sets `ID_LIKE="ubuntu debian"`. Verified against fixture `os-release`
files for CachyOS, EndeavourOS, Mint (accepted) and Fedora (cleanly rejected).

### What is and is not portable

An INDI driver links ~60 shared libraries (glibc, libstdc++, gnutls, krb5,
cairo, X11, libnova, cfitsio, gsl). A binary tarball of INDI built on Ubuntu
will not reliably run on rolling Arch: `libcfitsio.so.10`, `libnova-0.16.so.0`
and `libgnutls.so.30` are hard soname pins, plus udev rules and `/usr/local`
layout are host state, not payload.

| Component | Portable | Why |
|---|---|---|
| PINS publish tree | yes | `SelfContained=true`, ships its own .NET runtime |
| `External/linux-x64/*.so` | yes | vendor SDKs, `ldd`-clean, no distro deps |
| INDI + drivers | **no** | ~60 distro libs; build or package per distro |

So the installer builds INDI per-distro and treats only PINS as relocatable.

### Arch/CachyOS is much simpler than Ubuntu

`extra/libindi` is **2.2.4.2** (checked 2026-08-28) -- the exact version we
build from source on Ubuntu. The whole source-build path and its
`FIX_WARNINGS=OFF` workaround exist solely because Ubuntu 24.04 ships
`indi-bin` 1.9.9. That is an Ubuntu problem, not a Linux one.

Default per family (override with `INDI_FROM_SOURCE=0|1`):

| Family | INDI core | Why |
|---|---|---|
| arch | `pacman -S libindi` (2.2.4.2) | current in `extra`, no build |
| debian | source `v2.2.4.2` -> `/usr/local` | distro has 1.9.9, PPA noble pocket empty |

All 19 Arch package names in `pkgs_for_family` were verified to exist via the
archlinux.org packages API. Arch bundles headers with the library, so there
are no `-dev` counterparts; `systemd-libs` provides libudev and `curl`
provides libcurl.

### indi_toupbase is built from source on BOTH families

The Arch packaged alternatives were rejected:

- `aur/indi-3rdparty-drivers` 2.2.2 -- its PKGBUILD builds the entire 1.2 GB
  indi-3rdparty tree with a bare `make` (no `-j`) and depends on
  limesuite, urjtag, gpsd, pigpio, none of which we use.
- `aur/libindi-toupcam` 2.2.3.1 -- surgical, but `depends=(libindi=2.2.3.1)`
  hard-pins a version older than `extra/libindi` 2.2.4.2, so it conflicts with
  the core package or forces a downgrade.

Building just `indi-3rdparty/libtoupcam` + `indi-3rdparty/indi-toupbase` takes
a few minutes with `-j$(nproc)` and avoids both problems. Install prefix
follows the core: `/usr/local` for a source core, `/usr` for a distro one, so
indiserver finds the driver and the driver finds its SDK.

### Two indiservers on PATH is a real failure mode

A source install into `/usr/local/bin` sits alongside a distro
`/usr/bin/indiserver`. PATH order decides which one PINS spawns, and PINS
`pkill -9 indiserver`s everything on startup, so a stale 1.9.9 winning the PATH
fails in a confusing way (toupbase silently will not load). `stage_verify` now
runs `command -v -a indiserver` and warns when more than one is present.

### Session interrupted by reboot (2026-08-26 -> 08-28)
The INDI 2.2.4.2 source build in `x64-port/indi-build/indi-core/build` reached
100% but `sudo make install` never ran, and `~/pins-build` / `~/pins-run` did
not survive the reboot. The build tree itself did; an incremental `make`
confirmed nothing was left to compile.

## CachyOS (quark) RUNTIME VERIFICATION -- PASS (2026-08-30)

Target: quark mini laptop, CachyOS (Arch, rolling), 4 cores, GCC 16.2.1.
Full pipeline from a bare machine to `All checks passed` in ~20 minutes,
**zero source changes**, same as on Ubuntu.

```
indiserver: /usr/sbin/indiserver
toupbase driver: /usr/sbin/indi_toupcam_ccd
simulators: present
PINS binary: ELF 64-bit LSB pie executable, x86-64
runs: NINA 3.3.0.1053-nightly
SOFA/libsofa_c.so OK (424896 bytes)
NOVAS/libnovas_c.so OK (209704 bytes)
ToupTek/libtoupcam.so OK (60638712 bytes)
USB subsystem present
```

### The Arch path is dramatically cheaper than Ubuntu's

`cachyos-extra-v3/libindi` is **2.2.4.2** -- the identical version we build
from source on Ubuntu. The ~30 min INDI core build and the `FIX_WARNINGS=OFF`
GCC workaround are an *Ubuntu* problem (24.04 ships indi-bin 1.9.9), not a
Linux one. On Arch the core is a 5.4 MiB package download.

Stage timings on 4 cores:

| Stage | Time | Notes |
|---|---|---|
| deps | ~2 min | 10 packages + libindi (4 more) |
| indi | ~4 min | no core build; 221 MiB indi-3rdparty clone dominates |
| pins | ~6 min | .NET SDK 236 MB, PINS clone ~900 MB with submodules |
| external | ~1 min | pins.external LFS, 128 MiB |

**The linux-x64 build produced 0 errors and 426 warnings -- the exact same
warning count as the Ubuntu build.** Strong evidence the two are behaviorally
identical despite GCC 16, .NET 10.0.302 and a rolling toolchain.

### Three defects this run exposed

1. **indi-toupbase builds every ToupTek OEM rebrand.** `indi-toupbase`'s
   CMakeLists calls `build_touptek_driver` for Altair, Bresser, Mallincam,
   Meadecam, NNcam, Ogmacam, Omegon, StarshootG, SVBony and Teleskop, each
   defaulting to `On` with a `REQUIRED` find_package for its own vendor SDK.
   We install only libtoupcam, so configure dies:

   ```
   CMake Error at cmake_modules/FindALTAIRCAM.cmake:43 (message):
     Altaircam not found.  Please install Altaircam Library
   ```

   Fixed by passing `-DWITH_<BRAND>=Off` for the other ten. This was NOT an
   Arch quirk -- it would fail identically on Ubuntu; the 2026-08-26 session
   was interrupted by a reboot before `stage_indi` ever reached toupbase.

2. **libraw was missing.** PINS uses LibRaw for DSLR raw decoding. On Ubuntu
   it arrived incidentally with the other -dev packages; nothing pulls it in
   on Arch, so `link_system libraw.so` warned. `extra/libraw` 0.22.2 provides
   `libraw.so.25`. Added to both dependency lists.

3. **The duplicate-indiserver check never ran.** It used `command -v -a`,
   whose `-a` flag is a zsh/dash extension that bash's builtin rejects, so the
   check silently found nothing. Now `type -aP`, with each hit resolved via
   `readlink -f` before comparison -- necessary because Arch symlinks
   `/usr/sbin` to `/usr/bin`, which would otherwise report one binary twice
   and warn about a conflict that does not exist. Verified against three
   cases: merged sbin (no warning), two genuine binaries (warns), single
   install (no warning).

### Arch package notes
- All 21 package names verified against the archlinux.org API.
- Arch bundles headers with libraries: no `-dev` counterparts.
- `systemd-libs` provides libudev; `curl` provides libcurl.
- `base-devel` is a group, so `pacman -Qq base-devel` always fails and it
  lands in the "missing" list every run; `--needed` makes that a no-op.
- `icu` is listed explicitly: NINA.csproj does not set
  `InvariantGlobalization`, so .NET needs ICU at startup and its absence is a
  globalization exception that gives no hint a package is missing.
- Arch cfitsio ships both `libcfitsio.so` and `.so.10`, so the symlink step is
  a harmless no-op there rather than load-bearing as on Ubuntu.
- The installer never runs `pacman -Sy`: a refresh without an upgrade
  desynchronizes the sync DB from the installed set (classic partial-upgrade
  breakage). Preflight warns if the DB is more than 14 days old instead.

### Still to do on the quark
- `test-indi-sim.sh` against the simulators
- 90 s `./NINA` run, checking clean startup and shutdown through every
  subsystem (544 log lines on Ubuntu)
- Touch-N-Stars over the LAN -- note ufw is active on this machine and its
  port must be opened, same as SSH was
- ATR2600C on real USB: the first genuine hotplug test, impossible under WSL2
