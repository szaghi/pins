# PINS linux-x64 port — build notes

> **Installing on a new machine? Read [`INSTALL.md`](INSTALL.md) instead.**
> That is the step-by-step procedure, with troubleshooting and profile setup.
> This file is the evidence log: what was tried, what failed, and why each
> decision in the installer is the way it is. Kept chronological on purpose —
> the dated sections are the record that makes odd choices defensible later.

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

## CachyOS RUNTIME TESTS -- PASS (2026-08-30)

### Stage 1: PINS bare run (no hardware attached) -- PASS

Deliberately run with nothing connected. Hardware would add variables that
make a failure ambiguous: a crash with the camera plugged in could be the
port, the udev rules, the driver, or the camera.

- `Server fully initialized and running` **2 seconds** after launch
- PINS spawned its own indiserver: `PID 30139, port: 7624, using FIFO:
  /tmp/indiFIFO`, connected on attempt 1
- SOFA and NOVAS loaded from `External/linux-x64/` -- the
  `DllNotFoundException` that killed the first Ubuntu run does not recur
- **`libtoupcam.so` loaded successfully**, reporting `Found 0 ToupTek
  Cameras`: the ATR2600C native path is live, it simply has nothing to find
- `USB Device Watcher started` -- genuinely new; impossible under WSL2
- Ctrl-C after 90 s: all ten subsystems disconnected in order (Dome, Flat,
  Camera, Telescope, Filter Wheel, Focuser, Rotator, Switch, Weather, Safety
  Monitor), FIFO cleaned up, USB watcher stopped, no hang, no exit trace

Bundled libraries that loaded: SOFA, NOVAS, ASI (libASICamera2, libEFWFilter,
libEAFFocuser), ToupTek, Oasis, Nitecrawler, Wanderer -- matching the verified
`pins.external` inventory exactly.

Expected non-fatal `DllNotFoundException`s, one per vendor SDK not shipped in
pins.external: Altair, Atik, QHY, Ogma, Omegon, NNcam, Mallincam, SVBony,
PlayerOne, gphoto2. Each is caught per-provider in `CameraChooserVM` /
`FilterWheelChooserVM` and the app continues. Noisy, not broken.

### Stage 2: INDI simulators via test-indi-sim.sh -- PASS

Run separately from PINS. They must not overlap: `KillExistingServer`
(`INDIClient.cs:1485`) does a name-based `pkill -9 indiserver`, so PINS kills
the test server on port 7625 too, despite the deliberate port/FIFO split.

```
indiserver -> /usr/sbin/indiserver
indiserver running, PID 30307, port 7625, FIFO /tmp/indiFIFO-test
received 31289 bytes of XML
devices announced: "CCD Simulator", "Telescope Simulator"
after CONNECTION=On: CCD_EXPOSURE CCD_INFO CCD_TEMPERATURE CCD_ABORT_EXPOSURE
CCD1 is a BLOB vector (the image path PINS consumes)
```

`CCD1 is a BLOB vector` is the load-bearing check: that is the exact mechanism
PINS consumes images through (`setBLOBVector` -> base64 -> `INDICamera.cs`).
The lazy-property behavior noted on Ubuntu reproduces here -- `CCD_EXPOSURE`
and `CCD1` are only defined *after* CONNECTION is switched On, so probing the
initial dump reports them missing on a healthy server.

### OPEN QUESTION: phantom Alpaca devices

With no hardware attached, every device class reported exactly one Alpaca
device:

```
Found 1 Alpaca Cameras / Telescopes / Focusers / Rotators / Domes
Found 1 Alpaca Switch Hubs / Safety Monitors / Filter Wheels
Found 1 Alpaca Cover Calibrators / Observing Conditions
```

Something is answering Alpaca discovery (UDP 32227). This is NOT a port
problem -- it would behave identically on Ubuntu -- but it means PINS will
offer phantom devices in the chooser. Identify the responder before trusting
the device list on the rig:

```bash
ss -lunp | grep 32227
curl -s http://localhost:11111/management/v1/description
```

### Still outstanding
- ATR2600C attached: expect `Found 1 ToupTek Cameras`. This is the first real
  USB hotplug test in the whole port and the one thing WSL2 could never do.
- Mount attached, after the camera passes: one device at a time, so any
  failure has exactly one candidate cause.
- Touch-N-Stars over the LAN. ufw is active on this machine and its port must
  be opened, the same way SSH was (`sudo ufw allow from 192.168.1.0/24 to any
  port <port> proto tcp`).
- Deliberate mid-sequence aborts with 52 MB frames, to exercise the 500 ms
  `StaleBlobDebounce` window in `INDICamera.cs:38-46`. INDI's `setBLOBVector`
  carries no per-exposure correlation id, so that debounce is a real code path
  and nothing so far has touched it.

## ATR2600C HARDWARE ENUMERATION -- PASS (2026-08-30)

The first real USB hotplug test of the whole port, and the one thing WSL2
could never do.

