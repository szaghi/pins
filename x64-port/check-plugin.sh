#!/usr/bin/env bash
# Will this NINA plugin work on Linux? Answer before investing in a port.
#
# Adding a plugin to the fork gains nothing by itself. The plugins that run
# were MODIFIED: a net10.0 target added, NuGet PackageReferences to NINA.*
# swapped for ProjectReferences to the in-tree projects, and whatever
# Windows-only code that exposed fixed. This script measures how much of that
# is already done and how much is left.
#
# Usage:
#   check-plugin.sh <path-to.csproj>      inspect, and build if it can
#   check-plugin.sh --list                every plugin submodule in the fork
#
# Exit: 0 buildable now, 1 needs work, 2 bad usage.

set -uo pipefail

PINS_SRC="${PINS_SRC:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
DOTNET_ROOT="${DOTNET_ROOT:-$HOME/.dotnet}"

log()  { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '\033[1;33m   WARN %s\033[0m\n' "$*"; }
bad()  { printf '\033[1;31m   NO   %s\033[0m\n' "$*"; }
good() { printf '\033[1;32m   OK   %s\033[0m\n' "$*"; }

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    sed -n '2,14p' "$0" | sed 's/^# \?//'
    echo
    echo "Options:"
    echo "  -l, --list     list every plugin submodule in the fork and its targets"
    echo "  -h, --help     this text"
    echo
    echo "Read the 'exports' line first: a plugin whose only functional export"
    echo "is IDockableVM will load but be unreachable on a headless PINS."
    echo "See PLUGINS.md."
    exit 0
fi

