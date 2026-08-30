# PINS on x86-64 Linux — installation guide

Step-by-step for a fresh machine: the astrobit mini PC, a replacement laptop,
or any x86-64 box that will drive the rig.

Every command and version here was verified on **CachyOS (rolling Arch), kernel
7.2.2, GCC 16.2.1, .NET 10.0.302, libindi 2.2.4.2**, with a **ToupTek ATR2600C**
camera and a **SkyWatcher HEQ5 Pro** mount, on 2026-08-30.

This is the *procedure*. Start at [`README.md`](README.md) for what PINS is and
how the pieces fit together, [`PLUGINS.md`](PLUGINS.md) for the plugin story,
and [`BUILD-NOTES.md`](BUILD-NOTES.md) for **why** each decision was made — the
dead ends, the version traps, the evidence.

---

## Contents

1. [Before you start](#1-before-you-start)
2. [Install](#2-install)
3. [Verify](#3-verify)
4. [Firewall](#4-firewall)
5. [First run](#5-first-run)
6. [Profile setup](#6-profile-setup)
7. [Equipment](#7-equipment)
8. [Daily operation](#8-daily-operation)
9. [Troubleshooting](#9-troubleshooting)
10. [Reference](#10-reference)

---

## 1. Before you start

### Requirements

| | |
|---|---|
| Architecture | x86-64 (the installer refuses anything else) |
| Distro | Arch family (`pacman`) or Debian family (`apt`) |
| Disk | 8 GB free minimum; the full build downloads ~2.5 GB |
| Time | 40–60 min on 4 cores, less on more |
| Network | Needed throughout — several large clones |

### Update the system first, and reboot

```bash
sudo pacman -Syu        # Arch family
sudo apt update && sudo apt full-upgrade   # Debian family
```

**Reboot if the kernel was upgraded.** This is not optional hygiene. On a
rolling distro, a kernel upgrade deletes the *running* kernel's module tree, so
**no kernel module can load at all** until you reboot — including `ftdi_sio`,
which your mount needs. Everything already loaded keeps working, so the machine
looks fine until you plug something in. Discovering this at dusk is a bad night.

Check they match:

```bash
uname -r                  # running kernel
pacman -Q linux-cachyos   # installed package (adjust for your kernel package)
```

### Consider an LTS kernel for the observatory machine

The astrobit will sit unattended. A rolling kernel means every `-Syu` is a
potential module break. `linux-cachyos-lts` (or your distro's LTS) trades new
hardware support for not having to think about this.

---

## 2. Install

### 2.1 Get the tooling

Clone only `x64-port/`, not the whole 1.3 GB history:

```bash
git clone --filter=blob:none --no-checkout --depth 1 \
    --branch linux-x64 git@github.com:szaghi/pins.git ~/pins-tooling
cd ~/pins-tooling
git sparse-checkout set --no-cone x64-port
git checkout
cd x64-port
```

That is ~730 KB and about a second. A plain `git clone` pulls 1.3 GB and leaves
eight empty submodule directories.

### 2.2 Run the installer

```bash
./setup-pins-x64.sh \
    --pins-repo git@github.com:szaghi/pins.git \
    --pins-branch linux-x64 \
    all
```

> **The repo and branch flags are not optional.** The defaults point at
> **upstream** `nitr57/pins` / `develop`, which does not carry the linux-x64
> fixes — notably the OpenCvSharp bump without which the UI hangs after every
> exposure. Omit them and you get a build that looks fine and fails in use.
>
> The `pins` stage prints the remote, branch and commit it is building. **Read
> that line.** It is the only thing standing between you and an hour spent
> debugging upstream's code.

Expect several `sudo` prompts. On 4 cores:

| Stage | Time | What happens |
|---|---|---|
| `deps` | 1–2 min | ~21 distro packages, plus `libindi` on Arch |
| `indi` | 5–10 min | INDI core (Arch: package; Debian: source build ~30 min), then `indi_toupbase` and `indi_eqmod` from source. Clones indi-3rdparty, ~1.2 GB |
| `pins` | 15–30 min | .NET SDK (236 MB), PINS clone with submodules (~900 MB), build, publish |
| `plugins` | 3–5 min | ninaAPI, Touch-N-Stars and Three Point Polar Alignment, then `npm ci` and the Vue build |
| `astap` | 5–15 min | ASTAP plate solver (7 MB) plus the star database (D80, **1.2 GB**) |
| `external` | 1–3 min | `pins.external` via Git LFS, ~130 MB |
| `verify` | seconds | checks |

Stages are independent and re-runnable. If one fails, fix it and re-run that
stage alone rather than starting over:

```bash
./setup-pins-x64.sh --pins-repo ... --pins-branch ... pins
```

### 2.3 Where things land

| Path | Contents |
|---|---|
| `~/pins-build/` | scratch: source clones, build trees. Deletable afterwards |
| `~/pins-run/` | the published application. **This is what you run** |
| `~/.local/share/NINA/` | profiles, logs, plugins — your data |
| `~/.dotnet/` | the .NET SDK |
| `/usr/bin/indi_*` | INDI drivers |

Override the first two with `--work-dir` and `--publish-dir`.

---

### 2.4 If pins.external is unavailable

The `external` stage clones `nitr57/pins.external` for the vendor SDKs plus
SOFA and NOVAS. That repository replaced a Nextcloud zip whose share URL
started returning 503, so it is worth knowing there is a fallback if it goes
the same way.

`build-external-x64.sh` builds SOFA and NOVAS from the sources shipped **in
this repository** — 248 C files for SOFA, and NOVAS has its own Linux makefile
— and symlinks the system cfitsio and libraw:

```bash
./build-external-x64.sh
```

It cannot produce the proprietary vendor SDKs (ToupTek, ASI, and the rest), so
it only covers the INDI path and the astrometry libraries. Enough to run, not
enough for a native-SDK camera.

## 3. Verify

```bash
./setup-pins-x64.sh verify
```

A good result, exit code 0:

```
   indiserver: /usr/bin/indiserver
   toupbase driver: /usr/bin/indi_toupcam_ccd
   eqmod driver: /usr/bin/indi_eqmod_telescope
   simulators: present
   PINS binary: ELF 64-bit LSB pie executable, x86-64
   runs: NINA 3.3.0.1053-nightly
   SOFA/libsofa_c.so OK (424896 bytes)
   NOVAS/libnovas_c.so OK (209704 bytes)
   ToupTek/libtoupcam.so OK (60638712 bytes)
   libOpenCvSharpExtern.so OK (all deps resolve)
   ninaAPI plugin: ~/.local/share/NINA/Plugins/3.0.0/Advanced API/
   Touch-N-Stars plugin: present
   Touch-N-Stars web UI: present
   Three Point Polar Alignment: present
   astap_cli: /opt/astap/astap_cli
   star database: 1476 file(s)
   USB subsystem present

== All checks passed
```

Do not proceed past a failure. Each maps to a fix in
[§9 Troubleshooting](#9-troubleshooting).

### Optional: test INDI on its own

Before involving PINS, confirm INDI works standalone:

```bash
./test-indi-sim.sh
```

It uses port **7625** and `/tmp/indiFIFO-test` deliberately, staying clear of
PINS's 7624. The load-bearing line is:

```
CCD1 is a BLOB vector (the image path PINS consumes)
```

**Do not run it at the same time as PINS.** PINS runs `pkill -9 indiserver` on
startup, which is name-based and will kill the test server too.

---

## 4. Firewall

**PINS listens on three ports.** Open all three or the UI loads but never
becomes usable:

| Port | Server | Purpose |
|---|---|---|
| 1888 | ninaAPI | REST API |
| 5000 | Touch-N-Stars | the web UI you open in a browser |
| 4782 | PINS Kestrel | SignalR: notifications, progress, dialogs |

```bash
for p in 1888 5000 4782; do
    sudo ufw allow from 192.168.1.0/24 to any port $p proto tcp
done
sudo ufw status
```

Adjust the subnet to your LAN. Restricting by subnet rather than opening to the
world matters for a machine that may travel.

Using firewalld instead:

```bash
for p in 1888 5000 4782; do
    sudo firewall-cmd --permanent --add-port=$p/tcp
done
sudo firewall-cmd --reload
```

> **4782 is the one everyone forgets.** With only it blocked, the UI loads, the
> setup wizard reaches the GPS step, displays for a moment and silently returns
> to the start. Nothing in the PINS log indicates a problem. See
> [§9.4](#94-the-setup-wizard-bounces-back-to-the-start).

---

## 5. First run

```bash
cd ~/pins-run && ./NINA
```

Startup takes a couple of seconds. Expect a wall of `DllNotFoundException`
errors for vendor SDKs you do not own — Altair, Atik, QHY, Ogma, Omegon, NNcam,
Mallincam, SVBony, PlayerOne, gphoto2. **These are normal.** Each is caught per
provider and the application continues.

Signs of a healthy start:

```
INDI server started in FIFO mode with PID ..., port: 7624
DllLoader: Loading bundled library: .../SOFA/libsofa_c.so
DllLoader: Loading bundled library: .../NOVAS/libnovas_c.so
Server fully initialized and running.
USB Device Watcher started
```

Then open the UI from any machine on the LAN:

```
http://<host-ip>:5000
```

Complete the setup wizard. It skips step 4 on non-mobile platforms — that is an
Android/iOS permission step, not a fault.

---

## 6. Profile setup

The profile lives at `~/.local/share/NINA/Profiles/<guid>.profile` and holds
everything below.

> **The profile is written to disk only on a graceful shutdown.** Kill PINS with
> `pkill -9` and every setting changed since the last clean exit is silently
> discarded. Always stop it with [`stop-pins.sh`](#8-daily-operation).

### 6.1 Site coordinates — decimal degrees

PINS wants **decimal degrees**, not degrees-minutes-seconds. Entering
41°44'16.9" as `414416.9` gives a nonsense site, and the first visible symptom
is `TimeToMeridianFlipString: 24:00:00` rather than an error.

```
41°44'16.9" N  ->  41.7380
12°53'23.33" E ->  12.8898
```

Set them in the UI, or via the API:

```bash
H=<host-ip>
curl "http://$H:1888/v2/api/profile/change-value?settingpath=AstrometrySettings-Latitude&newValue=41.7380"
curl "http://$H:1888/v2/api/profile/change-value?settingpath=AstrometrySettings-Longitude&newValue=12.8898"
curl "http://$H:1888/v2/api/profile/change-value?settingpath=AstrometrySettings-Elevation&newValue=400"
```

**The mount keeps its own copy**, pushed at connect time. After correcting the
profile you must **disconnect and reconnect the mount** for it to take, or
`mount/info` will keep reporting the old value while the profile reads
correctly.

### 6.2 INDI drivers

PINS starts `indiserver` empty and loads only the driver named in the profile
for each device type. A fresh profile has them all set to `None`, which is why
a working mount reports `Found 0 INDI Telescopes`.

| Device | Setting | Value for this rig |
|---|---|---|
| Mount | `TelescopeSettings-IndiDriver` | `indi_eqmod_telescope` |
| Camera | `CameraSettings-IndiDriver` | `None` — native SDK is used instead |

```bash
curl "http://$H:1888/v2/api/profile/change-value?settingpath=TelescopeSettings-IndiDriver&newValue=indi_eqmod_telescope"
```

**A restart is required.** Re-listing devices returns a cached set; only a
restart re-enumerates with the new driver. And stop PINS *gracefully* or the
change is lost.

Touch-N-Stars has INDI settings for focuser, filterwheel, rotator, telescope,
weather, switches and flatpanel — **but not camera**. For the camera the profile
API is the only route.

#### Which mount driver?

| Connection | Driver |
|---|---|
| EQDIR cable into the mount's handset port, **no handset** | `indi_eqmod_telescope` |
| Through a SynScan handset | `indi_synscan_telescope` |

Getting this wrong produces `Serial read error: Timeout error.`, which reads
like broken hardware.

### 6.3 Camera path

Both routes to a ToupTek camera work and are tested. **The native SDK is the
default and the recommendation**: one library in the publish tree, versus an
indiserver child process, a FIFO, a TCP hop and BLOB debouncing.

Leave `CameraSettings-IndiDriver` at `None` for native. To use INDI instead, set
it to `indi_toupcam_ccd` and restart — the INDI camera then appears alongside
the native one, distinguishable by id.

### 6.4 Plugins

Six plugins are built and deployed by the `plugins` stage, into
`~/.local/share/NINA/Plugins/3.0.0/`:

| Plugin | Why it matters |
|---|---|
| Advanced API | the REST API — without it there is no UI at all |
| Touch 'N' Stars | the web UI, plus its Vue app |
| Three Point Polar Alignment | TPPA |
| Hocus Focus | star detection, autofocus, aberration inspector |
| Livestack | live stacking |
| Phd2 Tools | PHD2 guiding helpers |

Confirm they loaded:

```bash
grep 'Successfully loaded plugin' ~/.local/share/NINA/Logs/*.log | tail -6
```

**Plugins from the official NINA repository will not work here**, and most
cannot be ported: PINS is headless, so a plugin whose only export is a WPF
dockable view loads and is then unreachable. See **[PLUGINS.md](PLUGINS.md)**
for the full explanation, the list of all 96 repository plugins, and how to
assess one with `check-plugin.sh` before spending time on it.

### 6.5 Plate solver (ASTAP)

Plate solving underpins **TPPA, framing and centering**. PINS defaults
`PlateSolverType` to ASTAP, but `ASTAPLocation` starts empty, so a fresh
profile fails at the first solve with no useful message.

The `astap` stage installs the solver to `/opt/astap`. Point the profile at the
**CLI** binary:

```bash
curl "http://$H:1888/v2/api/profile/change-value?settingpath=PlateSolveSettings-ASTAPLocation&newValue=/opt/astap/astap_cli"
```

`astap_cli` rather than `astap`: the CLI build is statically linked with zero
library dependencies, while the GUI binary needs Qt5. On a headless rig that is
one less thing to break on a distro update.

#### Star databases

ASTAP does nothing without one. Pick by the narrowest field you will solve:

| Database | Size | Reliable field |
|---|---|---|
| `d05` | 100 MB | 0.6–10° |
| `d20` | 400 MB | 0.3–10° |
| `d50` | 900 MB | 0.2–10° |
| **`d80`** | **1.2 GB** | **0.15–10°** — the installer default |

Override with `ASTAP_DB=d50` before running the stage. The files live beside
the binary in `/opt/astap`. Note the extension differs by format: the D-series
installs `*.1476` (1476 files for d80), while the older H-series (h17/h18) uses
`*.290` — a check that looks only for `.290` reports "0 files" on a perfectly
good 1.3 GB install.

### 6.6 Cooling ramp

`CoolingDuration` is the ramp time in minutes. The UI's own field default (10)
is used when the caller does not specify, which makes cooling look
pathologically slow. Set it to taste — 1 minute matches Windows NINA's usual
configuration:

```bash
curl "http://$H:1888/v2/api/profile/change-value?settingpath=CameraSettings-CoolingDuration&newValue=1"
```

A slower ramp is gentler on the sensor and reduces condensation risk on the
optical window. On a humid night, consider leaving it longer.

---

## 7. Equipment

### 7.1 ToupTek camera (ATR2600C)

Plug it in. `lsusb` shows it as:

```
Bus 002 Device 007: ID 0547:13da Anchor Chips, Inc. USB3.0 Camera
```

**Do not grep for "touptek".** ToupTek cameras identify by their Cypress/Anchor
USB controller (VID `0547`, sometimes `04b4`), not a brand string.

Check permissions — the `99-toupcam.rules` installed by the `indi` stage should
give mode `0666`:

```bash
ls -l /dev/bus/usb/002/007      # want crw-rw-rw-
```

Verify the SDK independently of PINS:

```bash
~/pins-build/build-toupbase/toupcam_test
```

A successful open there means any remaining fault is in PINS or the device id,
not the camera.

### 7.2 SkyWatcher mount (HEQ5 Pro via EQDIR)

The EQDIR cable is an FTDI serial adapter:

```
Bus 001 Device 010: ID 0403:6001 FTDI FT232 Serial (UART) IC
```

It must create a device node:

```bash
ls -l /dev/ttyUSB0      # crw-rw-rw- ... expected
```

If missing, see [§9.6](#96-devttyusb0-does-not-appear).

**The mount must be powered on.** The FTDI chip is powered by the cable, so
`/dev/ttyUSB0` appears whether or not the mount is on — its presence proves
nothing about the mount.

### 7.3 Camera and mount together

They coexist. Verified: a capture runs while the mount stays connected and
keeps tracking sidereal time through the frame transfer.

> **The ToupTek device id encodes the USB bus path**, e.g.
> `ToupTek_tp-2-4-6-0547-13da`. **Any replug changes it.** PINS keeps the dead
> entry in the chooser marked `(OFFLINE)` beside the live one, and connecting to
> the stale id fails with *"Unable to connect ... Make sure it's plugged in,
> turned on, and set up correctly"* while the camera is perfectly healthy.
>
> Re-read the device list after any replug. A saved profile that auto-connects a
> specific camera id will break after a cable change.

---

## 8. Daily operation

### Start

```bash
~/pins-tooling/x64-port/start-pins.sh
```

It stops any running instance first, launches detached, waits for all three
ports and prints the URLs:

```
== Running
   pid: 6604
   plugins: Advanced API, Touch 'N' Stars, Three Point Polar Alignment

   Touch-N-Stars:  http://192.168.1.36:5000
   API:            http://192.168.1.36:1888/v2/api/version
   Log:            /tmp/pins.log
```

```bash
./start-pins.sh --foreground   # run in this terminal, log on screen
./start-pins.sh --no-stop      # do not stop a running instance first
```

Starting without stopping the old instance is the failure worth avoiding:
Kestrel cannot bind 4782, the new process aborts with a core dump, and the log
shows a stack trace that says nothing about the real cause.

### Run it as a service (recommended for the observatory machine)

So PINS comes up on boot without anyone logging in:

```bash
mkdir -p ~/.config/systemd/user
cp ~/pins-tooling/x64-port/pins.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now pins
sudo loginctl enable-linger $USER     # survive logout — required on a headless box
```

```bash
systemctl --user status pins
systemctl --user restart pins
journalctl --user -u pins -f
```

It is a **user** service, not a system one: PINS keeps its profile, logs and
plugins under `~/.local/share/NINA` and needs no privilege, since the udev
rules already give the camera mode 0666.

The unit sends **SIGTERM** and allows 60 s, which is the graceful path that
saves your profile, and uses `KillMode=control-group` so indiserver and the
INDI drivers die with it rather than being orphaned.

With the service enabled, use `systemctl --user restart pins` rather than the
scripts, or the two will fight over the ports.

### Stop — always with the script

```bash
~/pins-tooling/x64-port/stop-pins.sh
```

```bash
./stop-pins.sh --status      # what is running, changes nothing
./stop-pins.sh --tests-only  # stop the 7625 harness, leave PINS alone
./stop-pins.sh --force       # SIGKILL now — discards unsaved profile changes
```

It sends SIGTERM and waits, so PINS persists the profile, disconnects equipment
and cleans up its indiserver and FIFO. Only then does it clear leftovers.

### Update

```bash
cd ~/pins-tooling && git pull
cd x64-port
./stop-pins.sh
./setup-pins-x64.sh --pins-repo git@github.com:szaghi/pins.git \
                    --pins-branch linux-x64 pins
./setup-pins-x64.sh --pins-repo ... --pins-branch ... plugins
./setup-pins-x64.sh verify
```

`plugins` must follow `pins`: the `pins` stage wipes and recreates the publish
directory.

---

## 9. Troubleshooting

### 9.1 The UI hangs after starting an exposure

The exposure completes but the browser never updates.

**Cause:** OpenCV cannot load. Every ninaAPI image return goes through
`Cv2.ImRead`, so when the native library fails to dlopen the request never
completes.

```bash
ldd ~/pins-run/libOpenCvSharpExtern.so | grep 'not found'
```

Nine missing sonames (`libtesseract.so.4`, ffmpeg 4, `libtiff.so.5`, OpenEXR
2.5, GTK 2) means you built OpenCvSharp **4.11**, whose runtime targets Ubuntu
20.04-era libraries. **4.13 or newer is required.** Confirm you built the
`linux-x64` branch, not upstream `develop`:

```bash
grep 'OpenCvSharp4"' ~/pins-build/pins/NINA/NINA.csproj   # want 4.13.0.20260627
```

Installing the old libraries is not a fix — tesseract 4 and ffmpeg 4 are not
packaged on current Arch at all.

### 9.2 `verify` says the ninaAPI plugin is missing

The plugin folder is version-scoped and the version is **`3.0.0`**, keyed on
`PluginMinimumApplicationVersion`, *not* the application version:

```bash
ls ~/.local/share/NINA/Plugins/3.0.0/
#   Advanced API/      <- ninaAPI
#   Touch N Stars/     <- with spaces
```

Folder names must match each plugin's **display name**, not the project or
assembly name. Re-run the `plugins` stage.

### 9.3 The browser gets a 404 at `/`

You are on the wrong port. **1888 is the REST API; the UI is on 5000.** Hitting
`/` on 1888 gives `EmbedIO.HttpException: No module was able to serve the
requested path`.

If 5000 gives a 404, the Vue app was not deployed:

```bash
ls ~/.local/share/NINA/Plugins/3.0.0/"Touch N Stars"/app/index.html
```

Missing means the `plugins` stage could not build it — check `npm` is installed
and re-run that stage.

### 9.4 The setup wizard bounces back to the start

It reaches the GPS step, shows for a moment, then returns. Nothing in the PINS
log.

**Cause:** port **4782** is blocked. The wizard requires
`store.isBackendReachable`, which needs five conditions including a SignalR
WebSocket to 4782. With only that port closed the other four pass and the
failure is silent.

```bash
sudo ufw allow from 192.168.1.0/24 to any port 4782 proto tcp
```

Diagnosing this from the machine itself is misleading: `ss -tln` shows 4782
listening on `0.0.0.0` and every local request succeeds. Test **from another
machine**:

```bash
bash -c 'cat < /dev/null > /dev/tcp/<host-ip>/4782'
```

The browser console names it directly — repeated
`[SignalRNotificationService] Connecting to SignalR at: http://<host>:4782/...`
followed by `Backend not reachable`.

### 9.5 A profile setting will not take effect

You changed a value, the API said `"Updated setting"`, and after a restart it is
back to the old one.

**Cause:** PINS was killed rather than stopped. The profile is written only on a
graceful shutdown. Use `stop-pins.sh`, and confirm before restarting:

```bash
grep -o 'indi_eqmod_telescope' ~/.local/share/NINA/Profiles/*.profile
```

Also check no **orphaned INDI driver** survived — one that outlives PINS keeps
holding its device name, so the next start appears to load the old driver:

```bash
pgrep -af 'indi_'
```

### 9.6 `/dev/ttyUSB0` does not appear

With the FTDI adapter visible in `lsusb` but no device node:

```bash
lsmod | grep ftdi_sio          # loaded?
sudo modprobe ftdi_sio
```

If `modprobe` reports *"Module not found in directory /lib/modules/<version>"*,
**your running kernel does not match the installed one** — a kernel upgrade
deleted the running kernel's modules. No module at all can load. Reboot.

```bash
uname -r                       # running
ls /lib/modules/               # what is available
```

Make it persist across boots if it does not autoload:

```bash
echo ftdi_sio | sudo tee /etc/modules-load.d/ftdi.conf
```

On some distros `brltty` hijacks FTDI devices as Braille displays and steals the
port seconds after it appears. Not present on CachyOS; if you see the node
vanish, check for it.

### 9.7 The mount will not connect

```
[INDI Message][...] [ERROR] Serial read error: Timeout error.
```

In order of likelihood:

1. **Wrong driver.** EQDIR cable with no handset needs
   `indi_eqmod_telescope`; through a handset needs `indi_synscan_telescope`.
2. **Driver not installed.** `indi_eqmod_telescope` is not in INDI core. The
   `indi` stage builds it; check with `which indi_eqmod_telescope`.
3. **Mount not powered.** `/dev/ttyUSB0` exists regardless.
4. **Stale driver process** holding the device name — `pgrep -af indi_`.

Raw serial probes are **not** a reliable test. `:e1` and `Kx` stay silent at
every baud rate on a perfectly working mount; the driver handles DTR/RTS and
timing that a shell probe does not. Trust the driver's log.

### 9.8 The camera will not connect but the SDK works

```
System.Exception: Unable to connect to device 'ToupTek ATR2600C (547-13da)'
  (ID: ToupTek_tp-2-1-7-0547-13da).
```

The device id encodes the USB path and changed when the camera was replugged.
Re-read the list and use the entry **not** marked `(OFFLINE)`:

```bash
curl -s "http://$H:1888/v2/api/equipment/camera/list-devices"
```

### 9.9 Plate solving fails / TPPA will not run

TPPA solves each of its three points, so a broken solver stops it immediately.

```bash
ls -l /opt/astap/astap_cli                     # the binary
ls /opt/astap/*.1476 /opt/astap/*.290 2>/dev/null | wc -l   # the database
curl -s "http://$H:1888/v2/api/profile/show?active=true" \
  | grep -o '"ASTAPLocation":"[^"]*"'
```

All three must be right: binary present, database non-empty, and
`ASTAPLocation` pointing at `/opt/astap/astap_cli`. An empty `ASTAPLocation`
is the default on a fresh profile.

Test the solver directly, outside PINS:

```bash
/opt/astap/astap_cli -f <some.fits> -r 30 -fov 0
```

Note TPPA also needs the mount connected and a **correct site** — see
[§6.1](#61-site-coordinates--decimal-degrees). With mangled coordinates it will
solve but compute nonsense.

### 9.10 Phantom Alpaca devices

With no hardware attached, every device class may report exactly one Alpaca
device. Something on the LAN is answering discovery on UDP 32227. Harmless but
it clutters the chooser:

```bash
ss -lunp | grep 32227
```

### 9.11 Cooling seems too slow

Not a fault — the setpoint is ramped over `CoolingDuration` minutes. Check the
log:

```
Cooling Camera. Target: -5 Duration: 00:10:00
```

See [§6.6](#66-cooling-ramp). Note the sensor reports **die** temperature, 10–15 °C
above ambient when idle: 35–38 °C in a 22 °C room is normal. Proof the TEC works
is the temperature going *below* ambient.

---

## 10. Reference

### Ports

| Port | Server | Notes |
|---|---|---|
| 1888 | ninaAPI REST | `/v2/api/...` |
| 5000 | Touch-N-Stars | the browser UI |
| 4782 | PINS Kestrel | SignalR — silent failures if blocked |
| 7624 | indiserver | PINS owns it; `pkill -9 indiserver` on startup |
| 7625 | test harness | `test-indi-sim.sh` only |

### Paths

| Path | Contents |
|---|---|
| `~/pins-run/` | the application |
| `~/pins-build/` | scratch, deletable |
| `~/.local/share/NINA/Profiles/<guid>.profile` | settings |
| `~/.local/share/NINA/Logs/` | logs |
| `~/.local/share/NINA/Plugins/3.0.0/` | plugins |
| `/tmp/indiFIFO` | PINS's indiserver control FIFO |

### Useful API calls

```bash
H=<host-ip>
curl -s "http://$H:1888/v2/api/version"
curl -s "http://$H:1888/v2/api/equipment/camera/info"
curl -s "http://$H:1888/v2/api/equipment/mount/info"
curl -s "http://$H:1888/v2/api/equipment/camera/list-devices"
curl -s "http://$H:1888/v2/api/profile/show?active=true"

# Capture is two-step: start, then fetch when ready
curl -s "http://$H:1888/v2/api/equipment/camera/capture?duration=2"
sleep 12
curl -s "http://$H:1888/v2/api/equipment/camera/capture?getResult=true&resize=true&size=800x600"
```

`LastDownloadTime` moving off `-1` is the reliable signal that a manual capture
completed. `image-history` stays empty for manual snapshots — it records
sequence frames only.

### Known-good versions

| Component | Version |
|---|---|
| Distro | CachyOS (rolling Arch) |
| Kernel | 7.2.2-1-cachyos |
| GCC | 16.2.1 |
| .NET SDK | 10.0.302 (must match `global.json`) |
| libindi | 2.2.4.2 |
| INDI drivers | `indi_toupcam_ccd`, `indi_eqmod_telescope` |
| OpenCvSharp | **4.13.0.20260627** (4.11 is broken on Linux) |
| PINS | 3.3.0.1053-nightly |

### Debian/Ubuntu differences

The installer handles both families, but note:

- **INDI core is built from source on Debian.** Ubuntu 24.04 ships `indi-bin`
  1.9.9 (2022), too old for `indi_toupbase`, and the mutlaqja PPA's noble pocket
  is empty. This adds ~30 minutes.
- Package names differ (`-dev` suffixes); the installer maps them.
- `/usr/sbin` is not merged with `/usr/bin`, so a source INDI in `/usr/local`
  can shadow or be shadowed by a distro one. `verify` warns when several
  `indiserver` binaries share the PATH.
