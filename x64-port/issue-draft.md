Hi,

first of all, thank you for PINS. Getting NINA to run headless on Linux is a serious piece of work, and the `System.Windows.Compat` shim plus the INDI layer solve problems that most people would have called impossible.

I am trying to target an x86 build for a mini PC, working through it with Claude AI as an assistant. That turned up a broken download, and one finding that might interest you.

## 1. The `NINA/External` bundle URL returns 503

`.github/workflows/build-pins-package.yml` populates `NINA/External` from:

```
http://cloud.astro-narren.de/public.php/dav/files/7tEAZoEpCMCYyeX/?accept=zip
```

I tried twice on 2026-08-26, several hours apart:

| URL | Result |
|---|---|
| `https://cloud.astro-narren.de/` | `HTTP 200` |
| `https://cloud.astro-narren.de/public.php/dav/files/7tEAZoEpCMCYyeX/?accept=zip` | `HTTP 503` |
| `https://cloud.astro-narren.de/s/7tEAZoEpCMCYyeX` | `HTTP 404` |

The host answers on the root, so the share link itself looks revoked or expired rather than the server being down. The `curl --fail --retry 3` step in the workflow fails on it.

This may also explain the CI: every **Build and Test** run I can see has failed since 2026-07-28.

For anyone who finds this issue later, the Bitbucket submodule `Isbeorn/nina.external` does not substitute for it. Its `x64/` and `x86/` trees hold Windows PE32+ DLLs (`toupcam.dll`, `qhyccd.dll`, and so on), with no `.so` files and no Linux branch. It only tells you which vendor SDKs are expected.

Could you republish the bundle, or move it somewhere more durable? A GitHub release asset or an LFS-backed repo would survive link rot and let forks build without depending on a single share URL. I am happy to help with the packaging if that is useful.

## 2. A side finding: `linux-x64` builds without changes

I mention this only in case an x86-64 target interests you. I was porting PINS to an Intel N100 mini PC and expected to spend a weekend on it. There was nothing to do.

From baseline `75e49f03ee1a90f7d24e888dbc520619cca4ae04` (`develop`, 2026-08-05) on Ubuntu 24.04 with .NET SDK 10.0.302:

```bash
dotnet build   System.Windows.Compat/System.Windows.Compat.csproj -c Release
dotnet restore NINA/NINA.csproj -r linux-x64
dotnet build   NINA/NINA.csproj -c Release -r linux-x64 --no-restore
dotnet publish NINA/NINA.csproj -c Release -r linux-x64 --no-build -o out
```

Result:

```
System.Windows.Compat:  0 Error(s),  71 Warning(s)
NINA linux-x64:         0 Error(s), 426 Warning(s)
publish payload:        236 MB self-contained
file out/NINA  ->  ELF 64-bit LSB pie executable, x86-64
./out/NINA --help  ->  NINA 3.3.0.1053-nightly
```

No source edits at all. You had already covered it: `NINA/NINA.csproj:15` falls back to `linux-x64` whenever `OSArchitecture` is not `Arm64`.

```xml
<RuntimeIdentifier Condition="'$(RuntimeIdentifier)'=='' and $(...OSArchitecture...Contains('Arm64'))">linux-arm64</RuntimeIdentifier>
<RuntimeIdentifier Condition="'$(RuntimeIdentifier)'==''">linux-x64</RuntimeIdentifier>
```

`DllLoader` resolves `External/linux-{ProcessArchitecture}/…` at runtime, so it points at `External/linux-x64/` on x86-64 by itself. The published `System.Windows.dll` even came out byte-identical to the compat shim, so the workflow's explicit swap step was a no-op in my run.

The only architecture-specific parts I found are the env vars in `build-pins-package.yml`: `TARGET_RUNTIME`, `DEB_ARCH`, `PACKAGE_NAME`. I also grepped for Pi-specific hardware access (`vcgencmd`, `/boot/config.txt`, `libgpiod`, `System.Device.Gpio`, `/sys/class/gpio`) and found two source comments, nothing else.

Would you accept a PR adding a `linux-x64` leg to the packaging workflow? From what I can see it means parameterizing the env vars you already have, not writing a second workflow. I would rather wait until the `External` question is settled, since an x64 build needs an `External/linux-x64/` set. For INDI-attached gear it may not need one at all: `NINA.INDI` contains no `DllLoader` or `External` references, so it reaches hardware through `indiserver` instead of the bundled vendor SDKs.

## Environment

- Ubuntu 24.04.4 LTS, x86-64
- .NET SDK 10.0.302 (as pinned in `global.json`)
- Baseline: `75e49f03ee1a90f7d24e888dbc520619cca4ae04`

Thanks again for the project, and for whatever time you can spare on the bundle.