if [[ "${1:-}" == "--list" || "${1:-}" == "-l" ]]; then
    log "Plugin submodules in the fork"
    for d in "$PINS_SRC"/NINA.Plugins/*/; do
        n=$(basename "$d")
        # Skip test projects: their target framework says nothing about the
        # plugin's. Reading Orbuculum.Test.csproj instead of Orbuculum.csproj
        # is what made that plugin look Windows-only when it is not.
        while read -r c; do
            [[ -n "$c" ]] || continue
            tf=$(grep -oE '<TargetFramework[s]*>[^<]*' "$c" | head -1 | sed 's/.*>//')
            if [[ "$tf" =~ (^|;)net10\.0(;|$) ]]; then mark="linux-capable"
            else mark="WINDOWS ONLY"; fi
            printf "   %-30s %-30s %s\n" "$n" "$tf" "$mark"
        done < <(find "$d" -maxdepth 4 -name '*.csproj' 2>/dev/null | grep -viE '[Tt]est')
    done
    exit 0
fi

CSPROJ="${1:-}"
[[ -n "$CSPROJ" ]] || { sed -n '2,14p' "$0" | sed 's/^# \?//'; exit 2; }
[[ -f "$CSPROJ" ]] || { bad "no such csproj: $CSPROJ"; exit 2; }
# Absolute, so the EXTRA_PLUGINS line printed at the end is repo-relative
# regardless of where the caller ran this from.
CSPROJ=$(readlink -f "$CSPROJ")

log "Checking $(basename "$CSPROJ")"

verdict=0

# -- 1. target framework ------------------------------------------------------
tf=$(grep -oE '<TargetFramework[s]*>[^<]*' "$CSPROJ" | head -1 | sed 's/.*>//')
info "target frameworks: ${tf:-<none found>}"
if [[ "$tf" =~ (^|;)net10\.0(;|$) ]]; then
    good "has a plain net10.0 target"
else
    bad "no plain net10.0 target — add one to <TargetFrameworks>"
    warn "a *-windows target alone pulls in WPF and cannot build here"
    verdict=1
fi

# -- 2. how does it reference NINA? -------------------------------------------
# The Windows build resolves NINA.* from NuGet; the Linux build must use
# ProjectReference to the in-tree projects, or it links against Windows
# assemblies that do not exist here.
nprj=$(grep -c 'ProjectReference' "$CSPROJ" 2>/dev/null || true)
npkg=$(grep -cE 'PackageReference[^>]*Include="NINA\.' "$CSPROJ" 2>/dev/null || true)
info "ProjectReferences: ${nprj:-0}   NINA NuGet PackageReferences: ${npkg:-0}"
if (( ${nprj:-0} > 0 )); then
    good "references in-tree projects"
elif (( ${npkg:-0} > 0 )); then
    warn "references NINA from NuGet only — the net10.0 target needs"
    warn "ProjectReferences to ../../NINA.Core etc. instead"
    verdict=1
fi

# -- 3. Windows-only dependencies ---------------------------------------------
# A conditional reference is fine: several plugins already exclude their WPF
# package on Linux with an IsOSPlatform condition.
blockers=$(grep -oE 'Include="(ScottPlot\.WPF|System\.Windows[^"]*|Microsoft\.Windows[^"]*|WindowsAPICodePack[^"]*)"' \
           "$CSPROJ" 2>/dev/null | sort -u | sed 's/Include="//;s/"//' || true)
if [[ -n "$blockers" ]]; then
    if grep -q 'IsOSPlatform' "$CSPROJ"; then
        good "Windows packages present but conditioned on platform"
        info "$(echo "$blockers" | tr '\n' ' ')"
    else
        warn "unconditional Windows packages: $(echo "$blockers" | tr '\n' ' ')"
        verdict=1
    fi
fi

# -- 4. XAML surface ----------------------------------------------------------
# A dockable window or options page is real WPF work. Sequencer instructions
# and background services usually are not.
dir=$(dirname "$CSPROJ")
xaml=$(find "$dir" -name '*.xaml' 2>/dev/null | wc -l)
if (( xaml > 0 )); then
    warn "$xaml XAML file(s): the plugin has WPF UI"
    warn "it may still load headless if the UI is never instantiated, but"
    warn "any dockable view will not appear in Touch-N-Stars"
else
    good "no XAML — pure logic, the easy case"
fi

# -- 5. is it reachable at all? -----------------------------------------------
# The decisive question, and the one a build cannot answer. PINS is headless:
# the WPF shell never runs, so a plugin whose only export is IDockableVM loads
# successfully and is then unreachable -- Touch-N-Stars cannot render a WPF
# dockable, and there is no API to drive it.
#
# A plugin is useful here if it does at least one of:
#   ISequenceItem / SequenceItem  -- sequencer instructions, driven by the API
#   IDockableVM + a Vue counterpart in Touch-N-Stars (TPPA works this way)
#   hooks into a NINA subsystem that runs regardless of UI (Hocus Focus does
#     star detection and autofocus, which the imaging path calls anyway)
exports=$(grep -rhoE 'Export\(typeof\([A-Za-z]+' "$dir" --include=*.cs 2>/dev/null \
          | sed 's/.*(//' | sort -u | tr '\n' ' ')
seqitems=$(grep -rlE 'ISequenceItem|: *SequenceItem|SequenceContainer' "$dir" \
           --include=*.cs 2>/dev/null | wc -l)
info "exports: ${exports:-none found}"
info "sequencer-item files: $seqitems"

if (( seqitems > 0 )); then
    good "has sequencer instructions — drivable through the API"
elif [[ "$exports" == *"IDockableVM"* ]]; then
    warn "the only functional export is IDockableVM: a WPF dockable panel"
    warn "it will LOAD but be unreachable — Touch-N-Stars cannot render it,"
    warn "and there is no API surface to drive it. Porting the build gets you"
    warn "a plugin that does nothing visible."
    warn "Useful only if you also write a Touch-N-Stars view for it."
    verdict=1
elif [[ -z "$exports" ]]; then
    warn "no MEF exports found — check how this plugin is meant to hook in"
fi

# -- 6. try it ----------------------------------------------------------------
if (( verdict == 0 )); then
    [[ -x "$DOTNET_ROOT/dotnet" ]] && export PATH="$DOTNET_ROOT:$PATH"
    export DOTNET_CLI_TELEMETRY_OPTOUT=1
    if command -v dotnet >/dev/null; then
        log "Building for net10.0 linux-x64"
        out=$(dotnet build "$CSPROJ" -c Release -f net10.0 -r linux-x64 2>&1)
        errs=$(grep -cE ': error ' <<<"$out" || true)
        if (( ${errs:-0} == 0 )); then
            good "builds with 0 errors"
            title=$(grep -oE '<(AssemblyTitle|Title)>[^<]*' "$CSPROJ" | head -1 | sed 's/.*>//')
            [[ -z "$title" ]] && title=$(grep -ohE 'AssemblyTitle\("[^"]*' \
                "$dir/Properties/AssemblyInfo.cs" 2>/dev/null | head -1 | sed 's/.*("//')
            echo
            info "The display name is what names the plugin folder. To try it:"
            echo
            echo "      EXTRA_PLUGINS=\"${title:-<AssemblyTitle>}:${CSPROJ#"$PINS_SRC"/}\" \\"
            echo "          ./setup-pins-x64.sh plugins"
            echo
            info "If it proves useful, add that same string to the for-spec list"
            info "in stage_plugins so every machine builds it."
        else
            bad "$errs build error(s):"
            grep -E ': error ' <<<"$out" | head -8 | sed 's/^/        /'
            verdict=1
        fi
    else
        warn "dotnet not found; skipping the build check"
    fi
fi

log "Verdict"
case $verdict in
    0) good "buildable now" ;;
    1) warn "needs porting work — see the points above" ;;
esac
exit $verdict
