# PINS on x86-64 Linux

Tooling and documentation for running **PI 'N' Stars** — the headless Linux
fork of N.I.N.A. — on x86-64 hardware: a mini PC at the telescope, a laptop, or
any Arch- or Debian-family machine.

Verified end to end on **CachyOS** (rolling Arch, kernel 7.2.2, GCC 16.2.1,
.NET 10.0.302) with a **ToupTek ATR2600C** camera and a **SkyWatcher HEQ5 Pro**
mount on an EQDIR cable.

---

## What this is

Upstream PINS targets `linux-arm64` for Raspberry Pi. This directory is what it
took to run it on x86-64: an installer that goes from a bare machine to a
working rig in one command, scripts to operate it, and the record of every
problem found along the way.

**The port required exactly one source change** — an OpenCvSharp version bump.
Everything else here is tooling and packaging.

## Start here

| Document | For |
|---|---|
| **[INSTALL.md](INSTALL.md)** | installing on a new machine, configuring it, and fixing it when it breaks |
| **[PLUGINS.md](PLUGINS.md)** | which plugins work, why most cannot, and how to assess one |
| **[BUILD-NOTES.md](BUILD-NOTES.md)** | why every decision here is what it is — the evidence log |

New machine? Go to [INSTALL.md](INSTALL.md).

## The scripts

| Script | Purpose |
|---|---|
| `setup-pins-x64.sh` | the installer. Seven stages, each runnable alone |
| `start-pins.sh` | start cleanly, wait for all three ports, report the URLs |
| `stop-pins.sh` | stop gracefully so the profile is saved |
| `check-plugin.sh` | will this plugin work on Linux? Answer before porting it |
| `test-indi-sim.sh` | exercise INDI on its own, before involving PINS |
| `build-external-x64.sh` | build SOFA and NOVAS from source — fallback if `pins.external` is unavailable |
| `pins.service` | systemd user unit, so the rig comes up on boot |

Every script takes `--help`.

## Quick start

```bash
# 1. get the installer -- one file, 45 KB. No clone, no SSH key.
curl -fsSLO https://raw.githubusercontent.com/szaghi/pins/linux-x64/x64-port/setup-pins-x64.sh
chmod +x setup-pins-x64.sh

# 2. build everything. Defaults to this fork (szaghi/pins, branch linux-x64);
#    tee so you can check afterwards what it actually built.
./setup-pins-x64.sh all 2>&1 | tee ~/pins-install.log

# 3. open the firewall -- all three ports, or none of it works.
#    /16 rather than /24 so it still works on a phone hotspot in the field.
sudo ufw allow from 192.168.0.0/16 to any port 1888,5000,4782 proto tcp

# 4. run it. The scripts now live in the build tree.
~/pins/build/pins/x64-port/start-pins.sh
```

Then open `http://<host>:5000`.

Full detail, including profile setup and equipment, in
[INSTALL.md](INSTALL.md).

## How it fits together

PINS is **three servers plus a spawned INDI daemon**, which is the single most
useful thing to know when something misbehaves:

| Port | Server | Serves |
|---|---|---|
| 1888 | ninaAPI (EmbedIO) | the REST API, `/v2/api/...` |
| 5000 | Touch-N-Stars (EmbedIO) | the web UI you actually use |
| 4782 | PINS Kestrel | SignalR — notifications, progress, dialogs |
| 7624 | indiserver | spawned by PINS, which `pkill -9`s any other |

Block only 4782 and the UI loads, the setup wizard reaches its GPS step, then
silently returns to the start with nothing in the log. That one cost an hour.

Equipment reaches PINS by two independent routes:

- **Native SDK** — a vendor `.so` from `External/linux-x64/` loaded in-process.
  This is the camera path in use.
- **INDI** — `indiserver` on 7624 with per-device drivers, spoken over TCP.
  This is the mount path, and an alternative camera path.

## Traps worth knowing before you hit them

Each of these cost real time. All are documented with fixes in the guides.

- **A kernel upgrade without a reboot** deletes the running kernel's module
  tree, so *no* module can load — including `ftdi_sio`, which your mount needs.
  Everything already loaded keeps working, so the machine looks fine until you
  plug something in.
- **`pkill -9 NINA` discards your settings.** The profile is written only on a
  graceful shutdown. Use `stop-pins.sh`.
- **The installer defaults to upstream**, not your fork. Pass `--pins-repo` and
  `--pins-branch`, and read the line where the `pins` stage prints what it is
  actually building.
- **The ToupTek device id encodes the USB bus path**, so any replug changes it.
  Connecting to the old id fails with a message that reads like broken
  hardware.
- **Site coordinates are decimal degrees.** `41°44'16.9"` is `41.7380`, not
  `414416.9`, and the mount keeps its own copy that only updates on reconnect.
- **Most NINA plugins cannot work here** — see [PLUGINS.md](PLUGINS.md).

## Status

| | |
|---|---|
| Build, INDI, plugins, web UI | working |
| Camera: enumerate, cool, expose, display | working |
| Mount: HEQ5 Pro over EQDIR | working |
| Camera and mount together | working |
| ASTAP plate solver + D80 database | installed, **not yet tested against sky** |
| TPPA polar alignment | plugin loaded, **not yet run under sky** |

The two untested items need stars, not software.
