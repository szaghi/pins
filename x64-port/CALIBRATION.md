# CALIBRATION.md

Operator reference for characterising the ToupTek ATR2600C (IMX571) through
PINS. Two tools: `camera-analysis.sh` acquires, `camera_analysis.py` measures.

**Run the acquisition stages on astrobit only** — they drive real hardware
through ninaAPI on port 1888. Analysis runs anywhere the frames are.

Why this exists: the camera publishes `ElectronsPerADU = NaN`, and its gain
axis is ToupTek's **native percent scale** (100 = unity, 10000 = 100x), not
the ZWO 0.1 dB scale every SharpCap guide assumes. Nothing here can be looked
up. It has to be measured.

---

## What each stage produces

| Stage | Acquires | Answers |
|---|---|---|
| `--setup` | nothing | venv + `--selftest`: do the estimators recover known values? |
| `--bias` | gain x offset x N bias | minimum adequate offset per gain; read noise in ADU |
| `--flat-auto` | 4 exposure levels x (2 flat + 2 bias) per gain | conversion gain (e-/ADU), hence read noise and full well in electrons |
| `--flat` | flat pairs, you dim the panel | same, for a dimmable panel; superseded by `--flat-auto` |
| `--linearity` | 20 single frames, ramped past saturation | is the response a straight line, and where does it clip |
| `--analyse` | nothing | report + plots from the manifest |

`--flat-auto` supersedes `--flat`. It holds the illumination **fixed** and
sets the signal level by exposure time, probing the reference exposure per
gain instead of taking it on trust. No operator at the panel, repeatable to
the millisecond. `--flat` is kept for anyone with a dimmable panel.

---

## Quickstart: full characterisation, both readout modes

Cover the scope for `--bias`, uncover a flat panel for the rest, and do not
touch the panel once `--flat-auto` starts.

```bash
ssh stefano@astrobit
cd ~/pins/x64-port

./camera-analysis.sh --setup            # once; ends in the analyser self-test

# ---- LCG (readout mode 0) ----
export CAMANA_ROOT=~/camera-analysis/lcg CAMANA_READOUT=0
export CAMANA_GAINS="100 150 200 300 1000 2000" CAMANA_NBIAS=6
./camera-analysis.sh --bias             # cover the scope

export CAMANA_FLAT_GAINS="100 1000 2000" CAMANA_FLAT_OFFSET=2500
./camera-analysis.sh --flat-auto        # uncover the panel, then leave it
./camera-analysis.sh --linearity
./camera-analysis.sh --analyse

# ---- HCG (readout mode 1) ----
export CAMANA_ROOT=~/camera-analysis/hcg CAMANA_READOUT=1
export CAMANA_FLAT_TARGET_PCT=58        # 3x smaller full well; the tail clips first
./camera-analysis.sh --bias
./camera-analysis.sh --flat-auto
./camera-analysis.sh --linearity
./camera-analysis.sh --analyse
```

Budget: the bias sweep is 6 gains x 7 offsets x 6 frames = 252 frames per
mode at ~50 MB each, roughly 13 GB and a couple of hours with the inter-block
pauses. `--flat-auto` adds ~48 frames plus probing, `--linearity` 20.

Record `TouptekAlikeUltraMode` and `TouptekAlikeHighFullwell` before you
start — they change conversion gain and full well outright:

```bash
curl -s 'http://localhost:1888/v2/api/profile/show?active=true' \
  | grep -i 'touptekalike\|BinAverage'
```

---

## Every CAMANA_* variable

### Paths and API

