# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Scope: the `x64-port/` Linux port effort. The solution-wide map is
[`../AGENTS.md`](../AGENTS.md); do not duplicate it here. Read
[`README.md`](README.md) first for what the port is, then this file for how to
work on it.

## The two machines

This work spans two hosts, and confusing them wastes time.

| Host | Role | PINS source | Notes |
|---|---|---|---|
| **adam** | WSL2 dev workstation | `~/pins` (this repo) | builds, edits, commits. No telescope. |
| **quark** | Chuwi Minibook X N150, the observatory box | `~/pins-build/pins` | runs PINS with **mount and camera attached**. Clone+pull only, never edited. |

`ssh quark` works (also `stefano@192.168.1.36`). Quark's checkout is usually
several commits behind adam; it is a deployment target, not a worktree. Check
`git log --oneline -1` on both before assuming they match.

**Anything that must be verified against real hardware or a running PINS has to
run on quark.** Building and reading code happens on adam.

## Build and test (adam)

The SDK is at `~/.dotnet` and is not on `PATH` by default. Everything targets
`net10.0` / `linux-x64`.

```bash
~/.dotnet/dotnet build System.Windows.Compat/System.Windows.Compat.csproj -c Release
~/.dotnet/dotnet build NINA/NINA.csproj -c Release -r linux-x64
~/.dotnet/dotnet build NINA.Test/NINA.Test.csproj -c Release -r linux-x64

# whole suite, then a single fixture
~/.dotnet/dotnet test NINA.Test/NINA.Test.csproj -c Release --no-build -r linux-x64
~/.dotnet/dotnet test NINA.Test/NINA.Test.csproj -c Release --no-build -r linux-x64 \
    --filter "FullyQualifiedName~AstrometryTest"
```

**Expect ~60 astrometry failures on a fresh clone**, all `DllNotFoundException`
for SOFA/NOVAS. That is a missing `NINA/External/linux-x64/`, not broken code —
build it with `./build-external-x64.sh`. Establish the baseline before blaming
a change for a failing test.

The installer is staged; re-run one stage rather than the lot:

```bash
./setup-pins-x64.sh <stage>   # deps indi pins plugins astap external verify
```

## Verifying against the running instance (quark)

PINS serves two ports: **1888** = `ninaAPI` (`/v2/api/...`), **5000** =
Touch-N-Stars (its own `/api/...` plus the Vue app). They are different servers
with different route namespaces — a 404 on one says nothing about the other.

```bash
ssh quark 'curl -s http://localhost:1888/v2/api/equipment/mount/info'
ssh quark 'curl -s http://localhost:1888/v2/api/profile/show?active=true'
```

Read-only endpoints are safe. **`/framing/slew` and anything under
`/equipment/mount/` move real hardware — never fire those to "check" something.**

Profile settings are writable over the API and persist. Record the original
value before changing one, and revert when done:

```
/v2/api/profile/change-value?settingpath=<Section>-<Key>&newValue=<v>
```

## Hard-won rules

Each of these cost real time. They are documented at length in `PLUGINS.md`
and `BUILD-NOTES.md`; this is the index.

- **Verify images by pixel statistics, not HTTP status or byte count.** A blank
  white JPEG is a valid 200 with a plausible size.
  `convert img.jpg -format "%[fx:mean] %[fx:standard_deviation]" info:` —
  `mean=1 sd=0` is pure white, i.e. a silent failure.
- **Check the Vue frontend before declaring a capability missing.**
  Touch-N-Stars is a full app, not a thin view over `ninaAPI`; it carries logic
  and calls external services the API knows nothing about. The bundle is served,
  not vendored: `curl :5000/js/app.<hash>.js` and grep it.
- **Ask whether INDI already provides the capability** before assessing any
  equipment plugin. A plugin reaching hardware via ASCOM
  (`SendCommandString`) cannot work here at all — `NINA.INDI` implements no
  `SendCommand*`. `check-plugin.sh` now tests this first.
- **Sequencer-only plugins are useless here.** Instructions execute, but
  Touch-N-Stars has no sequence *editor*, so nothing can author a sequence that
  uses them. Orbuculum and Orbitals were both ported, then dropped for this.
- **A test project's target framework says nothing about the plugin's.** Read
  `Foo.csproj`, never `Foo.Test.csproj`.
- **Uncommitted porting work does not survive a crashed session.** The Orbitals
  port and a `System.Windows.Compat` fix were lost this way. Commit a shim fix
  as its own commit, independent of the plugin that motivated it.

## Assessing a plugin

```bash
./check-plugin.sh --list                     # every submodule and its targets
./check-plugin.sh path/to/plugin.csproj      # inspect, then build if it can
```

It reports transport blockers, export shape, XAML weight and Windows-only
packages, then prints a ready-made `EXTRA_PLUGINS` line. Note it **builds and
deploys** as a side effect — remove the plugin folder from
`~/.local/share/NINA/Plugins/3.0.0/` afterwards if you were only checking.

Six plugins are deployed. Keep these in sync when that changes: the spec list in
`stage_plugins`, the count in `INSTALL.md`, and the `**deployed**` markers in
`PLUGINS.md`.

## Documentation conventions

- `BUILD-NOTES.md` is an **append-only dated log**. Record a reversal as a new
  dated entry; never rewrite an earlier one to match present reality.
- `PLUGINS.md` holds the rules and the plugin catalogue, `INSTALL.md` the
  install/runtime reference, `README.md` the orientation.
- Claims here should be measured, not inferred. If something was not tested,
  say so rather than implying it works.
