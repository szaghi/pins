# PINS on x86-64 Linux — installation guide

Step-by-step for a fresh machine: the astrobit mini PC, a replacement laptop,
or any x86-64 box that will drive the rig.

> ## Supported platform
>
> **Arch-based distributions only.** Everything in this directory is developed
> and tested on **CachyOS**. Other Arch derivatives (EndeavourOS, Manjaro,
> plain Arch) should work — same `pacman`, same package names — but are not
> tested.
>
> The installer contains a Debian/Ubuntu code path. **It has never completed an
> end-to-end run.** The only attempt stopped partway through the INDI stage and
> was never resumed, so treat `apt` support as untested scaffolding, not a
> supported target. If you try it, expect to fix things; see
> [§10.2](#102-the-debianubuntu-path).

Verified end to end on the versions in [§10.1](#101-known-good-versions), with
a **ToupTek ATR2600C** camera and a **SkyWatcher HEQ5 Pro** mount.

Start at [`README.md`](README.md) for what PINS is and how the pieces fit
together, [`PLUGINS.md`](PLUGINS.md) for the plugin story, and
[`BUILD-NOTES.md`](BUILD-NOTES.md) for **why** each decision was made — the
dead ends, the version traps, the evidence.

---

## Contents

1. [Before you start](#1-before-you-start)
2. [Install](#2-install)
3. [Verify the build](#3-verify-the-build)
4. [Plug in the hardware](#4-plug-in-the-hardware)
5. [Firewall](#5-firewall)
6. [First run](#6-first-run)
7. [Profile setup](#7-profile-setup)
8. [Daily operation](#8-daily-operation)
9. [Run it on boot](#9-run-it-on-boot)
10. [Reference](#10-reference)
11. [Troubleshooting](#11-troubleshooting)

---

## 1. Before you start

### 1.1 What you need

| | |
|---|---|
| Architecture | x86-64 (the installer refuses anything else) |
| Distro | **Arch family** (`pacman`) — see the box above |
| Disk | **12 GB free.** The build tree alone reaches ~10 GB |
| Time | 40–60 min on 4 cores, less on more |
| Network | Needed throughout — several large clones |
| Privileges | A user with `sudo`. The installer prompts several times |

One thing must already be on the machine before step 2.1, because you need it
*to fetch the installer*:

```bash
sudo pacman -S --needed curl
```

That is all. Everything else — compilers, CMake, INDI, Node, git, git-lfs, the
.NET SDK — is installed by the `deps` and `pins` stages. The full dependency
list, and who installs what, is in [§10.3](#103-every-dependency).

### 1.2 Do you already run KStars/Ekos on this machine?

**Then read this before installing.** PINS takes ownership of INDI on the whole
machine: on startup it runs `pkill -9 indiserver`, killing *any* INDI server,
including one started by Ekos. It then spawns its own on port 7624.

The two cannot run at the same time. Stop Ekos before starting PINS, or use a
different machine. Nothing warns you — Ekos simply loses its equipment.

### 1.3 Update the system first, and reboot

```bash
sudo pacman -Syu
```

> **Reboot if the kernel was upgraded.** This is not optional hygiene. On a
> rolling distro, a kernel upgrade deletes the *running* kernel's module tree,
> so **no kernel module can load at all** until you reboot — including
> `ftdi_sio`, which your mount needs. Everything already loaded keeps working,
> so the machine looks fine until you plug something in. Discovering this at
> dusk is a bad night.

Check they match before continuing:

```bash
uname -r                  # running kernel
pacman -Q linux-cachyos   # installed package
```

If the two differ, reboot now.

### 1.4 Consider an LTS kernel for the observatory machine

The astrobit will sit unattended. A rolling kernel means every `-Syu` is a
potential module break. `linux-cachyos-lts` trades new hardware support for not
having to think about this — install it *and make it the default boot entry*,
since installing it alone changes nothing.

### 1.5 Decide where it goes

The installer writes to one tree, `~/pins/`. You can move it, but only *before*
you start: changing your mind afterwards means rebuilding.

| Path | Contents | Survives a rebuild? |
|---|---|---|
| `~/pins/build/` | scratch: source clones, CMake trees, downloads (~10 GB) | yes — reused, not re-fetched |
| `~/pins/run/` | the published application (~354 MB). **This is what you run** | **no — wiped and recreated** |
| `~/.local/share/NINA/` | profiles, logs, `NINA.sqlite`, plugins — **your data** | yes, and untouched by builds |
| `~/.dotnet/` | the .NET SDK (~610 MB) | yes |
| `/opt/astap/` | plate solver + star database (~1.3 GB) | yes |
| `/usr/bin/indi_*` | INDI drivers | yes |

To put it elsewhere, pass `--pins-home DIR` to every command in §2 (or
`--work-dir` / `--publish-dir` to move the halves independently).

`build/` and `run/` cannot be the same directory, and the installer refuses if
you try: the `pins` stage does `rm -rf` on the publish directory, which would
delete the 1.2 GB of INDI clones on every rebuild.

Your data is deliberately in neither, so **uninstalling is `rm -rf ~/pins`**
and nothing is lost but build time.

---

## 2. Install

### 2.1 Get the installer

One file, 45 KB. No clone, no SSH key:

```bash
curl -fsSLO https://raw.githubusercontent.com/szaghi/pins/linux-x64/x64-port/setup-pins-x64.sh
chmod +x setup-pins-x64.sh
```

The installer is self-contained: it needs none of the other files in
`x64-port/`, and it clones the full repository itself. After §2.2 the whole
toolkit — `start-pins.sh`, `stop-pins.sh`, `pins.service` and the rest — lives
at **`~/pins/build/pins/x64-port/`**, which is the copy to use from then on.
The file you just downloaded is disposable.

### 2.2 Run it

```bash
./setup-pins-x64.sh all 2>&1 | tee ~/pins-install.log
```

By default this builds **`szaghi/pins`, branch `linux-x64`** — this fork, the
one these scripts come from. To build something else, pass `--pins-repo URL`
and `--pins-branch REF`.

> **Check what it is building.** The `pins` stage prints:
>
> ```
>    building: https://github.com/szaghi/pins.git
>      branch: linux-x64   commit: a1b2c3d
> ```
>
> Those lines scroll past in the middle of a 15–30 minute stage, which is why
> the command above pipes through `tee`. Afterwards:
>
> ```bash
> grep -A1 'building:' ~/pins-install.log
> ```
>
> Upstream `nitr57/pins` does **not** carry the linux-x64 fixes — notably the
> OpenCvSharp bump, without which the UI hangs after every exposure. A build
> from the wrong branch looks fine and fails in use.

> **A clone that already exists is reused, never updated.** If
> `~/pins/build/pins` is there from a previous run, the installer keeps it
> as-is — even if you now pass a different `--pins-repo` or `--pins-branch`.
> This bites on re-runs. To force a fresh clone, `rm -rf ~/pins/build/pins`
> first.

Expect several `sudo` prompts. On 4 cores:

| Stage | Time | What happens |
|---|---|---|
| `deps` | 1–2 min | 21 distro packages, plus `libindi` |
| `indi` | 5–10 min | `indi_toupcam_ccd` and `indi_eqmod_telescope` built from source. Clones indi-3rdparty, ~1.2 GB |
| `pins` | 15–30 min | .NET SDK (236 MB), PINS clone with submodules (~900 MB), build, publish |
| `plugins` | 3–5 min | six plugins, including `npm ci` and the Vue build |
| `astap` | 5–15 min | ASTAP plate solver (7 MB) plus the D80 star database (**1.3 GB**) |
| `external` | 1–3 min | vendor SDKs via Git LFS, ~80 MB |
| `verify` | seconds | checks |

**Stages are independent and re-runnable.** If one fails, fix the cause and
re-run that stage alone:

```bash
./setup-pins-x64.sh indi
```

Re-running a completed stage is safe: clones are reused, packages already
installed are skipped.

---

## 3. Verify the build

```bash
~/pins/build/pins/x64-port/setup-pins-x64.sh verify
```

Note the path: from here on use the copy in the build tree, not the one you
downloaded.

A good result reports the binary as an `ELF 64-bit` executable that responds to
`--help`, `libOpenCvSharpExtern.so` with no unresolved libraries, the three
vendor libraries (`libtoupcam.so`, `libsofa_c.so`, `libnovas_c.so`) present,
both INDI drivers installed, and `astap_cli` printing its version.

If `verify` warns about **two `indiserver` binaries on PATH**, see
[§11.7](#117-two-indiserver-binaries).

---

## 4. Plug in the hardware

Do this **before** configuring anything in PINS. Every driver and camera
setting in §7 is only verifiable with the equipment enumerated, and configuring
a device that is not plugged in means doing §7 twice.

### 4.1 The mount

Connect the EQDIR cable and power the mount on.

```bash
ls -l /dev/ttyUSB*        # expect /dev/ttyUSB0
lsmod | grep ftdi_sio     # the module must be loaded
```

Nothing there, and you upgraded the kernel without rebooting? That is the trap
from [§1.3](#13-update-the-system-first-and-reboot). Reboot.

### 4.2 The camera

Connect the camera. It draws real current — use its power supply, not bus
power.

```bash
lsusb | grep -i touptek
```

The `indi` stage installed `99-toupcam.rules`, which gives the camera node mode
`0666` so no root is needed. If access fails, replug it, or:

```bash
sudo udevadm control --reload-rules && sudo udevadm trigger
```

Exercise the camera without PINS in the picture:

```bash
~/pins/build/build-toupbase/toupcam_test
```

> **The ToupTek device id encodes the USB bus path.** Any replug into a
> different port changes it. A profile that auto-connects to the old id fails
> with a message that reads like broken hardware. If you move the cable, expect
> to re-select the camera in §7.3.

### 4.3 INDI on its own

Before involving PINS, confirm INDI talks to the hardware:

```bash
~/pins/build/pins/x64-port/test-indi-sim.sh
```

---

## 5. Firewall

**No firewall running?** Skip this section — Arch installs none by default.
Check with `sudo ufw status`; if ufw is not installed and `firewalld` is not
running, there is nothing to open.

PINS is **three servers**, and you need all three:

| Port | Server | Serves |
|---|---|---|
| 1888 | ninaAPI | the REST API, `/v2/api/...` |
| 5000 | Touch-N-Stars | the web UI you actually use |
| 4782 | PINS Kestrel | SignalR — notifications, progress, dialogs |

> **Opening only two of the three is the worst outcome.** Block 4782 alone and
> the UI loads, the setup wizard reaches its GPS step, then silently returns to
> the start with nothing in the log. That one cost an hour.

Port 7624 (`indiserver`) stays closed: PINS uses it on localhost.

With ufw:

```bash
sudo ufw allow from 192.168.0.0/16 to any port 1888,5000,4782 proto tcp \
     comment 'PINS'
sudo ufw status | grep -E '1888|5000|4782'
```

`192.168.0.0/16` rather than a single `/24`, so the rule still works when the
machine is on a phone hotspot at an observing site. Add `172.16.0.0/12` and
`10.0.0.0/8` if you use those ranges.

If ufw is installed but inactive, `ufw allow` succeeds and does nothing — run
`sudo ufw enable` first.

---

## 6. First run

```bash
~/pins/build/pins/x64-port/start-pins.sh --foreground
```

It waits for all three ports and prints the URLs. Stop it with Ctrl-C **only
now**, before you have configured anything. From §7 onward, use `stop-pins.sh`.

> **`pkill -9 NINA` discards your settings.** The profile is written only on a
> graceful shutdown: PINS persists it in an `ApplicationStopping` handler that
> also disconnects equipment and cleans up indiserver. A hard kill loses
> everything changed since the last clean exit. Use `stop-pins.sh`.

### Errors you will see at startup, and should ignore

Roughly 56 `DllNotFoundException` lines scroll past:

```
DllLoader failed to load library libatikcameras.so
DllLoader failed to load library libaltaircam.so
DllLoader failed to load library libqhyccd.so
```

PINS probes every vendor SDK it supports to populate the equipment lists.
`External/linux-x64/` ships only ASI, ToupTek, Nitecrawler, Oasis and Wanderer,
so the rest fail. **The one that matters is `libtoupcam.so`, which must load
without error:**

```bash
grep -i toupcam /tmp/pins.log | grep -ci error    # expect 0
```

A missing `JPLEPH` warning is also expected if the `external` stage has not run.

---

## 7. Profile setup

Open `http://<host-ip>:5000` in a browser. Set this once, for the commands
below:

```bash
H=192.168.1.45        # your host's IP
```

### 7.1 Site coordinates

> **Decimal degrees, not sexagesimal.** `41°44'16.9"` is `41.7380`, not
> `414416.9`. North and east are positive, south and west negative.

Convert with:

```bash
python3 -c 'print(41 + 44/60 + 16.9/3600)'    # 41.73803
```

Four decimals (~11 m) is plenty. Elevation is in metres.

> **The mount keeps its own copy of the site, refreshed only on reconnect.** If
> you change the coordinates while the mount is connected, disconnect and
> reconnect it, or it keeps using the old ones — with no error, just wrong
> pointing.

### 7.2 Equipment: the mount

Set the INDI mount driver to **`indi_eqmod_telescope`** — the installed binary
name, not the source package name `indi_eqmod`.

Driver changes need a restart. Do it gracefully:

```bash
~/pins/build/pins/x64-port/stop-pins.sh
~/pins/build/pins/x64-port/start-pins.sh
```

### 7.3 Equipment: the camera

Two routes, and the native one is what this port uses:

- **Native SDK** — the ToupTek `.so` loaded in-process. Faster, fewer moving
  parts. Select the camera by name.
- **INDI** — driver `indi_toupcam_ccd` over TCP. The fallback.

### 7.4 Plate solver

Point ASTAP at the CLI binary:

```
/opt/astap/astap_cli
```

> **Not `/opt/astap/astap`.** That is the GUI build and needs GTK2, which a
> headless machine does not have. It is symlinked into `/usr/local/bin` only
> because that is the name people type.

### 7.5 Confirm it persisted

Settings that appear to save and then revert are the most common complaint.
Verify explicitly:

```bash
~/pins/build/pins/x64-port/stop-pins.sh
~/pins/build/pins/x64-port/start-pins.sh
curl -s "http://$H:1888/v2/api/profile/show?active=true" | grep -o '"Latitude":[^,]*'
```

If the value reverted, the shutdown was not graceful.

---

## 8. Daily operation

```bash
~/pins/build/pins/x64-port/start-pins.sh     # start, wait for all three ports
~/pins/build/pins/x64-port/stop-pins.sh      # stop gracefully — always use this
```

Both take `--help`.

**After moving a USB cable**, the camera id changes ([§4.2](#42-the-camera)) and
a profile set to auto-connect fails on next start. Re-select the camera.

### Updating

```bash
cd ~/pins/build/pins && git pull
~/pins/build/pins/x64-port/setup-pins-x64.sh pins plugins
```

`astap` and `external` rarely change; re-run them only if the changelog says so.
The `pins` stage wipes `~/pins/run` — your profile is elsewhere and is not
affected.

---

## 9. Run it on boot

A systemd **user** service, so the rig comes up without anyone logging in.

```bash
mkdir -p ~/.config/systemd/user
cp ~/pins/build/pins/x64-port/pins.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now pins
sudo loginctl enable-linger $USER     # survive logout; required on a headless box
```

> **If you installed to a non-default location** with `--pins-home` or
> `--publish-dir`, edit `WorkingDirectory` and `ExecStart` in the unit first —
> they are hardcoded to `%h/pins/run`.

```bash
systemctl --user status pins
journalctl --user -u pins -f
```

The unit sends SIGTERM and waits 60 s, so the profile is saved on stop, and
kills the whole control group so `indiserver` and its drivers go too.

> **`start-pins.sh` and systemd do not know about each other.** If
> `systemctl --user stop pins` appears to do nothing, you probably have a second
> instance started by hand. Check with `pgrep -a NINA`.

---

## 10. Reference

### 10.1 Known-good versions

Verified on astrobit, 2026-09-16:

| | |
|---|---|
| Distro | CachyOS (rolling Arch) |
| Kernel | 7.2.5-1-cachyos |
| GCC | 16.2.1 |
| CMake | 4.4.3 |
| libindi | 2.2.4.2 |
| .NET SDK | 10.0.302 (must match PINS `global.json`) |
| Node / npm | 26.8.2 / 12.0.2 |
| git-lfs | 3.8.0 |
| ASTAP | CLI-2026.09.01, D80 database |
| PINS | 3.3.0.1053-nightly |
| Camera | ToupTek ATR2600C |
| Mount | SkyWatcher HEQ5 Pro (EQDIR) |

### 10.2 The Debian/Ubuntu path

The installer detects `debian|ubuntu` and carries an apt package list, a
from-source INDI build (Ubuntu ships 1.9.9 from 2022, too old for the
`HotPlugManager` API that toupbase needs) and a `/usr/sbin` adjustment.

**None of it has completed an end-to-end run.** The one attempt was interrupted
during the INDI stage and never resumed. Known problems if you try:

- `test-indi-sim.sh` suggests `apt install indi-bin libindi1`; **`libindi1`
  does not exist** on Ubuntu noble.
- The mutlaqja PPA's noble pocket was empty when last checked, so the INDI
  source build is the only route.
- `build-external-x64.sh` symlinks what its comments call "Ubuntu's cfitsio",
  but it runs on Arch — those paths need checking.

### 10.3 Every dependency

**Installed by the `deps` stage** (21 packages):

| Group | Packages |
|---|---|
| Build toolchain | `base-devel` (pulls in gcc, make, **binutils**, sudo, pkgconf, gawk, sed, grep, file), `cmake` |
| INDI build | `libnova` `cfitsio` `libusb` `zlib` `gsl` `libjpeg-turbo` `curl` `libtheora` `fftw` `libev` `systemd-libs` |
| Imaging | `icu` `libraw` |
| Vue frontend | `nodejs` `npm` |
| Git + large files | `git` `git-lfs` |
| Utilities | `rsync` `file` |
| INDI core | `libindi` from the distro (2.2.4.2 is current and sufficient) |

**Not distro packages — fetched by the installer:**

| What | Where it comes from | Lands in |
|---|---|---|
| .NET SDK 10.0.302 | Microsoft's `dotnet-install.sh`, 236 MB | `~/.dotnet/` |
| ASTAP + D80 database | `.deb` files from hnsky.org, unpacked with `ar` | `/opt/astap/` |
| Vendor SDK blobs | `nitr57/pins.external` via Git LFS | `~/pins/run/External/` |

**Implicit, and worth knowing about:**

- **`ar`** (from `binutils`, pulled in by `base-devel`) unpacks the ASTAP
  `.deb`s. Install the packages individually without `base-devel` and the
  `astap` stage fails with a confusing error.
- **`git-lfs` must be present before any clone.** `.gitattributes` puts
  `*.dll`, `*.xisf` and `NINA/External/**` under LFS with `required = true`, so
  a clone without it dies partway through checkout and leaves a repository that
  looks complete but is missing ~1500 files.
- **`curl`** fetches the installer itself — see [§1.1](#11-what-you-need).

### 10.4 Ports

| Port | Server | Open to LAN? |
|---|---|---|
| 1888 | ninaAPI (EmbedIO) | yes |
| 5000 | Touch-N-Stars (EmbedIO) | yes |
| 4782 | PINS Kestrel (SignalR) | **yes — see [§5](#5-firewall)** |
| 7624 | indiserver, spawned by PINS | no, localhost only |
| 7625 | test harness | `test-indi-sim.sh` only |

### 10.5 Paths

| Path | Contents |
|---|---|
| `~/pins/run/` | the application |
| `~/pins/build/` | scratch, deletable |
| `~/pins/build/pins/x64-port/` | **the scripts, after installation** |
| `~/.local/share/NINA/Profiles/<guid>.profile` | settings |
| `~/.local/share/NINA/Logs/` | logs |
| `~/.local/share/NINA/Plugins/3.0.0/` | plugins — note **`3.0.0`**, and `Touch N Stars` with spaces |
| `/tmp/indiFIFO` | PINS's indiserver control FIFO |
| `/tmp/pins.log` | current run's log, from `start-pins.sh` |

### 10.6 Useful API calls

`$H` is your host IP. **Read-only unless marked:**

```bash
curl -s "http://$H:1888/v2/api/version"
curl -s "http://$H:1888/v2/api/equipment/camera/info"
curl -s "http://$H:1888/v2/api/equipment/mount/info"
curl -s "http://$H:1888/v2/api/profile/show?active=true"
```

> **These move real hardware.** Never fire them to "check" something — there is
> a telescope on the other end:
>
> ```
> /v2/api/equipment/mount/slew        moves the mount
> /v2/api/equipment/mount/park        moves the mount
> /v2/api/framing/slew                moves the mount
> /v2/api/equipment/focuser/move      moves the focuser
> ```

Capture is two-step — start, then fetch:

```bash
curl -s "http://$H:1888/v2/api/equipment/camera/capture?duration=2"
sleep 3
curl -s "http://$H:1888/v2/api/equipment/camera/capture?getResult=true"
```

Firing a second capture while one is running returns *"Capture already in
progress"* — the request is not queued.

> **An HTTP 200 with a plausible byte count does not mean a real image.** A
> blank-white frame is a documented failure mode of the framing cache. Check
> pixel statistics, not the status code — see [`PLUGINS.md`](PLUGINS.md).

---

## 11. Troubleshooting

### 11.1 The web UI does not load

Check in this order:

```bash
systemctl --user is-active pins          # or: pgrep -a NINA
ss -tlnp | grep -E ':(1888|5000|4782)'   # all three must be listening
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:5000/   # expect 200
```

A local 200 but nothing from another machine means the firewall
([§5](#5-firewall)). **After a reboot, give it ~30 seconds**: the service starts
about 9 s in, and the three servers take another 20 s to come up.

### 11.2 The UI loads but the wizard silently restarts

Port 4782 is blocked. See [§5](#5-firewall).

### 11.3 The UI hangs after every exposure

You built upstream instead of this fork — the OpenCvSharp bump is missing.

```bash
grep 'OpenCvSharp4"' ~/pins/build/pins/NINA/NINA.csproj   # want 4.13.0.20260627
```

Fix: `rm -rf ~/pins/build/pins`, then re-run the `pins` stage.

### 11.4 Settings revert after restart

The shutdown was not graceful. Always `stop-pins.sh`, never `pkill -9`. See
[§6](#6-first-run).

### 11.5 The camera is not listed

```bash
lsusb | grep -i touptek                          # is it there at all?
grep -i toupcam /tmp/pins.log | grep -i error    # did the SDK load?
```

If the id changed after a replug, re-select the camera ([§4.2](#42-the-camera)).

### 11.6 The mount will not connect

```bash
ls -l /dev/ttyUSB0
lsmod | grep ftdi_sio
```

A missing module after a kernel upgrade without reboot — see
[§1.3](#13-update-the-system-first-and-reboot).

### 11.7 Two `indiserver` binaries

A from-source INDI in `/usr/local/bin` alongside the distro one in `/usr/bin`.
Whichever comes first on `PATH` wins, and it may not be the one whose drivers
you built.

```bash
which -a indiserver
```

Remove the one you do not want, or fix `PATH`.

### 11.8 A plugin is missing

**The `plugins` stage does not fail when a plugin fails to build** — it warns
and continues, so a partial deploy looks like success.

```bash
ls ~/.local/share/NINA/Plugins/3.0.0/                 # expect 6 entries
grep -c 'Successfully loaded plugin' /tmp/pins.log    # expect 6
```

The six: Advanced API, Touch N Stars, Three Point Polar Alignment, Livestack,
Phd2 Tools, Hocus Focus.

### 11.9 The `external` stage produced tiny files

Files of ~133 bytes in `~/pins/run/External/` are Git LFS *pointers*, not the
real blobs — `git-lfs` was missing or failed.

```bash
find ~/pins/run/External -size -1k -name '*.so'   # expect nothing
```

Install `git-lfs`, `rm -rf ~/pins/build/pins.external`, and re-run the
`external` stage.

### 11.10 `libgdk-x11-2.0.so.0: cannot open shared object file`

You ran `/opt/astap/astap`, the GUI build. Use `astap_cli`
([§7.4](#74-plate-solver)).

### 11.11 A globalization exception at startup

`icu` is missing. It is in the `deps` list, so this only happens if packages
were installed by hand. `sudo pacman -S --needed icu`.