| Variable | Default | Change it when |
|---|---|---|
| `CAMANA_API` | `http://localhost:1888/v2/api` | never, unless ninaAPI moved. 5000 is Touch-N-Stars, a different server |
| `CAMANA_ROOT` | `$HOME/camera-analysis` | **per readout mode** — the single most useful override; keeps LCG and HCG datasets apart |
| `CAMANA_VENV` | `$CAMANA_ROOT/.venv` | sharing one venv across roots |
| `CAMANA_FRAMES` | `$CAMANA_ROOT/frames` | rarely |
| `CAMANA_OUT` | `$CAMANA_ROOT/out` | rarely |
| `CAMANA_MANIFEST` | `$CAMANA_ROOT/manifest.json` | re-analysing a split or archived manifest |
| `CAMANA_IMAGE_PATH` | `$HOME/Documents/N.I.N.A` | must match the profile's `ImageFileSettings.FilePath`, or frames are not found |
| `CAMANA_ANALYSER` | `<script dir>/camera_analysis.py` | rarely |

### Bias sweep

| Variable | Default | Change it when |
|---|---|---|
| `CAMANA_GAINS` | `100 200 300 500 800 1000 1500 2000 3000 5000` | narrowing to scout, or covering the gains you actually image at |
| `CAMANA_OFFSETS` | `0 200 500 1000 1500 2000 2500` | **keep the 0** — see "one clipping row" below |
| `CAMANA_NBIAS` | `8` | set to **6**: 7 offsets x 6 = 42 frames, which fits under the SDK wedge threshold. 8 gives 56 and wedges |
| `CAMANA_EXPOSURE` | `0.0001` | never; it is the camera's `ExposureMin` |

### Flats — interactive (`--flat`)

| Variable | Default | Change it when |
|---|---|---|
| `CAMANA_FLAT_GAINS` | `100 1000 3000` | used by **both** flat stages |
| `CAMANA_FLAT_OFFSET` | `500` | set to the sweep's recommended offset (2500 was used in 2026-09) |
| `CAMANA_FLAT_EXPOSURE` | `2.0` | `--flat` only. Keep >= 2 s: LED panels are PWM-dimmed and a shorter exposure integrates a varying number of pulses, inflating the pair variance and wrecking the conversion gain |

### Flats — exposure-driven (`--flat-auto`)

| Variable | Default | Change it when |
|---|---|---|
| `CAMANA_FLAT_TARGET_PCT` | `70` | **58 for HCG.** Its full well is 3x smaller, so the right-hand tail saturates while the median still looks safe |
| `CAMANA_FLAT_FRACTIONS` | `0.14 0.35 0.68 0.95` | spanning the photon-transfer curve differently; the low point anchors the read-noise end, the high one the shot-noise end |
| `CAMANA_FLAT_PAIRS` | `2` | more repeats per level; 2 is the minimum the pair estimator needs |
| `CAMANA_FLAT_PROBE_SEED` | `0.05` | the probe wastes frames doubling or halving from a bad seed |

### Linearity (`--linearity`)

| Variable | Default | Change it when |
|---|---|---|
| `CAMANA_LIN_GAIN` | `100` | checking linearity at a gain you actually use |
| `CAMANA_LIN_OFFSET` | `$CAMANA_FLAT_OFFSET` | rarely |
| `CAMANA_LIN_STEPS` | `20` | finer ramp near the knee |
| `CAMANA_LIN_EMAX` | probed | you already know the exposure; skips ~6 probe frames |
| `CAMANA_LIN_OVERSHOOT` | `1.4` | the ramp did not reach saturation — the stage says so explicitly |
| `CAMANA_LIN_FIT_PCT` | `40` | never raise it above ~50: fitting into the region under test drags the reference line towards the data and hides the departure |

### Cooling, wedge avoidance, recovery

| Variable | Default | Change it when |
|---|---|---|
| `CAMANA_BLOCK_PAUSE` | `45` | raise it if blocks still wedge. **Do not set 0** |
| `CAMANA_RECOVERY_PAUSE` | `30` | rarely |
| `CAMANA_MAX_RECOVERY` | `3` | rarely |
| `CAMANA_SETPOINT` | `0` | must match the set point the TEC actually holds; re-applied after a reconnect |
| `CAMANA_RECOOL` | `120` | slower cool-down after a reconnect |
| `CAMANA_TIMEOUT` | `120` | rarely |
| `CAMANA_READOUT` | empty | **0 for LCG, 1 for HCG.** Empty leaves whatever the camera has |