```
Found 1 ToupTek Cameras
Found 1 ToupTek Devices        <- the camera's integrated filter wheel
```

### Identifying the camera on the bus
`lsusb` reports it as:

```
Bus 002 Device 007: ID 0547:13da Anchor Chips, Inc. USB3.0 Camera
```

**Do not grep lsusb for "touptek".** ToupTek-family cameras identify by their
Cypress/Anchor USB controller (VID `0547`, sometimes `04b4`), not by any brand
string, so a brand-name grep finds nothing on a perfectly healthy device.

### udev
`libtoupcam`'s `99-toupcam.rules` covers exactly those two vendor IDs:

```
SUBSYSTEM=="usb", ATTRS{idVendor}=="0547", MODE="0666"
SUBSYSTEM=="usb", ATTRS{idVendor}=="04b4", MODE="0666"
```

The file's own comment says to copy it to `/etc/udev/rules.d`, but the CMake
install puts it in `/usr/lib/udev/rules.d/` and that is sufficient on modern
systemd -- both are search paths. Verified in effect:

```
$ ls -l /dev/bus/usb/002/007
crw-rw-rw- 1 root root 189, 134 Aug 30 11:07
```

`crw-rw-rw-` (0666) is the check that matters; `crw-rw-r--` would mean the
rule did not apply and PINS could not open the device without root.

### indi_toupcam_ccd also works
```
HotPlugManager: ToupbaseCCDHotPlugHandler initialized.
HotPlugManager: udev monitor initialized successfully (callback ID: 0).
```

That is `INDI::HotPlugManager` -- the API that exists only in INDI >= 2.x and
is the entire reason Ubuntu needs a source build. On Arch it came free with
`extra/libindi` 2.2.4.2.

### Two independent paths to the same camera

| Path | Mechanism | PINS counter |
|---|---|---|
| Native SDK | `External/linux-x64/ToupTek/libtoupcam.so` in-process | `ToupTek Cameras` |
| INDI | `indi_toupcam_ccd` over TCP 7624 | `INDI Cameras` |

`Found 0 INDI Cameras` with the camera attached is CORRECT: PINS only loads
the toupcam driver into its indiserver when the INDI camera is selected in the
UI, so the native path wins on a plain startup. Both paths want exclusive USB
access -- if `indi_toupcam_ccd` holds the camera open, native enumeration can
fail, and vice versa. Worth remembering when a camera "disappears".

## THE PLUGINS WERE NEVER BUILT (2026-08-30)

The installer produced a PINS that ran perfectly and had **no user interface**.
`verify` reported "All checks passed" for a build nobody could actually use.

Root cause: `ninaAPI` and `Touch-N-Stars` are git submodules under
`NINA.Plugins/`. Neither is in `NINA.sln`; neither is referenced by
`NINA.csproj`. So `dotnet publish NINA/NINA.csproj` yields a complete,
working binary with no API server. Per AGENTS.md the headless product's
entire user surface is the Touch-N-Stars Vue app talking to the backend
through ninaAPI, so without them there is nothing to drive.

Symptoms, none of which look like a missing plugin:
- nothing listening on port 1888 (`ss -tlnp | grep 1888` empty)
- no `PluginLoader` lines anywhere in the log
- `~/.local/share/NINA/Plugins/` does not exist at all
- PINS otherwise starts, enumerates hardware and shuts down cleanly

### Plugin folder location
`Constants.cs:26` -> `UserExtensionsFolder = APPLICATIONTEMPPATH/Plugins/<ver>`,
where `APPLICATIONTEMPPATH` is `LocalApplicationData/NINA` and `<ver>` is
MAJOR.MINOR.BUILD. On Linux `LocalApplicationData` is `~/.local/share`, giving:

```
~/.local/share/NINA/Plugins/3.3.0/
```

### Layout: one subfolder per plugin, with its full dependency set
`PluginAssemblyLoadContext` (`PluginLoader.cs:719-730`) resolves a plugin's
dependencies from the directory of the plugin DLL itself, recursively. So each
plugin gets its own subfolder containing everything it needs. This is why the
entire `bin` directory is copied rather than just the plugin assembly, and why
doing so cannot clobber PINS's own assemblies.

```
~/.local/share/NINA/Plugins/3.3.0/ninaAPI/         176 files, 53 MB
~/.local/share/NINA/Plugins/3.3.0/Touch-N-Stars/   167 files, 47 MB
```

`EmbedIO.dll` + `Swan.Lite.dll` in the ninaAPI folder are the HTTP server
serving port 1888.

### Two traps when building them
1. **Target framework must be pinned.** `ninaAPI.csproj` has a `net10.0`
   ItemGroup that `ProjectReference`s the in-tree PINS projects, and a
   `net8.0-windows` one that pulls NINA 3.2.0.9001 from NuGet instead. Build
   with `-f net10.0` explicitly or the wrong configuration can be selected.
