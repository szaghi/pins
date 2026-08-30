# Plugins on PINS

What works, what cannot, and how to tell the difference before you spend a day
on it.

## The short version

**Seven plugins run.** They are built from source by the installer's `plugins`
stage and deployed to `~/.local/share/NINA/Plugins/3.0.0/`.

| Plugin | Folder | What it does |
|---|---|---|
| Advanced API (ninaAPI) | `Advanced API` | the REST API on port 1888 — without it there is no UI at all |
| Touch 'N' Stars | `Touch N Stars` | the web UI on port 5000, plus its Vue app |
| Three Point Polar Alignment | `Three Point Polar Alignment` | TPPA — polar alignment |
| Hocus Focus | `Hocus Focus` | star detection, autofocus, aberration inspector for backfocus and tilt |
| Livestack | `Livestack` | live stacking |
| Phd2 Tools | `Phd2 Tools` | PHD2 guiding helpers |
| Orbuculum | `Orbuculum` | sequencer instructions for multi-target planning |

**The other 89 in the official repository do not, and mostly cannot.**

## Why repository plugins cannot be installed

PINS keeps the whole plugin-install machinery — `InstallPluginCommand`,
`PluginFetcher`, the official repository. It genuinely fetches them:

```
PluginFetcher.cs|RequestAll|57|Found 94 valid plugins at
  https://nighttime-imaging.eu/wp-json/nina/v1/plugins/manifests
```

They download. They will not run, for two compounding reasons.

**1. They are Windows builds.** The manifests carry no platform information at
all — `Author`, `Version`, `Installer`, `MinimumApplicationVersion`, and no
`TargetFramework` or `Platform` field. `PluginLoader` checks only *version*
compatibility (`PluginLoader.cs:370`), never the framework. Published archives
are `net8.0-windows`, pulling in WPF and Win32, so a downloaded plugin fails to
load or throws on its first Windows call with nothing warning you first.

**2. Most are dockable-view plugins.** This is the deeper problem, and it
survives any amount of porting.

## The rule that decides everything

> **PINS is headless. The WPF shell never runs.** A plugin whose only export is
> `IDockableVM` will load successfully and then be **unreachable** — Touch-N-Stars
> cannot render a WPF dockable, and there is no API to drive it.

So a plugin is useful here only if it does at least one of:

| Export | Why it works |
|---|---|
| `ISequenceItem`, `ISequenceCondition`, `ISequenceContainer` | sequencer instructions, drivable through the API |
| `IPluggableBehavior` | replaces a NINA subsystem that runs regardless of UI — Hocus Focus does star detection this way |
| `IDockableVM` **plus a Vue counterpart** in Touch-N-Stars | how TPPA works: the plugin computes, the Vue app displays |

Two worked examples, both of which fail:

- **Horizon Creator** — sole export `IDockableVM`, no sequencer items. Its whole
  purpose is slewing the mount interactively to record horizon points. Port it
  and you get a plugin that loads and does nothing visible.
- **GuidingAnalyzer** — same shape. Its *analysis* lives in plain service
  classes that read PHD2 logs and need no NINA at all, so the sensible route is
  to run it on Windows against copied logs, or build those services into a
  standalone tool.

## Assessing a plugin: `check-plugin.sh`

```bash
cd ~/pins-tooling/x64-port
./check-plugin.sh --list                    # every submodule in the fork
./check-plugin.sh path/to/Plugin.csproj     # assess one, and build it if it can
```

For a plugin outside the fork, clone it first:

```bash
git clone --depth 1 https://github.com/author/ThePlugin.git /tmp/probe
./check-plugin.sh /tmp/probe/ThePlugin.csproj
```

It reports five things:

| Check | What a failure means |
|---|---|
| plain `net10.0` target | a `*-windows` target alone pulls in WPF and cannot build here |
| ProjectReference vs NuGet | the Linux build must reference the in-tree NINA projects, not NuGet packages |
| unconditional Windows packages | fine when guarded by `IsOSPlatform`, fatal otherwise |
| XAML file count | a hint; the exports line below is the real test |
| **exports** | **the decisive one** — see the rule above |

**Read the exports line first.** It disqualifies faster than anything else:

```
exports: IDockableVM IPluginManifest ResourceDictionary
sequencer-item files: 0
WARN the only functional export is IDockableVM: a WPF dockable panel
WARN it will LOAD but be unreachable
```

versus one worth pursuing:

```
exports: IPluginManifest ISequenceCondition ISequenceContainer ISequenceItem
sequencer-item files: 7
OK   has sequencer instructions — drivable through the API
```

## Porting one

If the exports check passes, the rest is mechanical:

1. **Fork** the plugin to your account.
2. **Add `net10.0`** to its `<TargetFrameworks>`.
3. **Swap NuGet for projects** — replace `PackageReference Include="NINA.*"`
   with `ProjectReference` to `../../NINA.Core` and friends. ninaAPI has 20 of
   these; a small plugin needs three or four.
4. **Condition or remove Windows packages**, e.g.
   `Condition="!$([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(...Linux))"`.
   Hocus Focus already does this for `ScottPlot.WPF`.
5. **Build and fix** whatever surfaces. Re-run `check-plugin.sh` until clean.

Effort varies enormously. A sequencer-instruction plugin may be an afternoon;
anything with real WPF behaviour can be impractical.

## Trying one without editing the installer

`check-plugin.sh` prints this line on success:

```bash
EXTRA_PLUGINS="Display Name:path/to/Plugin.csproj" ./setup-pins-x64.sh plugins
```

The **display name must be the plugin's `AssemblyTitle`**, not its project or
assembly name — that is the folder the running assembly resolves its own
resources from, and the folder the official repository would install into.

Once a plugin earns its place, move that same string into the `for spec in`
list in `stage_plugins`, so every machine builds it.

## Why vendoring them all would not help

Adding the other 89 as submodules gains nothing. The seven that run were
**modified**: `net10.0` targets added, NINA references switched from NuGet to
in-tree projects, Windows-only code fixed. An unported submodule is tens of
megabytes of clone that fails to compile the moment it is wired up — and
`stage_pins` already spends most of its 15–30 minutes cloning submodules.

## In the fork but not deployed

| Submodule | Targets | Status |
|---|---|---|
| `NINA.Joko.Plugin.TenMicron` | `net8.0-windows7.0` | Windows-only, cannot build |

Everything else in `NINA.Plugins/` is deployed.

When checking a submodule by hand, **skip anything matching `*test*`**: a test
project's target framework says nothing about the plugin's. Reading
`Orbuculum.Test.csproj` (net7.0-windows) instead of `Orbuculum.csproj`
(net10.0-windows;net10.0) is what made that plugin look unbuildable when it is
not. `check-plugin.sh --list` filters them out.

## The full repository

96 unique plugins, from 364 manifest entries across versions, fetched from
`https://nighttime-imaging.eu/wp-json/nina/v1/plugins/manifests`.

Blank status means a Windows build not present in the fork — assess it with
`check-plugin.sh` before assuming it can be ported.