Flags: `-f/--force` acquires against an uncooled camera (rehearsal only),
`-h/--help` prints the same tables.

---

## Operational rules

Each of these cost real time. Detail is in `BUILD-NOTES.md` under the named
entry; this is the index.

**The SDK wedges after ~50 consecutive captures.** Measured twice, at 50 and
53 frames, with and without interruption. Every capture then times out after
60 s with `CameraDownloadFailedException` while the camera still reports
`Connected`, and disconnect/reconnect does **not** clear it — the state lives
in the SDK loaded into the PINS process. Only `stop-pins.sh` + `start-pins.sh`
does. So no stage runs an unbroken sequence near that: one bias block is
one gain x 7 offsets x 6 frames = 42, then `CAMANA_BLOCK_PAUSE`. Seven
offsets x 8 frames would be 56, and the pause would always arrive too late.
`--flat-auto` pauses between gains, `--linearity` every 15 steps. Every
stage takes one throwaway frame first and refuses to start if it fails.
→ *BLOCKED SWEEP: 42-FRAME BLOCKS WITH A PAUSE BETWEEN THEM*, *THE TOUPTEK
SDK WEDGES, AND ONLY A PINS RESTART CLEARS IT*, *WHAT WEDGES THE SDK IS
ABORTING A SWEEP, NOT `kill -9`*

**Cool to a set point the TEC holds with headroom under load.** A calibration
library is valid only at the gain, offset, readout mode and temperature it was
taken at; change any of the four and it is void. Pick a set point the cooler
holds at well under full duty, not its floor — a TEC pinned at 100% loses
regulation as ambient drifts and the sweep ends at a different temperature
than it started. 0.0 C was used in 2026-09. Note also that the camera
publishes **two** disagreeing targets: `TemperatureSetPoint` is what the
cooler regulates to, `TargetTemp` is a separate profile field it may ignore.
Checking the wrong one rejected a properly cooled camera.
→ *THE CAMERA PUBLISHES TWO TEMPERATURE TARGETS*, *THE COOLING FAULT WAS THE
WEDGED SDK, NOT THE TEC*, *THE "CAMERA COOL DOWN" TOGGLE DOES NOT MEAN THE
COOLER IS ON*

**The FITS header is the only honest source.** The API reports success on
writes that did not take effect, in three documented ways:

- **Offset.** `/profile/change-value` answers `"Updated setting", 200` and
  `/equipment/camera/info` keeps reporting the old value — info reads the
  driver, the write lands on the profile. Confirmed: profile set to 400, info
  said 0, the frame carried `OFFSET = 400`.
- **Readout mode.** Three routes exist and only one works.
  `/set-readout` answers 200 and changes nothing; `/set-readout/image` is the
  one that reaches captures. And info does not reflect even the successful
  write — it reported mode 0 while the frames were genuinely HCG.
- **Capture status.** A `500 "Unknown error"` does **not** mean no frame was
  written; the first capture after a PINS restart answered 500 with a
  complete, valid FITS on disk. Two different 409s share a status code and
  mean opposite things.

`capture_frame()` therefore verifies `GAIN`/`OFFSET` from the written header
and discards a mismatch. Trusting the 200 would have produced a full sweep of
identically-offset frames and a confident, wrong report.
→ *GAIN AND OFFSET REACH THE CAMERA BY TWO DIFFERENT ROUTES*, *THREE READOUT
ROUTES, ONE OF THEM ACTUALLY AFFECTS CAPTURES*

**Archive by MOVING frames, and verify counts before deleting.** The first
LCG dataset was lost to a copy-then-delete whose copy had not completed.
`mv` within a filesystem is atomic per file and leaves nothing to verify
afterwards; a copy does. If you must copy, count both trees and compare
before removing anything.
→ *I DELETED THE FIRST LCG DATASET*