2. **Touch-N-Stars' assembly is `TouchNStars.dll`**, not `Touch-N-Stars.dll`
   (`AssemblyName` in its csproj differs from the folder name). A verify check
   keyed on the folder name reports a present plugin as missing.

### Verified working (2026-08-30)
```
$ ss -tlnp | grep 1888
LISTEN 0 0 *:1888 *:* users:(("NINA",pid=32919,fd=386))

$ curl -s http://localhost:1888/v2/api/equipment/camera/info
{"Response":{...,"Connected":false},"Error":"","StatusCode":200,"Success":true,"Type":"API"}
```

`Connected:false` with zeroed fields is correct for an enumerated but
unconnected camera.

`verify` now returns rc=1 when ninaAPI is absent, so a PINS with no interface
can never report "All checks passed" again.

### ufw
Port 1888 must be opened for anything but localhost to reach the UI, exactly
as SSH needed:

```bash
sudo ufw allow from 192.168.1.0/24 to any port 1888 proto tcp
```

## THE PLUGIN FOLDER IS 3.0.0, NOT THE APP VERSION (2026-08-30)

Deploying plugins to a folder named after the application version puts them
somewhere PINS never looks, and it fails **silently**: the app starts, the
plugins are simply absent, and any copy previously installed from the official
plugin repository wins instead.

`Constants.cs:26` keys the folder on `ApplicationVersionWithoutRevision`, which
`Constants.cs:35-39` reads from the `PluginMinimumApplicationVersion` assembly
metadata of NINA.Plugin -- **not** from `CoreUtil.Version`. That metadata is set
nowhere in this repo, so the fallback applies and the folder is `3.0.0` even
though PINS is 3.3.0.1053:

```
~/.local/share/NINA/Plugins/3.0.0/
```

### Folder names must match the plugin's display Name
Not the project name, not the assembly name:

| Plugin | Assembly | Folder |
|---|---|---|
| ninaAPI | `ninaAPI.dll` | `Advanced API` |
| Touch-N-Stars | `TouchNStars.dll` | `Touch N Stars` (spaces) |

That is the folder the official repository installs into, and
`TouchNStarsServer.cs:29` resolves its web root from
`Assembly.GetExecutingAssembly().Location`, so the running copy's own directory
is what matters. Deploying beside a downloaded copy under a different name
leaves two installations and the downloaded one loads.

### The symptom this produced
Both plugins reported `Successfully loaded plugin`, ninaAPI served port 1888
correctly, and yet nothing listened on 5000:

```
ERROR|TouchNStarsServer.cs|Start|77|failed to start web server:
System.ArgumentException: The directory name
'/home/stefano/.local/share/NINA/Plugins/3.0.0/Touch N Stars/app'
does not exist. (Parameter 'path')
```

The loaded Touch-N-Stars was the *downloaded* one in `3.0.0/Touch N Stars/`,
which has 7 files and no `app/`, while our build sat unused in
`3.3.0/Touch-N-Stars/`. EmbedIO refuses to start a static-folder module whose
directory is missing, so the whole TNS web server aborts -- the plugin loads
but serves nothing.

### Two ports, two servers
| Port | Server | Serves |
|---|---|---|
| 1888 | ninaAPI (`API.cs`) | REST API, `/v2/api/...` |
| 5000 | Touch-N-Stars (`TouchNStarsServer.cs`) | the Vue UI at `/` |

Hitting `/` on 1888 gives `404 ... EmbedIO.HttpException: No module was able to
serve the requested path`, which looks like a broken deployment but is just the
wrong port. Both need opening in ufw; the frontend on 5000 calls the API on
1888.

### Verified working (2026-08-30)
```
$ ss -tln | grep -E ":1888|:5000"
LISTEN 0 0 *:1888 *:*
LISTEN 0 0 *:5000 *:*

$ curl -s -o /dev/null -w "%{http_code}" http://localhost:5000/
200
```

## PINS LISTENS ON THREE PORTS, NOT TWO (2026-08-30)

A firewalled host needs **all three** opened or the UI loads but never becomes
usable:

| Port | Server | Purpose | Source |
|---|---|---|---|
| 1888 | ninaAPI (EmbedIO) | REST API, `/v2/api/...` | `ninaAPI Settings.Designer.cs:40` |
| 5000 | Touch-N-Stars (EmbedIO) | the Vue UI at `/` | `TNS Settings.Designer.cs:52` |
| **4782** | **PINS Kestrel** | **SignalR: notifications, progress, dialogs** | `NINA/Program.cs:28`, `appsettings.json:13` |

```bash
for p in 1888 5000 4782; do
  sudo ufw allow from 192.168.1.0/24 to any port $p proto tcp
done
```

### The symptom when only 4782 is blocked
The UI loads and looks healthy. The setup wizard advances to step 5 (GPS),
displays for a moment, then silently returns to the start. Nothing in the PINS
log indicates a problem.