| Plugin | Author | Status | Description |
|---|---|---|---|
| 10 Micron Tools | George Hilios (jokogeo) | in fork, Windows-only | 10 Micron Mount Tools, including model building |
| 2-Point Polar Alignment | Nir Zonshine |  | Fast polar alignment using home position and a 90° RA rotation |
| Add To CPWI Alignment Model | ADPUK |  | Creates or adds to a CPWI alignment model |
| Advanced API | Christian Palm | **deployed** | An experimental API for N.I.N.A. |
| AI Assistant | Michele Bergo |  | Multi-provider AI assistant with MCP equipment control for intelligent astrophotography automation |
| AI Weather | Michele Bergo |  | AI-powered all-sky camera weather monitoring with automatic safety protection |
| Alpaca | Stefan Berg @isbeorn |  | A plugin to host all N.I.N.A. devices as Alpaca Devices to be accessed from other applications |
| ASA Tools | Gerald Hitz (photon) |  | ASA model building |
| ASG Electronically Assisted Tilt | ASG Astronomy |  | Controls the ASG Astronomy electronically assisted tilt device for precise sensor tilt correction. |
| Astro HTTP API | Shrivu Shankar (sshh12) |  | A general purpose HTTP API for NINA designed for use with astroapp.io |
| Astro PM | Astro PM |  | Connect your Astro PM cloud projects to NINA and run a fully automated, multi-night imaging schedule. |
| Astro-Physics Tools | Dale Ghent |  | A collection of useful Advanced Sequencer utilities for users of Astro-Physics mounts and APCC Pro |
| AstroColibri | Christoph Nieswand |  | Integration of AstroColibri Events |
| AstroManager | Michael Sleeman |  | Use AstroManager with NINA Advanced Sequencer. Documentation: https://docs.astro.sleeman.at |
| Astromechanics Aperture Control | Dale Ghent |  | Controls the focal ratio of a Canon lens when using an Astromechanics Canon Lens Controller and a custom ASCOM driver |
| Astrovault | AstrosphereHub |  | Automatically uploads captured astrophotography images to Astrovault cloud storage |
| Autofocus Report Analysis | Stefan Berg @isbeorn |  | Analyse temperature slope of autofocus runs from the autofocus logs |
| BahtiFocus | CanardConfit |  | BahtiFocus is a precision Bahtinov mask analyzer integrated into N.I.N.A., designed to help astronomers achieve perfect  |
| Benchmark | CaeloWorks |  | Benchmarks your machine by timing N.I.N.A.'s real image-analysis primitives (debayer, stretch remap, resize, blur, Canny |
| Click To Center | Alexander Wrede @astro_ale |  | A new dockable window for slewing and centering the mount on a selected point in the image. Additionally the target coor |
| Collimation Helper for SkyWave | joergsflow |  | Automated SkyWave collimation helper — circular defocused star capture & native FITS integration |
| Connector | Stefan Berg @isbeorn |  | Equipment connection on startup |
| CPU\GPU Computing for NINA | Lucas Alias |  | A NINA Plugin that move some N.I.N.A & Accord heavy functions inside native code and GPU to speed it up. |
| DeepSkyLog | Karol Bryd |  | Automatically sync your astrophotography session data with DeepSkyLog |
| Device Actions and Commands | Dale Ghent |  | Sequence instructions for accessing any available ASCOM (and perhaps other) driver actions and raw commands |
| Discord Alert | Drew McDermott |  | Sends alerts to discord |
| Discord Notification | Daniel Ludwig |  | This N.I.N.A plugin sends Discord notifications and can share images (e.g., live stacked images) from a specific folder, |
| Dither Statistics | Thierry Tschanz |  | Visualizes dithering performance |
| DynamicSequencer | Daniel He |  | Smarter automation with dynamic target selection |
| ExoPlanets | ExoPlanets |  | A plugin to help get exoplanet or variable star data. |
| Exposure Calculator | Stefan Berg @isbeorn |  | A tool to recommend an exposure time based on read noise and sky glow. |
| FasterFlats | naixx |  | Disable autostretch for flats sequences |
| Filter Offset Calculator | S. Dimant & Stefan Berg |  | Compilation of Sequencer 2 plugins; currently included: Filter Offset Calculator |
| Flat Epoch | Graham Hollis @Hologram |  | An Epoch is a chunk of time, defined as all LIGHT frames taken and saved in the Image file path. This plugin takes any n |
| Flexure Compensator | Michele Guzzini |  | A plugin that evaluates and corrects drift due to differential flexure. |
| GNS Plugin | Nick Hardy |  | A plugin for using GoodNightSystem by Lunatico |
| GRB_Helper | Ezzeddin, Halla, Insiyah,  |  | Automatically detects GRB alerts and schedules telescope capture based on observability. |
| Ground Station | Dale Ghent |  | Send failure events and free-form messages to a variety of messaging or automation services |
| GuidingAnalyzer | JPH |  | Advanced PHD2 guiding log analyzer: FFT, anomaly detection, polar alignment, statistics and recommendations. |
| Hocus Focus | George Hilios (jokogeo) | **deployed** | Improved Star Detection, Star Annotation, Auto Focus, and Tilt Correction for NINA |
| Home Assistant | CaeloWorks |  | Expose Home Assistant entities as NINA switch channels and drive/read them from advanced sequencer instructions. |
| Horizon Creator | Christian Palm |  | Create a horizon from within NINA only using your scope and mount! |
| Horizon Studio | Nir Zonshine |  | Trace local horizon profiles in daylight using live camera guides to prevent telescope slews into obstructions. |
| InfluxDB Exporter | Dale Ghent |  | Exports metrics to an InfluxDB 2.x or InfluxDB Cloud 2 instance |
| Inject Autofocus | Charles Hagen |  | Inject an autofocus routine manually into your sequence. |
| Instruction Math | Drew McDermott |  | Adds instructions which evaluate a math expression |
| Lens AF | Christian Palm |  | Run AF with your Camera Lens or change the aperture! (Canon and Nikon) |
| Lightbucket | Lightbucket |  | Send session information to the Lightbucket API |
| Livestack | Stefan Berg @isbeorn | **deployed** | Live stacking within N.I.N.A. |
| Log Viewer | Alexander Wrede @astro_ale |  | A plugin to read and filter N.I.N.A. log files. |
| LumixCamera | roberthasson |  | Control Lumix Cameras natively - nightly |
| Manual Focuser | ChungwonSEO[충탱] |  | Interactive manual focuser |
| ManualRotatorOAG | JR Schmidt |  | Manual rotator with support for an OAG with PHD2 integration |
| Moon Angle | Dale Ghent |  | Instructions that consider the angular separation between the target object and the moon |
| NEOCP Helper | Rafael Barberá |  | Download NEOCP data and automatically generate observing sequences for these objects. |
| Night Summary | Evan Pegors @sleepypuppy15 |  | Records your imaging sessions and delivers detailed HTML reports. Includes a built-in Live Dashboard, plus an optional c |
| Nikon Ekrynox SDK | Lucas Alias |  | A new Nikon SDK based on direct PTP/MTP call with Windows Portable API. |
| NINA.Luckyimaging | Nick Hardy |  | Plugin for lucky imaging |
| OnStepX Tools | Michel Moriniaux |  | Mount configuration and automated pointing model generation for OnStepX controllers |
| Orbitals | George Hilios (jokogeo) |  | Downloads publically available orbital data to target and track Comets, Asteroids, Planets, the Moon, the Sun, and other |
| Orbuculum | Stefan Berg @isbeorn | **deployed** | A plugin that will provide sequencer instructions that are able to look for future targets and react accordingly. |
| Pentax Camera and Focuser Driver | RTG |  | Focuser and Camera Driver for Pentax SDK: K-1 K-1ii KP 645Z K-3iii, KF and K-70 |
| Pentax Vintage Camera Driver | RTG |  | Camera Driver for PentaxKR PKTriggerCord: K-r, K-x, K-30, K100D, K10D, K200D, K-3, K5ii |
| Phd2 Tools | Stefan Berg @isbeorn | **deployed** | Additional capabilities for controlling the PHD2 Guiding Software via N.I.N.A. |
| PixInsight Tools | Stefan Berg @isbeorn |  | A bundle of tools to interact with PixInsight from N.I.N.A. for the purpose of live stacking |
| PlaneWave Tools | Dale Ghent |  | A collection of useful tools for managing PlaneWave telescope systems |
| PlateSolvePlus | Flashy-GER |  | Enables plate solving and optional autofocus via alternative camera and focal length |
| Point3D | Drew McDermott |  | Displays a model of how the telescope is pointing |
| Prometheus Exporter | Naveen Malik |  | Exposes a Prometheus scrape endpoint for NINA metrics |
| Python Scripting | Stefan Berg @isbeorn |  | Python Scripting within N.I.N.A. |
| Remote Copy | Tom Palmer @tcpalmer |  | Copy acquired files to another location |
| RTSP Client | Stefan Berg @isbeorn |  | A plugin that adds a new dock window to the imaging tab to show RTSP video streams |
| RTSP Timelapse Control | HiranD |  | Start/stop RTSP timelapse capture and render videos from your N.I.N.A. sequence - with session events (autofocus, flips, |
| Scope Control | Stefan Berg @isbeorn |  | Adds tool panels to the imaging tab with basic mount control as well as an altitude and azimuth chart for the telescope  |
| Sequencer+ | Carl Björk (Elveteek Sàrl) |  | Advanced Sequencer on steroids. Adds variables, expressions, conditional logic, reusable functions, safety triggers, DIY |
| Session Metadata | Tom Palmer @tcpalmer |  | Write additional metadata for an imaging session |
| SGP Server Emulation | Stefan Berg and the N.I.N. |  | A server emulation of the SGP API |
| Shutdown PC | Dale Ghent |  | A sequence instruction that gracefully shuts down N.I.N.A. or the PC |
| Sites Plugin | Francisco Moraes |  | Easily switch the latitude, longitude and elevation from a configurable list of locations. |
| SkyFlats | Gerald Hitz (@photon) |  | SQM based sky flat automation |
| Smart Filters | Benoit SAINTOT |  | SmartFilters is a plugin designed to optimize your astrophotography sessions by calculating the ideal number of exposure |
| Smart Plug Control | Crepusculum |  | Control TP-Link Kasa and Tapo smart plugs/power strips individually from NINA sequences |
| Solve Every Light | Alexander Wrede @astro_ale |  | A plugin that plate solves automatically every light frame (optionally snapshots) and writes the astrometric solution to |
| Sony Camera Plugin | Doug Henderson |  | Support for Sony Cameras (and optionally, Camera controlled lenses) |
| SpeckleInterferometry | Nick Hardy & Leon Bewersdo |  | This plugin automates the acquisition of speckle interferometry data for closely seperated objects. |
| Star Sentinel | Michele Guzzini |  | Monitors star count in saved light frames and stops the sequencer when a sustained drop indicates degrading imaging cond |
| StarMessenger | Sascha Lohaus |  | A notification plugin for N.I.N.A. which provides the user with information about the current imaging session. |
| Starting Sequence Number | Simon Kapadia |  | Plugin to enable starting a file index sequencing numbering at a specified value. |
| Subframes.io | Subframes.io |  | Captures per-exposure telemetry from your NINA imaging sessions and posts it to the Subframes.io API for analysis and tr |
| Synchronization | Stefan Berg @isbeorn |  | A plugin that introduces synchronization instructions for multi camera imaging rigs |
| Target Planning | Tom Palmer @tcpalmer |  | Help for planning future imaging sessions |
| Target Scheduler | Tom Palmer @tcpalmer |  | An automated target scheduler for NINA |
| Three Point Polar Alignment | Stefan Berg @isbeorn | **deployed** | Three Point Polar Alignment almost anywhere in the sky |
| Touch 'N' Stars | Johannes Maier, Christian  | **deployed** | A WebApp to control NINA |
| WandererBoxUltimate Plugin | Naixx |  | Native NINA driver for WandererBoxUltimate v2 |
| Web Session History Viewer | Tom Palmer @tcpalmer |  | Embedded Web server and app providing acquisition session history details |