**Keep one clipping row per gain.** Offset 0 is in the default sweep
deliberately, though it is known to clip ~40% of pixels. Without a `TOO LOW`
row at each gain the analyser can only report the lowest offset it tested,
not that it is the *minimum adequate* one. That row is what makes "minimum" a
measurement rather than an artefact of where the sweep started.

**When a guard fires, check its premise before believing its conclusion.**
Twice in two days a correct guard acting on a wrong premise produced a
convincing false alarm: the cooling check reading `TargetTemp`, and the SDK
probe that never applied the offset and so failed its own header check
against a healthy driver. Each cost a PINS restart.

---

## Reading the output

### The report — `$CAMANA_OUT/calibration-report.md`

Four sections, in the order you want them:

1. **Offset calibration.** One row per (gain, offset). `adequate` means no
   pixel clipped at 0 ADU in *any* Bayer channel **and** `median - 5*sigma > 0`.
   The recommendation is the **minimum** adequate offset — higher is not
   better, every offset ADU is subtracted from usable full well.
2. **Per-channel detail.** R/G1/G2/B separately. A channel-specific failure at
   an offset the global frame passes is exactly what the global median hides.
3. **Read noise and conversion gain.** `sigma = std(b1 - b2) / sqrt(2)` from
   bias pairs; `g = signal / (var(f1-f2)/2 - var(b1-b2)/2)` from flat pairs
   with their matching bias. The `e-/ADU`, `read noise (e-)`, `full well (e-)`
   and `DR (dB)` columns show `-` unless the manifest holds flats.
4. **Recommendation.** One offset covering every gain, plus the per-gain
   minima if you would rather buy back the dynamic range.

Dynamic range is `20*log10(full_well / read_noise_e)` — the amplitude
convention. A power convention using `10*log10` halves it, so the two are not
comparable without saying which was used.

### The plots — `$CAMANA_OUT/*.png`

- `bias_g<gain>_o<offset>_r<mode>.png` — one histogram per setting, all four
  Bayer channels. Look for the left tail touching zero: that is clipping, and
  it is visible here before any number says so.
- `offset_sweep.png`, `read_noise.png`, `photon_transfer.png` — the summary
  figures, written when the manifest supports them.

### The manifest — `$CAMANA_MANIFEST`

One JSON object per frame: `gain`, `offset`, `readout_mode`, `kind`,
`exposure`, `file`, `timestamp`. Written as JSONL during acquisition
(`manifest.json.jsonl`) and assembled into a list at the end, so an
interrupted run still leaves parseable data.

`--linearity` additionally writes `$CAMANA_ROOT/linearity.jsonl` carrying the
measured `median` and `saturated` count per frame, so the fit and any later
script need not re-open 20 FITS files.

### Fixed: four levels per gain now give four framesets

`camera_analysis.py` used to group frames by
`(gain, offset, readout_mode, kind)` and read the **first pair** of each
group. A photon-transfer run writes four exposure levels at one gain and
offset, so all four collapsed into one frameset and `--analyse` measured the
lowest level while silently discarding the rest — a four-point curve reported
as a single point, with no warning that anything had been dropped.

Exposure is now part of the key for flats, so each level is its own frameset.
Verified on the 2026-09-21 manifests: 3 flat framesets became 12, two paths
each. Bias frames keep the old key — they are all at the same minimum exposure
and the pair method wants them pooled.

**A large scatter in e-/ADU between levels is evidence of saturation, not of
noise.** The first HCG flat run reused the LCG exposures and saturated two of
four levels; variance collapses, `signal/variance` explodes, and e-/ADU came
out 0.25, 0.26, **1.51**, 1.16 at one gain. Their mean (0.80) sits plausibly
near the LCG value and is completely wrong. Check saturation first.

---

## Reference baseline — 2026-09-21

Measured on astrobit at 0.0 C, offset 2500, central 2000x3000 region.
**Ultra Mode `True`, High Fullwell `False`** throughout. A future run should
land near these; a large departure means something changed, not that the
sensor did.