`SetupPage.vue:305-318` waits 2.5 s at step 5 and calls `previousStep()` if
`store.isBackendReachable` is false. That flag (`store.js:413-419`) requires
**five** conditions:

```
isApiConnected && isTnsPluginConnected && isApiVersionNewerOrEqual
  && isTnsPluginVersionNewerOrEqual && isWebSocketConnected
```

With 4782 blocked the first four pass and only the WebSocket fails, so the
browser console shows three successes then the bounce:

```
TNS Plugin Version: 1.2.4.0
api Port: 1888
API Version: 2.2.15.0
Backend not reachable
[SignalRNotificationService] Connecting to SignalR at: http://<host>:4782/hubs/notifications   <- repeating forever
```

Diagnosing this from the shell is misleading: `ss -tln` shows 4782 LISTENing on
`0.0.0.0`, and every curl from the quark itself succeeds. Only a connection
*from the LAN* reveals it:

```bash
# on the quark -> works;  from another machine -> blocked
bash -c 'cat < /dev/null > /dev/tcp/192.168.1.36/4782'
```

There is also a separate EmbedIO WebSocket at `ws://<host>:1888/v2/socket`
which answers `101 Switching Protocols` and is NOT the one the reachability
check depends on. Testing it and concluding "the WebSocket works" is a trap.

### Not a bug: the wizard skips step 4
`SetupPage.vue:299` deliberately skips step 4 on non-mobile platforms -- it is
an Android/iOS permission step. Jumping 3 -> 5 is correct.

## FIRST LIGHT: ATR2600C EXPOSURE ON CACHYOS -- PASS (2026-08-30)

End-to-end proof of the port: ToupTek SDK -> PINS -> image pipeline -> browser
UI, on real hardware.

### Camera connected, reporting real sensor geometry
```
Connected: True     XSize: 6224   YSize: 4168   PixelSize: 3.76
GainMin: 100        GainMax: 10000              CanSetTemperature: True
```
6224x4168 at 3.76 um is the IMX571, 25.9 MP -- the actual ATR2600C sensor, not
defaults.

### Exposure
```
CameraVM.cs|Capture|752|Starting Exposure - Exposure Time: 2s;
  Filter: ; Gain: 160; Offset 2000; Binning: 1x1;
```
No error followed, and `LastDownloadTime` moved from `-1` (never downloaded) to
**0.2608029**.

A 6224x4168 16-bit frame is ~52 MB, so 261 ms is roughly 200 MB/s: the camera
negotiated **USB 3.0** properly. A frame taking seconds instead would indicate
a USB 2.0 fallback, worth checking on the rig.

### Notes for interpreting a manual snapshot
- `/v2/api/image-history` stays empty: it records sequence frames, not manual
  snapshots from the UI.
- `/v2/api/image/0` returns HTTP 200 with a ~91 byte JSON error for the same
  reason. Neither is a fault.
- `LastDownloadTime` is the reliable signal that a manual capture completed.
- Sensor read 38.1 C with the cooler off, normal for a TEC camera idling
  indoors. Cooling is a separate check still to do.

### Still outstanding
- TEC cooler: set a target temperature and confirm it pulls down
- The mount, added on its own so any failure has one candidate cause
- The `StaleBlobDebounce` abort path (see below) -- note this applies ONLY to
  the INDI camera route. The camera is currently connected through the native
  ToupTek SDK, where that code is not involved, so testing it means
  reconnecting the camera as an INDI device first.

## OPENCV 4.11 IS UNUSABLE ON A MODERN DISTRO (2026-08-30)

**Symptom:** the browser UI hangs forever after starting an exposure. The
exposure itself completes -- `LastDownloadTime` updates -- but the API request
never returns.

**Cause:** `Camera.cs:606` writes a `temp.png` and reads it back through
`System.Windows.Compat`'s `Bitmap(string)`, which is backed by `Cv2.ImRead`
(`Drawing/Extensions.cs:115`). So **every ninaAPI image return goes through
OpenCV**. The bundled `libOpenCvSharpExtern.so` from
`OpenCvSharp4.official.runtime.linux-x64` **4.11.0.20250507** fails to dlopen,
the call throws, and `CameraCapture` never completes.

The library is present in the publish -- `ldd` is what reveals the problem:

```
libtesseract.so.4    not found      libavcodec.so.58   not found
libgtk-x11-2.0.so.0  not found      libavformat.so.58  not found
libgdk-x11-2.0.so.0  not found      libavutil.so.56    not found
libtiff.so.5         not found      libswscale.so.5    not found
libIlmImf-2_5.so.25  not found
```

Nine unresolved sonames, all obsolete. The NuGet runtime is built against
Ubuntu 20.04-era libraries. On rolling Arch the majors have moved far past
them: ffmpeg 63/61/10 vs 58/56/5, tiff 6 vs 5, tesseract 5.5.3 vs 4, OpenEXR
long past 2.5, and **gtk2 has been dropped from the official repos entirely**.

Installing the old versions is not a fix. The AUR has `libtiff5`, `openexr2`
and `gtk2`, but **no `tesseract4` and no ffmpeg-4 package**, so the set cannot
be completed -- and pinning five obsolete libraries on a rolling distro would
be a permanent maintenance burden anyway.

### The fix: bump to 4.13.0.20260627
That release drops every problematic dependency. Its full `NEEDED` list is
GTK **3**, cairo, pango, harfbuzz, freetype, glib, X11, drm and libstdc++ --
all present on any desktop -- with the image codecs statically linked:

```
$ ldd libOpenCvSharpExtern.so   # 4.13, on CachyOS
  (no "not found" lines)
```

Verified end to end on the quark: capture returns a JPEG, decoded to an
800x536 mono image showing real sensor noise and hot pixels.

`NINA/NINA.csproj` now pins 4.13.0.20260627 for both the managed
`OpenCvSharp4` and the runtime package. The runtime line is conditioned on
`linux-x64`, so Windows and arm64 builds are unaffected. Build: 0 errors.

**This is the first and so far only source change the linux-x64 port has
required.** Everything before it was tooling and packaging.

### Note on the capture API
`/v2/api/equipment/camera/capture?duration=N` returns immediately with
`{"Response":"Capture started"}`. The image is fetched by a **second** call
with `getResult=true`, which answers `{"Response":"Capture already in
progress"}` until the frame is ready, then returns
`{"Response":{"Image":"<base64 JPEG>"}}`. Firing overlapping capture requests
makes it look stuck when it is not.

## THE INSTALLER DEFAULTS TO UPSTREAM, NOT YOUR FORK (2026-08-30)

A "from scratch" rebuild reproduced the OpenCV hang even though the fix was
committed and pushed, because `stage_pins` cloned **upstream nitr57/pins
branch develop** -- the defaults -- which does not carry the fix:

```
$ cd ~/pins-build-clean/pins && git log --oneline -1
75e49f03e INDI Telescope: goto home pos fix        <- upstream, not the fork
$ grep OpenCvSharp4\" NINA/NINA.csproj
  Version="4.11.0.20250507"                        <- the broken one
```

Two ways this bites:
1. Forgetting `PINS_REPO`/`PINS_BRANCH` silently builds someone else's tree.
2. An **existing** clone under `--work-dir` is reused as-is and never updated,
   so even a fresh-looking work dir can be stale.

Both look like "the build ignored my changes" rather than "the build used a
different source".

Fixes applied:
- `-R/--pins-repo` and `-B/--pins-branch` flags, so the override does not
  depend on getting env-var placement right.
- The pins stage now always prints the remote, branch and commit it is
  actually building.

To build the fork:
```bash
./setup-pins-x64.sh -R git@github.com:szaghi/pins.git -B linux-x64 \
    --work-dir ~/pins-build --publish-dir ~/pins-run all
```

### verify now catches a broken OpenCV
It sits in the publish root rather than under `External/`, and PINS starts and
captures perfectly without it -- only the image *return* breaks. `verify` now
runs `ldd` on it and fails with the specific missing sonames plus the fix:

```
WARN libOpenCvSharpExtern.so cannot load, missing: libtesseract.so.4 ...
WARN the UI will hang after an exposure; needs OpenCvSharp >= 4.13
```

## INDI CAMERA PATH + ABORT RACE -- PASS (2026-08-30)

The second, independent route to the ATR2600C, and the one code path nothing
had exercised.

### Why no INDI camera appears by default
PINS starts `indiserver` empty and loads drivers on demand by writing
`start <driver>` into `/tmp/indiFIFO` (`INDIClient.cs:265`).
`INDIInteraction.GetCameras` (`NINA.Equipment/Utility/INDIInteraction.cs:47`)
reads **`CameraSettings.IndiDriver`** from the active profile and starts only
that driver. A fresh profile has it set to `'None'`, so the log reads
`Found 0 INDI Cameras` and nothing is wrong.

Set it to the driver executable name -- for ToupTek-family cameras
`indi_toupcam_ccd` (`/usr/bin/`, XML label "Toupcam"):

```bash
curl "http://<host>:1888/v2/api/profile/change-value?settingpath=CameraSettings-IndiDriver&newValue=indi_toupcam_ccd"
```

**A restart is required.** Re-listing devices returns a cached set; only a
restart re-enumerates with the new driver. After it:

```
CameraChooserVM.cs|GetEquipment|247|Found 1 INDI Cameras
$ pgrep -af indi_toupcam
46507 indi_toupcam_ccd            <- started by indiserver via the FIFO
```

Note Touch-N-Stars' `INDIController` has routes for focuser, filterwheel,
rotator, telescope, weather, switches and flatpanel but **not camera**, so the
driver must be set through the profile API rather than the UI.

### Telling the two paths apart
Both cameras are listed simultaneously and are distinguishable by id:

| id | Path |
|---|---|
| `ToupTek_tp-2-1-7-0547-13da` | native SDK (USB address in the id) |
| `ToupTek ATR2600C` | INDI (the INDI device name) |

Connected, the INDI one reports `DisplayName: ToupTek ATR2600C (INDI)`, same
6224x4168 at 3.76 um. A 2 s capture returned a 101 KB JPEG.

They contend for exclusive USB access, so disconnect one before connecting the
other.

### The StaleBlobDebounce abort race -- 3/3 PASS
`INDICamera.cs:38-46` debounces stale BLOBs in a 500 ms window because INDI's
`setBLOBVector` carries no per-exposure correlation id. With 52 MB frames the
timing is real, and only a deliberate mid-exposure abort exercises it.

Procedure: start 60 s, abort after 8-10 s, immediately start 2 s, fetch the
result. A leaked stale frame would be obvious -- 30x the integration time at
38 C, where dark current dominates, is far brighter.

Mean pixel value of the returned 800x536 frames:

```
  indi     50.74    <- baseline, a normal 2 s exposure
  abort1   51.08    <- fresh
  abort2   52.38    <- fresh
  abort3   52.46    <- fresh
```

All three post-abort frames match the 2 s baseline rather than a 60 s
exposure, so the debounce correctly discarded the aborted BLOB every time.

### Decision: native ToupTek SDK is the camera path
Both routes are verified working, and the native SDK is the chosen default.
`CameraSettings.IndiDriver` is left at `'None'`, so no INDI camera driver is
started and the camera is reached in-process through
`External/linux-x64/ToupTek/libtoupcam.so`.

Rationale: fewer moving parts. The native path is one library in the publish;
the INDI path adds an indiserver child process, a FIFO, a TCP hop and the
BLOB debounce. The INDI route remains available and tested -- set
`IndiDriver=indi_toupcam_ccd` and restart to switch -- and stays the fallback
if the bundled SDK ever breaks on a future distro update.

Confirmed after reverting:
```
Found 1 ToupTek Cameras
Found 0 INDI Cameras
pgrep indi_toupcam -> 0 processes
```

## HEQ5 PRO VIA EQDIR -- PASS (2026-08-30)

```
Connected: True   DisplayName: EQMod Mount (INDI)
RightAscension 19:58:40   Declination +90 00' 00"   <- pointing at the pole,
SiderealTime 13.98        AtPark False               correct home position
```

### Getting there: four separate obstacles

**1. The kernel had no modules.** `modprobe ftdi_sio` failed with "Module not
found in directory /lib/modules/7.2.0-1-cachyos". The installed package was
`linux-cachyos 7.2.2-1`; the running kernel was 7.2.0-1, whose module tree had
been deleted by the upgrade. **Zero** modules were loadable, not just ftdi_sio.
This is the classic rolling-distro trap: a `pacman -Syu` that bumps the kernel
breaks module loading until reboot, silently, while everything already loaded
keeps working. On an observatory machine that means discovering it at dusk.
Reboot fixed it, and `ftdi_sio` now autoloads.

**2. USB devices evicting each other.** The dock presents two hubs -- `1-4`
(USB 2.0, mount) and `2-3` (USB 3.0, camera). The kernel log showed the camera
disconnecting in the same second the mount enumerated. Not a power budget: the
hub reports Self Powered / MaxPower 0mA and the FT232R draws only 90 mA.
RESOLVED (see below): they do coexist. The eviction was a transient during
replugging, not a limitation.

**3. The wrong driver, from a misread topology.** The cable plugs into the
mount's *handset port* with **no handset in the chain** -- that is EQDIR, so
the driver is `indi_eqmod_telescope`, not `indi_synscan_telescope`. With
SynScan selected the failure was clean and well-instrumented:

```
[SynScan] Setting CONNECTION_MODE to CONNECTION_SERIAL   OK
[SynScan] Enabling DEVICE_AUTO_SEARCH                    OK
[INDI Message][SynScan] [ERROR] Serial read error: Timeout error.
```

`indi_eqmod_telescope` is NOT in INDI core -- it lives in indi-3rdparty, like
toupbase, so `pacman -S libindi` leaves you with no mount driver. **The `indi`
stage now builds it automatically**, alongside toupbase, and `verify` fails if
it is absent. Defaults are correct: `WITH_AHP_GT` is already Off (an AHP GoTo
controller upgrade) and alignment/EQMod-alignment/scope-limits are On.

To build it by hand:

```bash
mkdir -p ~/pins-build/build-eqmod && cd ~/pins-build/build-eqmod
cmake -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release \
      ~/pins-build/indi-3rdparty/indi-eqmod
make -j$(nproc) && sudo make install
```

**4. Profile changes are lost on pkill.** `change-value` reports
`"Updated setting"` immediately but the profile is only written to disk on a
**graceful** shutdown. Killing PINS with `pkill -x NINA` discards it, and the
next start silently reuses the old driver -- which looked like the setting not
taking effect at all. Use `pkill -TERM` and allow it to exit, then confirm the
value landed in
`~/.local/share/NINA/Profiles/<guid>.profile` before restarting.