### Headline, gain 100

| | LCG (mode 0) | HCG (mode 1) |
|---|---:|---:|
| e-/ADU | 0.7794 | 0.2531 |
| read noise | 2.39 e- | **0.93 e-** |
| full well | **51,078 e-** | 16,587 e- |
| dynamic range | **86.6 dB** | 85.0 dB |
| linearity | +-0.30% | +-0.35% |

51,078 e- matches Sony's ~51,000 e- for the IMX571 at unity gain: the sensor
is to spec.

### The full table

Conversion gain from flat pairs, four levels per gain, scatter 0.2-0.4%. Read
noise is `sigma_bias * e-/ADU`, with sigma from the **dark** bias sweeps — see
the warning below.

| gain | e-/ADU LCG | RN LCG | FW LCG | DR LCG | e-/ADU HCG | RN HCG | FW HCG | DR HCG |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 100 | 0.7794 | 2.39 e- | 51,078 | 86.6 dB | 0.2531 | 0.93 e- | 16,587 | 85.0 dB |
| 150 | 0.5199 | 2.26 | 34,072 | 83.6 | 0.1695 | 0.90 | 11,108 | 81.8 |
| 200 | 0.3891 | 2.16 | 25,500 | 81.4 | 0.1274 | 0.88 | 8,349 | 79.6 |
| 300 | 0.2588 | 2.05 | 16,960 | 78.4 | 0.0848 | 0.85 | 5,557 | 76.3 |
| 1000 | 0.0772 | 1.87 | 5,059 | 68.6 | 0.0253 | 0.76 | 1,658 | 66.8 |
| 2000 | 0.0383 | 1.70 | 2,510 | 63.4 | 0.0126 | 0.73 | 826 | 61.1 |

Consistency check — `e-/ADU * gain` is constant to 1% across a factor of
twenty in gain, which a systematic error would not leave flat:

```
LCG: 77.9  78.0  77.8  77.6  77.2  76.6
HCG: 25.3  25.4  25.5  25.4  25.3  25.2
```

### Bias from the flat stage is `bias_lit`, not `bias`

The flat stages need a bias pair at matching settings to subtract the
read-noise term from the flat difference, but they run with the panel lit and
cannot ask for a cover between every level. Those frames therefore carry light.

They are recorded as **`bias_lit`**, a distinct kind, so nothing can mistake
them for dark frames. The analyser uses them for conversion gain, where the
contamination cancels in signal/variance, and never for read noise. Each flat
stage also runs `check_bias_leak`, which compares the median against the offset
and reports the excess in ADU when it exceeds `CAMANA_BIAS_LEAK_WARN` (20).

This was a real error, not a hypothetical: read noise was overstated by a
factor of two in the first version of these results — 4.92 e- reported against
2.39 actual at gain 100 — because those frames were treated as bias. The leak
scales with panel brightness, so it hides at low levels: sigma read 4.34 ADU at
one brightness and 21.5 ADU at ten times that, same settings.

**Read noise always comes from the bias sweep**, which is shot with the cap on.

### Ultra Mode

`CameraSettings-TouptekAlikeUltraMode`, on by default, read at connect (so a
reconnect is needed after changing it). Measured worth, LCG bias sweep:

| gain | on | off | penalty |
|---:|---:|---:|:--|
| 100 | 3.07 ADU | 3.68 | +20% |
| 1000 | 24.21 | 28.19 | +16% |
| 2000 | 44.33 | 52.37 | +18% |

Leave it on. The minimum adequate offset is unchanged either way, and every
figure in this document was measured with it enabled.

**HCG has 12-17% lower read noise in electrons at every gain.** The earlier
verdict from the bias sweeps — "HCG is noisier" — was wrong: it compared ADU,
and an HCG ADU is worth a third of an LCG one.

The 3x amplification is confirmed three independent ways: the e-/ADU ratio
(3.08/3.05/3.04), the exposure needed for equal signal (0.2/0.065 = 3.1), and
the full-well ratio.

**The ToupTek percent scale is exactly linear**: 0.7794/0.0772 = 10.1 against
10 expected, 0.0772/0.0383 = 2.02 against 2. Gain 1000 really is 10x gain 100
— measured, not assumed.

**Read noise in electrons falls gently with gain** (2.39 -> 1.70 e- LCG,
0.93 -> 0.73 e- HCG). The fourteen-fold rise seen in ADU was pure
amplification.

### Minimum adequate offset

| gain | LCG | HCG |
|---:|---:|---:|
| 100 | 200 | 200 |
| 150 | 200 | 500 |
| 200 | 500 | 500 |
| 300 | 500 | 500 |
| 1000 | 1500 | 2000 |
| 2000 | 2500 | > 2500 (not bracketed) |

One value covering every gain tested: **2500** (LCG), **2000** (HCG, with
gain 2000 unresolved — its minimum is above the swept range).

### Linearity

Both modes are linear to within 0.35% all the way to the ADC ceiling. There is
no knee before the converter runs out of bits — the apparent deviation at the
top is 65535 pinned, not the well filling. The usual shortcut
`full well = e-/ADU * 65535` is therefore **valid on this camera**, now by
measurement rather than assumption.

Saturated pixels appear well before the median saturates: 8,183 of them at an
LCG median of 56,166 ADU (86% of full scale), still dead on the fit. Judge a
flat by its saturated-pixel count, not its median.

### Which mode to use

HCG cuts read noise by 61% — 2.39 to 0.93 e- at gain 100 — and gives up two
thirds of the full well. Those nearly cancel: **dynamic range differs by only
1.6 dB**, so the choice is not about range at all. It is about which end of
the scale the target needs.

| | LCG | HCG |
|---|---|---|
| read noise | 1.7-2.4 e- | **0.73-0.93 e-** |
| full well | **3x** | 1x |
| dynamic range | **86.6 dB** | 85.0 dB |
| offset needed | 200-2500 | 200 to beyond 2500 |
| Bayer channel spread | **0.7%** | 3% |

**Default to LCG.** A clipped star cannot be recovered; a slightly noisier
background can be integrated down. Reach for HCG when the signal itself is a
handful of electrons per sub — narrowband, long exposures, faint extended
objects — and nothing in the field would have used the extra headroom.

---

## Where the retained results live

On **adam**, checked in at `x64-port/calibration-results/` (8.9 MB):

```
calibration-results/lcg/     calibration-results/hcg/
  calibration-report.md        the full report, both modes
  manifest.json                252 bias records each
  flats.json                   48 flat + bias records each
  linearity.jsonl              20 ramp points each
  plots/                       42 PNGs each (per gain x offset bias histograms)
```

The frames themselves stayed on astrobit under `~/camera-analysis/{lcg,hcg}/`
— 253 bias + 48 flat + 20 linearity per mode, ~15 GB each, all retained and
re-analysable. Only the derived artefacts came across; a 26 Mpx FITS does not
belong in git.

Note `flats.json` is the ad-hoc exposure-driven run that predates
`--flat-auto`. The per-level numbers in the table above were computed by a
separate script at the time, before the frameset-grouping fix; re-running
`--analyse` over it now reproduces all four levels per gain.

---

## Worth measuring next

- **Ultra Mode off.** Everything above was taken with
  `TouptekAlikeUltraMode = True`, ToupTek's low-noise readout. All figures
  here are *with it enabled*; measured, turning it off costs
  worse. It is a one-line profile write away and nobody has quantified it.
- **Gain 2000 HCG offset.** Its minimum is above the swept range, so the HCG
  recommendation of 2000 does not actually cover it. Extend
  `CAMANA_OFFSETS` past 2500 for that mode.
- **Dark current against temperature.** Nothing here measures it, and it is
  the term that depends on cooling exponentially.