Also note a stale driver process survives a PINS restart and keeps holding the
device name, so `pkill -f indi_<old>` as well when switching drivers.

### Raw serial probes are not a reliable test
`:e1` (EQMod) and `Kx` (SynScan) were silent at 9600/38400/115200 even though
the mount was fine. The driver handles DTR/RTS and timing that a shell probe
does not. Let the driver decide; its log gives a better verdict than a
hand-rolled query.

### Site coordinates were mangled
The profile held `Latitude 414416.9` / `Longitude 125323.33` -- 41 44' 16.9"
and 12 53' 23.33" written as concatenated digits instead of decimal degrees,
presumably from the setup wizard. PINS wants decimal degrees; corrected to
41.7380 / 12.8898.

The mount stores its own copy, pushed at connect time, so correcting the
profile is not enough: **disconnect and reconnect** for the mount to pick it
up. Before the reconnect `mount/info` still reported the bad value while the
profile read correctly.

## CAMERA + MOUNT TOGETHER -- PASS (2026-08-30)

Both devices connected at once, and a capture ran without disturbing the mount:

```
camera: Connected=True  ToupTek ATR2600C  6224x4168  temp=20.4
mount:  Connected=True  EQMod Mount (INDI)  Dec +90 00' 00"
capture -> 135 KB JPEG
mount RA 18:04:56 -> 18:05:22 across the capture   <- still tracking sidereal
```

They sit on different controllers -- FTDI on bus 1 (USB 2.0 hub), camera on
bus 2 (USB 3.0 hub) -- and the kernel logs no disconnects once both are
settled. The earlier apparent eviction was a transient while replugging.

### The ToupTek device ID encodes the USB bus path
This cost time and looks exactly like a broken camera:

```
ToupTek_tp-2-1-7-0547-13da   <- before replug, later shown as (OFFLINE)
ToupTek_tp-2-4-6-0547-13da   <- after replug, the live device
```

The `tp-2-4-6` segment is bus/port/device. **Replugging the camera, or any
change in USB enumeration order, changes its PINS device id.** Connecting to
the old id fails with:

```
System.Exception: Unable to connect to device 'ToupTek ATR2600C (547-13da)'
  (ID: ToupTek_tp-2-1-7-0547-13da). Make sure it's plugged in, turned on,
  and set up correctly.
```

...while the camera is plugged in, powered, and perfectly healthy. PINS keeps
the stale entry in the chooser marked `(OFFLINE)` alongside the live one, so
**always re-read `camera/list-devices` after any replug** rather than reusing
a remembered id. A saved profile that auto-connects a specific camera id will
break the same way after a cable change or a hub re-enumeration.

Confirming the SDK is healthy, independent of PINS:

```bash
~/pins-build/build-toupbase/toupcam_test
  Found 1 Toupcam device(s):
    Device 0: ATR2600C (ID: usb-0547-13da-2-3-4)
  Successfully opened device: ATR2600C
```

That binary talks straight to libtoupcam with no PINS involved, so a pass there
narrows any remaining fault to PINS or the device id.

## stop-pins.sh -- clean shutdown (2026-08-30)

`x64-port/stop-pins.sh` stops PINS and everything it leaves behind.

**Do not use `pkill -9 NINA`.** PINS writes the active profile to
`~/.local/share/NINA/Profiles/<guid>.profile` only on a **graceful** shutdown,
so a hard kill silently discards every setting changed since the last clean
exit -- INDI driver selection, site coordinates, cooling duration. This cost
real time during the mount work: the driver was set to eqmod, the API replied
`"Updated setting"`, PINS was killed with `pkill`, and the next start quietly
reused synscan. It looked like the setting had no effect.

```bash
./stop-pins.sh              # SIGTERM, wait, escalate only if stuck
./stop-pins.sh --status     # show what is running, change nothing
./stop-pins.sh --tests-only # stop the 7625 harness, leave PINS alone
./stop-pins.sh --force      # SIGKILL now (discards unsaved profile changes)
```

Order matters and is deliberate:

1. **Test harness first**, matched by `indiserver.*indiFIFO-test` rather than
   by name -- a bare `pkill indiserver` would take PINS's own server down too.
2. **SIGTERM to PINS**, then wait (`GRACE_SECONDS`, default 15). A clean exit
   persists the profile, disconnects equipment and runs `CleanupServer`, which
   stops its indiserver and removes `/tmp/indiFIFO` by itself.
3. **Leftovers only if step 2 failed.** Orphaned INDI drivers matter more than
   they appear: one that outlives PINS keeps holding its device name, so the
   next start seems to load the OLD driver even after the profile changed.
4. **Verify**, exiting non-zero if any of 1888/5000/4782/7624/7625 is still
   held.

Verified on the quark against a live install:

```
== Stopping PINS
   sent SIGTERM, waiting up to 15s for a clean exit
   exited cleanly (profile saved)
== Clearing INDI leftovers
   no orphaned indiserver          <- PINS had already done it
   no orphaned drivers
== Final state
   nothing running                 EXIT: 0
```

...and the profile on disk still read `indi_eqmod_telescope` afterwards.

## TPPA (Three Point Polar Alignment) -- BUILT AND LOADING (2026-08-30)

The plugin stage originally built only ninaAPI and Touch-N-Stars, so polar
alignment was absent from the UI. TPPA is in the fork already, as the
`PolarAlignment` submodule (`nitr57/nina.plugin.polaralignment`), and it builds
for Linux unmodified:

```
Successfully loaded plugin Three Point Polar Alignment version 1.0.0.0
  by Stefan Berg @isbeorn
```

Identity, which decides where it must be deployed:

| | |
|---|---|
| submodule | `NINA.Plugins/PolarAlignment` |
| csproj | `NINA.Plugins.PolarAlignment.csproj`, targets `net10.0-windows7.0;net10.0` |
| assembly | `NINA.Plugins.PolarAlignment.dll` |
| **folder** | **`Three Point Polar Alignment`** (its `AssemblyTitle`) |

ninaAPI already carries the server half: `TPPASocket` is registered at
`/v2/tppa` (`API.cs:55`) and answers a WebSocket upgrade with
`101 Switching Protocols`, logging `TPPA WebSocket connected`. Touch-N-Stars
has the matching client in `src/services/websocketTppa.js`. So the only thing
missing was the plugin itself.

### Which other plugins could be added
Checked every submodule's target framework:

| Plugin | Targets | Linux? |
|---|---|---|
| ninaAPI | `net10.0` | yes -- deployed |
| Touch-N-Stars | `net10.0-windows;net10.0` | yes -- deployed |
| PolarAlignment | `net10.0-windows7.0;net10.0` | yes -- deployed |
| joko.nina.plugins | `net10.0-windows7.0;net10.0` | buildable, not deployed |
| LiveStack | `net10.0-windows;net10.0` | buildable, not deployed |
| nina.plugin.phd2tools | `net10.0-windows;net10.0` | buildable, not deployed |
| NINA.Joko.Plugin.TenMicron | `net8.0-windows7.0` | **no** |
| nina.plugin.orbuculum | `net7.0-windows` | **no** |

Adding one is a single entry in the `for spec in` list in `stage_plugins`,
formatted `"Display Name:path/to/plugin.csproj"`. The display name must match
the plugin's `AssemblyTitle`, not the project or assembly name -- that is the
folder the official plugin repository would install into, and the folder the
running assembly resolves its own resources from.

## ASTAP PLATE SOLVER (2026-08-30)

Needed by TPPA (which solves each of its three points), framing and centering.
PINS defaults `PlateSolverType` to ASTAP but leaves `ASTAPLocation` empty, so a
fresh profile fails at the first solve.

### Why the upstream .deb rather than the AUR
- `aur/astap-bin` is 2023.09.11 with **zero votes** — effectively abandoned.
- `aur/astap` builds from source through **Lazarus**, a Pascal IDE toolchain:
  a large makedepend and a build-time risk on a rolling distro.
- The upstream `.deb` (7 MB, CLI-2026.07.30) extracts with `ar` + `tar` and
  installs identically on Arch and Debian, with no AUR helper.

### Use astap_cli, not the GUI binary
```
astap      -> ELF, dynamic, needs Qt5
astap_cli  -> ELF, STATICALLY linked, 0 unresolved libraries
```
On a headless rig the static CLI is one less thing to break on a distro update.
`PlateSolveSettings-ASTAPLocation` is set to `/opt/astap/astap_cli`.

### Database file extension differs by format
The verify check originally globbed `*.290` and reported **"star database: 0
files, 1.3G total"** on a perfectly good install — the size was right, the count
was nonsense.

| Series | Extension | d80 |
|---|---|---|
| D-series (d05/d20/d50/d80) | `*.1476` | 1476 files |
| H-series (h17/h18) | `*.290` | — |

`.290` is the older H-series format. `astap_db_count()` now matches both.

Sizes and usable fields, from hnsky.org:

| DB | Size | Reliable field |
|---|---|---|
| d05 | 100 MB | 0.6–10° |
| d20 | 400 MB | 0.3–10° |
| d50 | 900 MB | 0.2–10° |
| **d80** | **1.2 GB** | **0.15–10°** — installer default, override with `ASTAP_DB` |

Databases are hosted on SourceForge, not hnsky.org:
`https://sourceforge.net/projects/astap-program/files/star_databases/<db>_star_database.deb/download`

### Verified on the quark
```
astap_cli: /opt/astap/astap_cli
star database: 1476 file(s)
== All checks passed
$ /opt/astap/astap_cli
ASTAP astrometric solver version CLI-2026.07.30
```
A solve against real sky is still untested — that needs stars.
