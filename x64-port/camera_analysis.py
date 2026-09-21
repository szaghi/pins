#!/usr/bin/env python3
"""Sensor calibration analysis for the ToupTek ATR2600C (IMX571) behind PINS.

Why this exists
---------------
The camera publishes ``ElectronsPerADU = NaN`` and offers a gain axis on
ToupTek's *native percent* scale (100 = unity, 10000 = 100x), not the ZWO
0.1 dB scale that SharpCap tutorials and every "best gain for the 2600"
forum post assume.  Nothing published for a ZWO ASI2600 transfers.  The only
way to know the right offset, the read noise, and where the HCG/LCG knee
sits on *this* camera is to measure it.

What it computes
----------------
1. Offset adequacy per gain, globally **and per Bayer channel**.  A CFA
   sensor can clip one channel while the global histogram looks clean, so a
   global-only check is not a check at all.
2. Read noise from bias *pairs*: ``sigma = std(b1 - b2) / sqrt(2)``.  The
   ``sqrt(2)`` is not optional -- differencing two independent frames adds
   the variances.
3. Conversion gain (e-/ADU) from flat pairs, per Bayer channel.
4. Full well, read noise in electrons, dynamic range.
5. Histograms and summary plots, plus a markdown report.

It also detects bit-shifted data (a real ToupTek trap: 12- or 14-bit data
left-shifted into a 16-bit container makes every value divisible by 16 or 4
and scales e-/ADU by that factor).

Run ``--selftest`` to validate the estimators against synthetic frames with
known read noise and known e-/ADU before trusting any of it on real data.

Companion to ``camera-analysis.sh``, which acquires the frames.
"""

from __future__ import annotations

import argparse
import itertools
import json
import logging
import math
import sys
from dataclasses import dataclass, field
from pathlib import Path
from collections.abc import Iterable, Sequence
from typing import Any

import numpy as np

log = logging.getLogger(__name__)

# --------------------------------------------------------------- exceptions --


class CameraAnalysisError(Exception):
    """Base class for every error this module raises deliberately."""


class FitsLoadError(CameraAnalysisError):
    """A FITS file could not be read, or held no usable 2-D image."""


class ManifestError(CameraAnalysisError):
    """The acquisition manifest is missing, malformed, or inconsistent."""


class InsufficientDataError(CameraAnalysisError):
    """An estimator was asked for a result the data cannot support."""


class SelfTestError(CameraAnalysisError):
    """A self-test estimator failed to recover its known input value."""


# ------------------------------------------------------------- Bayer layout --

#: Sub-plane slices for a CFA pattern, as ``(row_start, col_start)`` pairs
#: keyed by channel name.  The array is indexed ``[row, col]``, so for RGGB
#: with ``BayerOffsetX = BayerOffsetY = 0``::
#:
#:     a[0::2, 0::2] = R    a[0::2, 1::2] = G1
#:     a[1::2, 0::2] = G2   a[1::2, 1::2] = B
#:
#: This is the layout PINS reports for the ATR2600C (``SensorType: RGGB``).
BAYER_PATTERNS: dict[str, dict[str, tuple[int, int]]] = {
    "RGGB": {"R": (0, 0), "G1": (0, 1), "G2": (1, 0), "B": (1, 1)},
    "BGGR": {"B": (0, 0), "G1": (0, 1), "G2": (1, 0), "R": (1, 1)},
    "GRBG": {"G1": (0, 0), "R": (0, 1), "B": (1, 0), "G2": (1, 1)},
    "GBRG": {"G1": (0, 0), "B": (0, 1), "R": (1, 0), "G2": (1, 1)},
    "MONO": {},
}

#: 1 / Phi^-1(3/4): converts a median absolute deviation to a Gaussian sigma.
MAD_TO_SIGMA = 1.4826

#: Full scale of a 16-bit frame.  The IMX571 is 16-bit native, so no
#: bit-shift correction is applied -- but see :func:`detect_bit_shift`.
ADU_MAX = 65535.0

#: Channel plot colours, chosen to stay legible on white and on dark grey.
CHANNEL_COLOURS: dict[str, str] = {
    "global": "#222222",
    "R": "#d1495b",
    "G1": "#2a9d3f",
    "G2": "#66bb3a",
    "B": "#2364aa",
}


def bayer_planes(
    data: np.ndarray,
    pattern: str = "RGGB",
) -> dict[str, np.ndarray]:
    """De-interleave a CFA frame into its four 2x2 sub-planes.

    Parameters
    ----------
    data : numpy.ndarray
        2-D array indexed ``[row, col]``.
    pattern : str, default "RGGB"
        CFA pattern name, a key of :data:`BAYER_PATTERNS`.  ``"MONO"``
        returns an empty mapping.

    Returns
    -------
    dict of str to numpy.ndarray
        Channel name to sub-plane view.  Views, not copies.

    Raises
    ------
    CameraAnalysisError
        If `pattern` is unknown or `data` is not 2-D.

    Notes
    -----
    The offsets assume ``BayerOffsetX = BayerOffsetY = 0``, which is what
    the ToupTek driver reports through PINS.  A sensor read out with a
    non-zero Bayer offset, or a frame cropped by an odd number of pixels,
    permutes the channel labels; the values stay correct but R and B swap.
    """
    if pattern not in BAYER_PATTERNS:
        msg = f"unknown CFA pattern {pattern!r}; known: {sorted(BAYER_PATTERNS)}"
        raise CameraAnalysisError(msg)
    if data.ndim != 2:
        msg = f"expected a 2-D frame, got shape {data.shape}"
        raise CameraAnalysisError(msg)
    return {
        name: data[row::2, col::2]
        for name, (row, col) in BAYER_PATTERNS[pattern].items()
    }


# ------------------------------------------------------------- FITS loading --


def load_fits(path: str | Path) -> tuple[np.ndarray, dict[str, Any]]:
    """Load the first 2-D image HDU of a FITS file as float64.

    Handles ``.fits`` and ``.fits.fz`` alike, and compressed
    (``CompImageHDU``) as well as plain image HDUs.  The HDU index is never
    assumed: PINS writes with ``FITSAddFzExtension = true`` while
    ``FITSCompressionType = NONE``, so a ``.fz`` extension does **not**
    imply a compressed HDU, and a compressed file puts its image at index 1
    behind an empty primary.

    Parameters
    ----------
    path : str or pathlib.Path
        File to read.

    Returns
    -------
    data : numpy.ndarray
        2-D float64 array.
    header : dict
        Header cards as a plain dict, string keys, native values.

    Raises
    ------
    FitsLoadError
        If the file cannot be opened or contains no 2-D image HDU.
    """
    try:
        from astropy.io import fits
    except ImportError as err:  # pragma: no cover - environment problem
        msg = "astropy is required to read FITS files; run the --setup stage"
        raise FitsLoadError(msg) from err

    path = Path(path)
    try:
        with fits.open(path, memmap=False) as hdul:
            for index, hdu in enumerate(hdul):
                data = getattr(hdu, "data", None)
                if data is None or np.ndim(data) != 2:
                    continue
                log.debug("%s: using HDU %d (%s)", path.name, index, type(hdu).__name__)
                header = {
                    str(key): hdu.header[key]
                    for key in hdu.header
                    if key and key not in {"COMMENT", "HISTORY"}
                }
                return np.asarray(data, dtype=np.float64), header
    except OSError as err:
        msg = f"cannot read {path}: {err}"
        raise FitsLoadError(msg) from err

    msg = f"{path}: no 2-D image HDU found"
    raise FitsLoadError(msg)


def detect_bit_shift(data: np.ndarray) -> int:
    """Detect data left-shifted from a lower bit depth into 16 bits.

    Some ToupTek modes deliver 12- or 14-bit samples shifted up into a
    16-bit container.  Every value is then divisible by 16 or by 4, and
    every ADU-denominated result -- read noise, e-/ADU, full well -- is off
    by exactly that factor.  This is worth catching loudly.

    Parameters
    ----------
    data : numpy.ndarray
        Frame to inspect.

    Returns
    -------
    int
        Number of low bits that are identically zero across the frame: 0
        for genuine 16-bit data, 2 for 14-bit shifted, 4 for 12-bit shifted.

    Notes
    -----
    A uniformly zero or constant frame gives a meaningless answer, so a
    frame with no variation returns 0 rather than 16.
    """
    values = np.asarray(data).astype(np.int64).ravel()
    nonzero = values[values > 0]
    if nonzero.size == 0 or np.ptp(values) == 0:
        return 0
    shift = 0
    while shift < 8 and np.all(nonzero % (1 << (shift + 1)) == 0):
        shift += 1
    return shift


# ------------------------------------------------------------- statistics --


def robust_sigma(data: np.ndarray, dither: bool = True) -> float:
    """Gaussian-equivalent sigma from the median absolute deviation.

    Parameters
    ----------
    data : numpy.ndarray
        Samples.
    dither : bool, default True
        Add uniform noise on [-0.5, 0.5) when the samples are
        integer-valued.  See the notes: without this the estimator is
        badly biased at low noise levels.

    Returns
    -------
    float
        ``1.4826 * median(|x - median(x)|)``.  Insensitive to the hot
        pixels and cosmic-ray hits that inflate a plain standard deviation
        on a real bias frame.

    Notes
    -----
    Camera data is integer-valued, and that breaks a naive MAD.  The MAD of
    integers is itself an integer, so ``1.4826 * MAD`` can only land on
    multiples of 1.4826 -- and after the ``/sqrt(2)`` of the pair method,
    on multiples of about 1.048 ADU.  A true sigma of 2.5 ADU has a true
    MAD of 1.686, which must round to 1 or 2, giving 1.05 or 2.10 ADU
    instead of 2.5.  Measured bias at sigma = 1.5 ADU is -30%.  This is a
    quantisation artefact of the *estimator*, not of the sensor, and it
    bites hardest exactly where it matters most: the low-read-noise HCG
    regime this whole analysis exists to find.

    Adding uniform dither on [-0.5, 0.5) restores the continuum the
    estimator assumes.  The dither adds 1/12 ADU^2 of variance -- 0.083
    ADU^2 against a read-noise variance of several ADU^2 -- which is below
    the estimator's own sampling error and is not worth correcting out.
    Non-integer input is left alone, so a difference of two already-dithered
    frames is not dithered twice.

    The dither does not rescue everything.  Measured on synthetic integer
    data (1200x1200, seeded), relative error against known truth:

    ======  ==========  ========
    sigma   no dither   dither
    ======  ==========  ========
    1.0     +4.8%       +8.3%
    1.5     -30.1%      +1.4%
    2.5     -16.1%      +0.6%
    4.0     +4.8%       +0.5%
    8.0     +4.8%       +0.2%
    25.0    +0.6%       +0.1%
    ======  ==========  ========

    Below about 1 ADU the dither's own 1/12 ADU^2 stops being negligible
    against the signal and the estimator is unreliable either way.  A read
    noise under ~1 ADU is not measurable by this method: read the plain
    standard deviation reported beside it and treat both as upper bounds.
    That regime is unlikely on this sensor -- it would take a gain far
    above the HCG knee -- but a sub-ADU figure is not a fact.
    """
    flat = np.asarray(data, dtype=np.float64).ravel()
    if dither and np.all(flat == np.rint(flat)):
        # Deterministic, seeded on the data itself: two calls on the same
        # frame must return the same number, or a report is not reproducible.
        rng = np.random.default_rng(abs(int(np.sum(flat))) % (2**32))
        flat = flat + rng.uniform(-0.5, 0.5, size=flat.size)
    med = float(np.median(flat))
    return float(MAD_TO_SIGMA * np.median(np.abs(flat - med)))


@dataclass(frozen=True)
class ChannelStats:
    """Single-channel bias statistics.

    Attributes
    ----------
    name : str
        Channel label: ``"global"``, ``"R"``, ``"G1"``, ``"G2"``, ``"B"``.
    n_pixels : int
        Sample count.
    n_zero : int
        Pixels at exactly 0 ADU, i.e. clipped at the bottom of the range.
    zero_fraction : float
        `n_zero` / `n_pixels`.
    mean, median, sigma_mad, sigma_std : float
        Location and scale, in ADU.
    percentiles : dict of float to float
        Low-tail percentiles, keyed by percentile (0.001 .. 50).
    n_saturated : int
        Pixels at 65535 ADU.  Should be 0 in a bias frame.
    """

    name: str
    n_pixels: int
    n_zero: int
    zero_fraction: float
    mean: float
    median: float
    sigma_mad: float
    sigma_std: float
    percentiles: dict[float, float]
    n_saturated: int

    @property
    def headroom(self) -> float:
        """ADU between the median and 0 ADU, in units of 5 sigma.

        Returns
        -------
        float
            ``median - 5 * sigma_mad``.  Positive means the noise
            distribution clears zero with margin; this is the quantity the
            offset verdict tests.
        """
        return self.median - 5.0 * self.sigma_mad

    @property
    def adequate(self) -> bool:
        """Whether this channel's offset is adequate.

        Returns
        -------
        bool
            True when no pixel is clipped at 0 **and** the 5-sigma
            headroom is positive.
        """
        return self.n_zero == 0 and self.headroom > 0.0


#: Percentiles reported for the low tail of a bias distribution.
LOW_PERCENTILES: tuple[float, ...] = (0.001, 0.01, 0.1, 1.0, 50.0)


def channel_stats(data: np.ndarray, name: str) -> ChannelStats:
    """Compute bias statistics for one channel.

    Parameters
    ----------
    data : numpy.ndarray
        Pixel values, any shape.
    name : str
        Label to attach to the result.

    Returns
    -------
    ChannelStats
        Populated statistics record.
    """
    flat = np.asarray(data, dtype=np.float64).ravel()
    return ChannelStats(
        name=name,
        n_pixels=int(flat.size),
        n_zero=int(np.count_nonzero(flat <= 0.0)),
        zero_fraction=float(np.count_nonzero(flat <= 0.0) / flat.size),
        mean=float(np.mean(flat)),
        median=float(np.median(flat)),
        sigma_mad=robust_sigma(flat),
        sigma_std=float(np.std(flat)),
        percentiles={
            p: float(v)
            for p, v in zip(
                LOW_PERCENTILES,
                np.percentile(flat, LOW_PERCENTILES),
                strict=True,
            )
        },
        n_saturated=int(np.count_nonzero(flat >= ADU_MAX)),
    )


def read_noise_from_pair(
    frame_a: np.ndarray,
    frame_b: np.ndarray,
) -> tuple[float, float]:
    """Read noise in ADU from a pair of bias frames.

    Parameters
    ----------
    frame_a, frame_b : numpy.ndarray
        Two bias frames taken at identical settings.

    Returns
    -------
    sigma_mad : float
        MAD-based robust estimate, in ADU.
    sigma_std : float
        Plain standard-deviation estimate, in ADU.

    Raises
    ------
    InsufficientDataError
        If the two frames have different shapes.

    Notes
    -----
    The frames are independent, so ``var(a - b) = var(a) + var(b) =
    2 * sigma_read^2`` and therefore ``sigma_read = std(a - b) / sqrt(2)``.
    Dropping the ``sqrt(2)`` overstates read noise by 41%.  Differencing
    also cancels the fixed-pattern offset structure that a single-frame
    standard deviation would wrongly count as noise, which is why the pair
    method is used rather than ``std(bias)``.
    """
    a = np.asarray(frame_a, dtype=np.float64)
    b = np.asarray(frame_b, dtype=np.float64)
    if a.shape != b.shape:
        msg = f"bias pair shape mismatch: {a.shape} vs {b.shape}"
        raise InsufficientDataError(msg)
    diff = a - b
    root2 = math.sqrt(2.0)
    return robust_sigma(diff) / root2, float(np.std(diff)) / root2


def conversion_gain(
    flat_a: np.ndarray,
    flat_b: np.ndarray,
    bias_a: np.ndarray,
    bias_b: np.ndarray,
) -> tuple[float, float, float]:
    """Conversion gain in e-/ADU from a flat pair and a bias pair.

    Parameters
    ----------
    flat_a, flat_b : numpy.ndarray
        Two flat frames at identical settings and identical illumination.
    bias_a, bias_b : numpy.ndarray
        Two bias frames at the same gain/offset/readout mode.

    Returns
    -------
    gain : float
        Conversion gain, e-/ADU.
    signal : float
        Mean bias-subtracted flat level, ADU.
    var_signal : float
        Shot-noise variance of the signal, ADU^2, read-noise-free.

    Raises
    ------
    InsufficientDataError
        If the signal is non-positive or its variance is non-positive,
        which means the flats are not actually illuminated or are not a
        matched pair.

    Notes
    -----
    The algebra, written out because the factors of two are where this
    estimator is usually got wrong.

    Let ``S`` be the mean signal in ADU above bias and ``g`` the conversion
    gain in e-/ADU.  Shot noise is Poisson in electrons, so the signal
    variance in ADU is ``var_shot = S / g``.

    Differencing two flats cancels the flat-field structure (pixel-response
    non-uniformity), which otherwise dominates and would masquerade as
    noise.  The difference carries twice the shot variance and twice the
    read variance::

        var(f1 - f2) = 2 * var_shot + 2 * sigma_read^2

    Differencing the two biases gives ``var(b1 - b2) = 2 * sigma_read^2``,
    so subtracting removes the read-noise term::

        var(f1 - f2) - var(b1 - b2) = 2 * var_shot = 2 * S / g

    The mean signal is likewise taken as the average of the two flats minus
    the average of the two biases, which is why the numerator below is
    written as a sum over both pairs::

        S = ((mean_f1 + mean_f2) - (mean_b1 + mean_b2)) / 2

    Combining::

        g = S / var_shot
          = ((mean_f1 + mean_f2) - (mean_b1 + mean_b2)) / 2
            / ([var(f1 - f2) - var(b1 - b2)] / 2)
          = ((mean_f1 + mean_f2) - (mean_b1 + mean_b2))
            / (var(f1 - f2) - var(b1 - b2))

    The two halves cancel, leaving the compact form used here.  The
    equivalent textbook statement ``g = mean_signal / (var_diff / 2)`` is
    the same expression with the 2s left in.
    """
    fa = np.asarray(flat_a, dtype=np.float64)
    fb = np.asarray(flat_b, dtype=np.float64)
    ba = np.asarray(bias_a, dtype=np.float64)
    bb = np.asarray(bias_b, dtype=np.float64)

    numerator = (float(np.mean(fa)) + float(np.mean(fb))) - (
        float(np.mean(ba)) + float(np.mean(bb))
    )
    var_flat_diff = float(np.var(fa - fb))
    var_bias_diff = float(np.var(ba - bb))
    denominator = var_flat_diff - var_bias_diff

    if numerator <= 0.0:
        msg = (
            f"flat level {numerator / 2.0:.1f} ADU is not above bias; "
            "the panel was probably off"
        )
        raise InsufficientDataError(msg)
    if denominator <= 0.0:
        msg = (
            f"flat-difference variance {var_flat_diff:.1f} does not exceed "
            f"bias-difference variance {var_bias_diff:.1f}; the flats are not "
            "an independent pair"
        )
        raise InsufficientDataError(msg)

    return numerator / denominator, numerator / 2.0, denominator / 2.0


# ------------------------------------------------------------ data records --


@dataclass(frozen=True)
class FrameSet:
    """A group of frames sharing gain, offset and readout mode.

    Attributes
    ----------
    gain, offset : int
        Camera settings.  `gain` is on the ToupTek native percent scale.
    readout_mode : int
        Index into the camera's ``ReadoutModes`` list.
    kind : str
        ``"bias"`` or ``"flat"``.
    exposure : float
        Exposure time, seconds.
    paths : list of pathlib.Path
        The frames, in acquisition order.
    """

    gain: int
    offset: int
    readout_mode: int
    kind: str
    exposure: float
    paths: list[Path] = field(default_factory=list)

    @property
    def key(self) -> tuple[int, int, int, str]:
        """Grouping key: ``(gain, offset, readout_mode, kind)``."""
        return (self.gain, self.offset, self.readout_mode, self.kind)

    @property
    def label(self) -> str:
        """Human-readable settings label for plot titles."""
        return (
            f"gain {self.gain} / offset {self.offset} / readout {self.readout_mode}"
        )


@dataclass
class BiasResult:
    """Offset-calibration result for one (gain, offset, readout mode).

    Attributes
    ----------
    frameset : FrameSet
        The frames analysed.
    stats : dict of str to ChannelStats
        Keyed by ``"global"``, ``"R"``, ``"G1"``, ``"G2"``, ``"B"``.
    sigma_read_mad, sigma_read_std : float or None
        Read noise in ADU from the first frame pair, robust and plain.
        None when fewer than two frames were available.
    bit_shift : int
        Result of :func:`detect_bit_shift` on the first frame.
    sample : numpy.ndarray or None
        First frame, retained for plotting.  Dropped when plotting is off.
    """

    frameset: FrameSet
    stats: dict[str, ChannelStats]
    sigma_read_mad: float | None
    sigma_read_std: float | None
    bit_shift: int
    sample: np.ndarray | None = None

    @property
    def adequate(self) -> bool:
        """True when every channel, and the global frame, clears zero."""
        return all(s.adequate for s in self.stats.values())

    @property
    def failing_channels(self) -> list[str]:
        """Names of the channels whose offset is inadequate."""
        return [n for n, s in self.stats.items() if not s.adequate and n != "global"]


@dataclass
class GainResult:
    """Per-Bayer-channel conversion gain at one camera gain.

    Attributes
    ----------
    gain : int
        Camera gain, ToupTek percent scale.
    readout_mode : int
        Readout mode index.
    e_per_adu : dict of str to float
        Conversion gain per channel, e-/ADU.
    signal : dict of str to float
        Mean flat level above bias per channel, ADU.
    var_signal : dict of str to float
        Shot-noise variance per channel, ADU^2.
    """

    gain: int
    readout_mode: int
    e_per_adu: dict[str, float] = field(default_factory=dict)
    signal: dict[str, float] = field(default_factory=dict)
    var_signal: dict[str, float] = field(default_factory=dict)

    @property
    def mean_e_per_adu(self) -> float | None:
        """Channel-averaged conversion gain, or None if nothing converged."""
        values = [v for v in self.e_per_adu.values() if math.isfinite(v)]
        return float(np.mean(values)) if values else None


# ------------------------------------------------------------- the analyser --


class CameraAnalysis:
    """Full calibration analysis over a manifest of acquired frames.

    Parameters
    ----------
    pattern : str, default "RGGB"
        CFA pattern of the sensor.
    keep_samples : bool, default True
        Retain one frame per bias set for plotting.  Set False to keep
        memory down on a 26 Mpx sensor when only the numbers are wanted.
    """

    def __init__(self, pattern: str = "RGGB", keep_samples: bool = True) -> None:
        self.pattern = pattern
        self.keep_samples = keep_samples
        self.bias: list[BiasResult] = []
        self.gains: list[GainResult] = []
        self.bit_shift_warnings: set[int] = set()

    # -- loading ------------------------------------------------------------

    @staticmethod
    def framesets_from_manifest(path: str | Path) -> list[FrameSet]:
        """Group a shell-written manifest into :class:`FrameSet` records.

        Parameters
        ----------
        path : str or pathlib.Path
            JSON manifest written by ``camera-analysis.sh``: a list of
            objects carrying ``gain``, ``offset``, ``readout_mode``,
            ``kind``, ``exposure`` and ``file``.

        Returns
        -------
        list of FrameSet
            One per distinct ``(gain, offset, readout_mode, kind)``, each
            with its frames in manifest order.

        Raises
        ------
        ManifestError
            If the file is missing, is not JSON, is not a list, or holds a
            record missing a required field.
        """
        path = Path(path)
        try:
            raw = json.loads(path.read_text())
        except FileNotFoundError as err:
            msg = f"no manifest at {path}; run the --bias stage first"
            raise ManifestError(msg) from err
        except json.JSONDecodeError as err:
            msg = f"{path} is not valid JSON: {err}"
            raise ManifestError(msg) from err

        if not isinstance(raw, list):
            msg = f"{path}: expected a JSON list of frame records"
            raise ManifestError(msg)

        grouped: dict[tuple[int, int, int, str], FrameSet] = {}
        for record in raw:
            try:
                gain = int(record["gain"])
                offset = int(record["offset"])
                mode = int(record.get("readout_mode", 0))
                kind = str(record["kind"])
                exposure = float(record["exposure"])
                file_path = Path(str(record["file"]))
            except (KeyError, TypeError, ValueError) as err:
                msg = f"{path}: malformed record {record!r}: {err}"
                raise ManifestError(msg) from err
            # Exposure belongs in the key for flats, and must be: a
            # photon-transfer run takes four signal levels at one gain and
            # offset, and those are four different measurements. Keying only
            # on (gain, offset, mode, kind) collapsed all four into one frame
            # set, and analyse_flats reads paths[0..1] -- so a four-level run
            # silently measured the lowest level and discarded the rest.
            # Bias frames keep the old key: they are all at the same minimum
            # exposure, and the pair method wants them pooled.
            key = (gain, offset, mode, kind, exposure if kind == "flat" else None)
            if key not in grouped:
                grouped[key] = FrameSet(
                    gain=gain,
                    offset=offset,
                    readout_mode=mode,
                    kind=kind,
                    exposure=exposure,
                )
            grouped[key].paths.append(file_path)

        framesets = sorted(grouped.values(), key=lambda fs: fs.key)
        log.info("manifest %s: %d frame set(s)", path.name, len(framesets))
        return framesets

    # -- offset calibration -------------------------------------------------

    def analyse_bias(self, framesets: Iterable[FrameSet]) -> list[BiasResult]:
        """Run the offset and read-noise analysis over the bias sets.

        Parameters
        ----------
        framesets : iterable of FrameSet
            All frame sets; non-bias sets are ignored.

        Returns
        -------
        list of BiasResult
            One per bias set, in ``(gain, offset)`` order.
        """
        results: list[BiasResult] = []
        for fs in framesets:
            if fs.kind != "bias" or not fs.paths:
                continue
            frames = [load_fits(p)[0] for p in fs.paths]
            first = frames[0]

            shift = detect_bit_shift(first)
            if shift:
                self.bit_shift_warnings.add(shift)

            stats = {"global": channel_stats(first, "global")}
            for name, plane in bayer_planes(first, self.pattern).items():
                stats[name] = channel_stats(plane, name)

            sigma_mad: float | None = None
            sigma_std: float | None = None
            if len(frames) >= 2:
                sigma_mad, sigma_std = read_noise_from_pair(frames[0], frames[1])
            else:
                log.warning(
                    "%s: only %d bias frame(s); read noise needs a pair",
                    fs.label,
                    len(frames),
                )

            results.append(
                BiasResult(
                    frameset=fs,
                    stats=stats,
                    sigma_read_mad=sigma_mad,
                    sigma_read_std=sigma_std,
                    bit_shift=shift,
                    sample=first if self.keep_samples else None,
                )
            )
        self.bias = results
        return results

    def minimum_adequate_offset(self) -> dict[int, int | None]:
        """Smallest adequate offset for each gain tested.

        Returns
        -------
        dict of int to (int or None)
            Gain to smallest offset that clips no pixel in any channel and
            keeps ``median - 5 sigma`` above zero, or None when no tested
            offset was adequate.

        Notes
        -----
        The *minimum* adequate value is the answer, not the largest one
        tried.  Offset is dead signal: every ADU of it is subtracted from
        the available full well and therefore from dynamic range.  Piling
        on offset "for safety" trades real highlight headroom for nothing.
        """
        by_gain: dict[int, list[BiasResult]] = {}
        for result in self.bias:
            by_gain.setdefault(result.frameset.gain, []).append(result)
        answer: dict[int, int | None] = {}
        for gain, results in sorted(by_gain.items()):
            adequate = sorted(
                (r.frameset.offset for r in results if r.adequate),
            )
            answer[gain] = adequate[0] if adequate else None
        return answer

    # -- read noise vs gain -------------------------------------------------

    def read_noise_curve(
        self,
        offset_choice: dict[int, int | None] | None = None,
    ) -> list[tuple[int, float, float]]:
        """Read noise against gain, one point per gain.

        Parameters
        ----------
        offset_choice : dict of int to (int or None), optional
            Gain to preferred offset.  When given, the bias set at that
            offset is used; otherwise the largest offset available at each
            gain is used, on the grounds that it is the least likely to be
            clipped (clipping truncates the distribution and *understates*
            read noise, which is the dangerous direction to err).

        Returns
        -------
        list of tuple
            ``(gain, sigma_mad_adu, sigma_std_adu)`` sorted by gain.
        """
        by_gain: dict[int, list[BiasResult]] = {}
        for result in self.bias:
            if result.sigma_read_mad is None:
                continue
            by_gain.setdefault(result.frameset.gain, []).append(result)

        curve: list[tuple[int, float, float]] = []
        for gain, results in sorted(by_gain.items()):
            preferred = (offset_choice or {}).get(gain)
            chosen = next(
                (r for r in results if r.frameset.offset == preferred),
                max(results, key=lambda r: r.frameset.offset),
            )
            # Both are non-None by construction: the loop above skipped every
            # result whose read noise was missing. Read them into locals so the
            # narrowing is explicit rather than an assert that -O would strip.
            sigma_mad = chosen.sigma_read_mad
            sigma_std = chosen.sigma_read_std
            if sigma_mad is None or sigma_std is None:  # pragma: no cover
                continue
            curve.append((gain, sigma_mad, sigma_std))
        return curve

    @staticmethod
    def detect_hcg_knee(
        curve: Sequence[tuple[int, float, float]],
    ) -> tuple[int, int, float] | None:
        """Locate the conversion-gain transition in a read-noise curve.

        Parameters
        ----------
        curve : sequence of tuple
            Output of :meth:`read_noise_curve`.

        Returns
        -------
        tuple or None
            ``(gain_before, gain_after, relative_drop)`` for the adjacent
            gain pair with the largest fractional fall in read noise, or
            None when the curve has fewer than two points or read noise
            never falls.

        Notes
        -----
        A dual-conversion-gain sensor such as the IMX571 switches its
        charge-to-voltage conversion at a driver-defined gain.  Read noise
        drops abruptly there -- the HCG/LCG knee.  This finds the largest
        single step down rather than assuming a published value, because
        the ToupTek percent scale puts the knee somewhere no ZWO table
        predicts.  A smoothly falling curve with no distinct step will
        still return its steepest segment, so read the magnitude: a drop of
        a few percent is not a knee.
        """
        if len(curve) < 2:
            return None
        best: tuple[int, int, float] | None = None
        for (g0, s0, _), (g1, s1, _) in itertools.pairwise(curve):
            if s0 <= 0.0:
                continue
            drop = (s0 - s1) / s0
            if drop > 0.0 and (best is None or drop > best[2]):
                best = (g0, g1, drop)
        return best

    # -- conversion gain ----------------------------------------------------

    def analyse_flats(self, framesets: Iterable[FrameSet]) -> list[GainResult]:
        """Compute per-channel conversion gain from matched flat/bias sets.

        Parameters
        ----------
        framesets : iterable of FrameSet
            All frame sets.  Flats are matched to the bias set sharing
            gain, offset and readout mode.

        Returns
        -------
        list of GainResult
            One per flat set that produced at least one channel result.
        """
        sets = list(framesets)
        bias_index = {
            fs.key[:3]: fs for fs in sets if fs.kind == "bias" and len(fs.paths) >= 2
        }

        results: list[GainResult] = []
        for fs in sets:
            if fs.kind != "flat" or len(fs.paths) < 2:
                continue
            bias_fs = bias_index.get(fs.key[:3])
            if bias_fs is None:
                log.warning("%s: no matching bias pair, skipping gain", fs.label)
                continue

            flat_a, _ = load_fits(fs.paths[0])
            flat_b, _ = load_fits(fs.paths[1])
            bias_a, _ = load_fits(bias_fs.paths[0])
            bias_b, _ = load_fits(bias_fs.paths[1])

            result = GainResult(gain=fs.gain, readout_mode=fs.readout_mode)
            planes = [
                ("global", flat_a, flat_b, bias_a, bias_b),
                *(
                    (name, *frames)
                    for name, frames in _zip_planes(
                        self.pattern, flat_a, flat_b, bias_a, bias_b
                    )
                ),
            ]
            for name, fa, fb, ba, bb in planes:
                try:
                    gain_value, signal, var_signal = conversion_gain(fa, fb, ba, bb)
                except InsufficientDataError as err:
                    log.warning("%s channel %s: %s", fs.label, name, err)
                    continue
                result.e_per_adu[name] = gain_value
                result.signal[name] = signal
                result.var_signal[name] = var_signal

            if result.e_per_adu:
                results.append(result)

        self.gains = results
        return results

    def derived_metrics(self) -> list[dict[str, Any]]:
        """Combine read noise and conversion gain into physical units.

        Returns
        -------
        list of dict
            One record per gain that has both a read-noise measurement and
            a conversion gain, carrying ``gain``, ``sigma_read_adu``,
            ``e_per_adu``, ``read_noise_e``, ``full_well_e`` and
            ``dynamic_range_db``.

        Notes
        -----
        Full well is estimated as ``(65535 - offset_median) * g`` electrons,
        the charge that fills the remaining ADU range.  It is an upper
        bound: the sensor may clip before the ADC does.  Dynamic range is
        ``20 log10(full_well / read_noise_e)``, the amplitude convention --
        a power convention using 10 log10 would halve the number, so the
        two are not comparable without saying which was used.
        """
        noise_by_gain = {g: (m, s) for g, m, s in self.read_noise_curve()}
        median_by_gain = {
            r.frameset.gain: r.stats["global"].median for r in self.bias
        }

        records: list[dict[str, Any]] = []
        for gain_result in self.gains:
            gain = gain_result.gain
            if gain not in noise_by_gain:
                continue
            e_per_adu = gain_result.mean_e_per_adu
            if e_per_adu is None or e_per_adu <= 0.0:
                continue
            sigma_adu = noise_by_gain[gain][0]
            read_e = sigma_adu * e_per_adu
            full_well = (ADU_MAX - median_by_gain.get(gain, 0.0)) * e_per_adu
            dynamic_range = (
                20.0 * math.log10(full_well / read_e) if read_e > 0.0 else float("nan")
            )
            records.append(
                {
                    "gain": gain,
                    "sigma_read_adu": sigma_adu,
                    "e_per_adu": e_per_adu,
                    "read_noise_e": read_e,
                    "full_well_e": full_well,
                    "dynamic_range_db": dynamic_range,
                }
            )
        return records


def _zip_planes(
    pattern: str,
    *frames: np.ndarray,
) -> list[tuple[str, tuple[np.ndarray, ...]]]:
    """Pair up the same Bayer channel across several frames.

    Parameters
    ----------
    pattern : str
        CFA pattern name.
    *frames : numpy.ndarray
        Frames to de-interleave in lockstep.

    Returns
    -------
    list of tuple
        ``(channel_name, (plane_from_each_frame, ...))``.
    """
    per_frame = [bayer_planes(f, pattern) for f in frames]
    if not per_frame or not per_frame[0]:
        return []
    return [
        (name, tuple(planes[name] for planes in per_frame))
        for name in per_frame[0]
    ]


# ------------------------------------------------------------------ plotting --


def _configure_matplotlib(show: bool) -> Any:
    """Import matplotlib with a backend suited to the display situation.

    Parameters
    ----------
    show : bool
        True when figures must appear on screen.

    Returns
    -------
    module
        ``matplotlib.pyplot``.

    Raises
    ------
    CameraAnalysisError
        If matplotlib is not installed.

    Notes
    -----
    astrobit is headless, so the default is Agg and figures only ever land
    on disk.  ``--show`` needs a display: run over ``ssh -X`` (or -Y), or
    copy the PNGs to a machine that has one.
    """
    try:
        import matplotlib
    except ImportError as err:  # pragma: no cover - environment problem
        msg = "matplotlib is required for plots; run the --setup stage"
        raise CameraAnalysisError(msg) from err
    if not show:
        matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    # Explicit, not inherited: these figures are read on a white page, in a
    # dark terminal viewer and on a phone. Default styling washes out in at
    # least one of those.
    plt.rcParams.update(
        {
            "figure.facecolor": "white",
            "savefig.facecolor": "white",
            "axes.facecolor": "white",
            "axes.edgecolor": "#333333",
            "axes.labelcolor": "#111111",
            "axes.grid": True,
            "grid.color": "#bbbbbb",
            "grid.alpha": 0.6,
            "text.color": "#111111",
            "xtick.color": "#111111",
            "ytick.color": "#111111",
            "font.size": 11,
            "axes.titlesize": 12,
            "axes.labelsize": 11,
            "legend.fontsize": 9,
            "legend.framealpha": 0.9,
        }
    )
    return plt


def plot_bias_histograms(
    results: Sequence[BiasResult],
    out_dir: Path,
    pattern: str = "RGGB",
    show: bool = False,
) -> list[Path]:
    """Per-setting bias histograms, full range plus low-tail zoom.

    Parameters
    ----------
    results : sequence of BiasResult
        Bias analyses to plot, one figure each.
    out_dir : pathlib.Path
        Destination directory; created if absent.
    pattern : str, default "RGGB"
        CFA pattern, for de-interleaving the sample frame.
    show : bool, default False
        Display interactively in addition to saving.

    Returns
    -------
    list of pathlib.Path
        The PNG files written.
    """
    plt = _configure_matplotlib(show)
    out_dir.mkdir(parents=True, exist_ok=True)
    written: list[Path] = []

    for result in results:
        if result.sample is None:
            continue
        fs = result.frameset
        stats = result.stats["global"]
        fig, (ax_full, ax_tail) = plt.subplots(1, 2, figsize=(13.0, 5.2))

        planes = {"global": result.sample, **bayer_planes(result.sample, pattern)}
        lo = float(np.min(result.sample))
        hi = float(np.percentile(result.sample, 99.99))
        span = max(hi - lo, 1.0)
        bins_full = np.linspace(lo, lo + span, 256)

        for name, plane in planes.items():
            ax_full.hist(
                np.ravel(plane),
                bins=bins_full,
                histtype="step",
                linewidth=1.6 if name == "global" else 1.1,
                color=CHANNEL_COLOURS.get(name, "#777777"),
                label=name,
            )
        ax_full.set_yscale("log")
        ax_full.set_xlabel("ADU")
        ax_full.set_ylabel("pixels (log)")
        ax_full.set_title(f"bias histogram - {fs.label}")
        ax_full.legend(loc="upper right")

        # Left tail: where clipping actually shows. Anything at or below 0
        # is lost signal, so shade it.
        tail_hi = max(stats.median + 6.0 * stats.sigma_mad, 8.0)
        bins_tail = np.linspace(-2.0, tail_hi, 200)
        for name, plane in planes.items():
            ax_tail.hist(
                np.ravel(plane),
                bins=bins_tail,
                histtype="step",
                linewidth=1.6 if name == "global" else 1.1,
                color=CHANNEL_COLOURS.get(name, "#777777"),
                label=name,
            )
        ax_tail.axvspan(-2.0, 0.0, color="#d1495b", alpha=0.25, label="clipped (<=0)")
        ax_tail.axvline(0.0, color="#d1495b", linewidth=1.8)
        ax_tail.axvline(
            stats.median, color="#111111", linewidth=1.4, linestyle="--", label="median"
        )
        ax_tail.axvline(
            stats.headroom,
            color="#e07b00",
            linewidth=1.4,
            linestyle=":",
            label="median - 5 sigma",
        )
        ax_tail.set_yscale("log")
        ax_tail.set_xlabel("ADU")
        ax_tail.set_ylabel("pixels (log)")
        verdict = "ADEQUATE" if result.adequate else "TOO LOW"
        failing = (
            "" if result.adequate else f"  (clipping: {', '.join(result.failing_channels) or 'global'})"
        )
        ax_tail.set_title(f"low tail - offset {fs.offset}: {verdict}{failing}")
        ax_tail.legend(loc="upper right")

        fig.suptitle(
            f"ATR2600C bias - {fs.label} - "
            f"{stats.n_zero} clipped px ({stats.zero_fraction * 100:.4f}%)",
            fontsize=13,
        )
        fig.tight_layout()
        path = out_dir / f"bias_g{fs.gain:05d}_o{fs.offset:05d}_r{fs.readout_mode}.png"
        fig.savefig(path, dpi=130)
        written.append(path)
        if show:
            plt.show()
        plt.close(fig)

    log.info("wrote %d bias histogram(s) to %s", len(written), out_dir)
    return written


def plot_offset_sweep(
    results: Sequence[BiasResult],
    out_dir: Path,
    show: bool = False,
) -> Path | None:
    """Clipped fraction against offset, one line per gain.

    Parameters
    ----------
    results : sequence of BiasResult
        All bias analyses.
    out_dir : pathlib.Path
        Destination directory.
    show : bool, default False
        Display interactively as well.

    Returns
    -------
    pathlib.Path or None
        The PNG written, or None when there is nothing to plot.
    """
    plt = _configure_matplotlib(show)
    by_gain: dict[int, list[BiasResult]] = {}
    for result in results:
        by_gain.setdefault(result.frameset.gain, []).append(result)
    if not by_gain:
        return None

    out_dir.mkdir(parents=True, exist_ok=True)
    fig, ax = plt.subplots(figsize=(10.0, 6.0))
    colours = plt.cm.viridis(np.linspace(0.0, 0.88, len(by_gain)))

    # A zero clipped fraction cannot be drawn on a log axis; put it on a
    # floor an order of magnitude below the smallest measurable fraction so
    # "clean" is visible rather than missing.
    floor = 1e-9
    for colour, (gain, group) in zip(colours, sorted(by_gain.items()), strict=True):
        group = sorted(group, key=lambda r: r.frameset.offset)
        offsets = [r.frameset.offset for r in group]
        fractions = [max(r.stats["global"].zero_fraction, floor) for r in group]
        ax.plot(
            offsets,
            fractions,
            marker="o",
            linewidth=1.8,
            color=colour,
            label=f"gain {gain}",
        )
        for result in group:
            if result.adequate:
                ax.plot(
                    result.frameset.offset,
                    max(result.stats["global"].zero_fraction, floor),
                    marker="*",
                    markersize=13,
                    color="#2a9d3f",
                    zorder=5,
                )
                break

    ax.axhline(
        floor,
        color="#2a9d3f",
        linestyle="--",
        linewidth=1.5,
        label="zero clipping (adequacy floor)",
    )
    ax.set_yscale("log")
    ax.set_xlabel("offset (ADU, 0..7936 scale)")
    ax.set_ylabel("fraction of pixels at 0 ADU (log)")
    ax.set_title(
        "ATR2600C offset sweep - star marks the minimum adequate offset per gain"
    )
    ax.legend(loc="best", ncol=2)
    fig.tight_layout()
    path = out_dir / "offset_sweep.png"
    fig.savefig(path, dpi=130)
    if show:
        plt.show()
    plt.close(fig)
    log.info("wrote %s", path)
    return path


def plot_read_noise(
    curve: Sequence[tuple[int, float, float]],
    knee: tuple[int, int, float] | None,
    derived: Sequence[dict[str, Any]],
    out_dir: Path,
    show: bool = False,
) -> Path | None:
    """Read noise against gain, in ADU and, where known, in electrons.

    Parameters
    ----------
    curve : sequence of tuple
        ``(gain, sigma_mad, sigma_std)`` points.
    knee : tuple or None
        Detected HCG transition from :meth:`CameraAnalysis.detect_hcg_knee`.
    derived : sequence of dict
        Records from :meth:`CameraAnalysis.derived_metrics`, for the
        electron-unit panel.  May be empty.
    out_dir : pathlib.Path
        Destination directory.
    show : bool, default False
        Display interactively as well.

    Returns
    -------
    pathlib.Path or None
        The PNG written, or None when the curve is empty.
    """
    plt = _configure_matplotlib(show)
    if not curve:
        return None
    out_dir.mkdir(parents=True, exist_ok=True)

    panels = 2 if derived else 1
    fig, axes = plt.subplots(1, panels, figsize=(6.6 * panels, 5.6), squeeze=False)
    ax = axes[0][0]

    gains = [g for g, _, _ in curve]
    ax.plot(
        gains,
        [m for _, m, _ in curve],
        marker="o",
        linewidth=2.0,
        color="#2364aa",
        label="sigma_read (MAD, robust)",
    )
    ax.plot(
        gains,
        [s for _, _, s in curve],
        marker="s",
        linewidth=1.4,
        linestyle="--",
        color="#d1495b",
        label="sigma_read (std)",
    )
    if knee is not None:
        g0, g1, drop = knee
        ax.axvline(
            math.sqrt(g0 * g1),
            color="#e07b00",
            linewidth=2.0,
            linestyle="-.",
            label=f"HCG knee {g0}->{g1} ({drop * 100:.0f}% drop)",
        )
    ax.set_xscale("log")
    ax.set_xlabel("gain (ToupTek percent scale: 100 = unity)")
    ax.set_ylabel("read noise (ADU)")
    ax.set_title("read noise vs gain")
    ax.legend(loc="best")

    if derived:
        ax_e = axes[0][1]
        ax_e.plot(
            [d["gain"] for d in derived],
            [d["read_noise_e"] for d in derived],
            marker="o",
            linewidth=2.0,
            color="#2a9d3f",
            label="read noise (e-)",
        )
        ax_e.set_xscale("log")
        ax_e.set_xlabel("gain (ToupTek percent scale)")
        ax_e.set_ylabel("read noise (electrons)")
        ax_e.set_title("read noise in electrons")
        ax_e.legend(loc="best")

    fig.tight_layout()
    path = out_dir / "read_noise_vs_gain.png"
    fig.savefig(path, dpi=130)
    if show:
        plt.show()
    plt.close(fig)
    log.info("wrote %s", path)
    return path


def plot_photon_transfer(
    gains: Sequence[GainResult],
    out_dir: Path,
    show: bool = False,
) -> Path | None:
    """Photon transfer curve: shot-noise variance against signal, log-log.

    Parameters
    ----------
    gains : sequence of GainResult
        Conversion-gain results, one point per gain per channel.
    out_dir : pathlib.Path
        Destination directory.
    show : bool, default False
        Display interactively as well.

    Returns
    -------
    pathlib.Path or None
        The PNG written, or None when there are no flats.

    Notes
    -----
    A pure shot-noise regime gives variance proportional to signal, i.e.
    slope 1 in log-log.  A fitted slope well below 1 means the flats are
    saturating; well above 1 means residual flat-field structure survived
    the differencing, usually from an unstable panel.
    """
    plt = _configure_matplotlib(show)
    if not gains:
        return None
    out_dir.mkdir(parents=True, exist_ok=True)

    fig, ax = plt.subplots(figsize=(9.5, 6.2))
    channels = sorted({name for g in gains for name in g.signal})
    for name in channels:
        points = sorted(
            (g.signal[name], g.var_signal[name]) for g in gains if name in g.signal
        )
        if not points:
            continue
        xs = np.array([p[0] for p in points], dtype=np.float64)
        ys = np.array([p[1] for p in points], dtype=np.float64)
        label = name
        if xs.size >= 2 and np.all(xs > 0) and np.all(ys > 0):
            slope, _ = np.polyfit(np.log10(xs), np.log10(ys), 1)
            label = f"{name} (slope {slope:.2f})"
        ax.plot(
            xs,
            ys,
            marker="o",
            linewidth=1.6,
            color=CHANNEL_COLOURS.get(name, "#777777"),
            label=label,
        )

    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_xlabel("signal above bias (ADU)")
    ax.set_ylabel("shot-noise variance (ADU^2)")
    ax.set_title("photon transfer curve - slope 1 means pure shot noise")
    ax.legend(loc="best")
    fig.tight_layout()
    path = out_dir / "photon_transfer.png"
    fig.savefig(path, dpi=130)
    if show:
        plt.show()
    plt.close(fig)
    log.info("wrote %s", path)
    return path


# -------------------------------------------------------------- reporting --


def build_report(analysis: CameraAnalysis) -> str:
    """Render the full analysis as markdown.

    Parameters
    ----------
    analysis : CameraAnalysis
        A completed analysis.

    Returns
    -------
    str
        Markdown document: offset table, read-noise table, derived
        quantities, and the recommendation section.
    """
    lines: list[str] = [
        "# ToupTek ATR2600C (IMX571) calibration",
        "",
        "Measured through PINS / ninaAPI on astrobit. Every gain value below is",
        "on the **ToupTek native percent scale** (100 = unity gain, 10000 = 100x).",
        "It is NOT the ZWO 0.1 dB scale, so numbers from SharpCap guides, ASI2600",
        "gain tables or forum posts about \"gain 100\" mean something different and",
        "must not be copied across.",
        "",
    ]

    if analysis.bit_shift_warnings:
        shift = max(analysis.bit_shift_warnings)
        lines += [
            "## WARNING: bit-shifted data detected",
            "",
            f"Every pixel value is divisible by {1 << shift}, i.e. the data was",
            f"left-shifted from {16 - shift} bits into a 16-bit container.",
            f"Every ADU-denominated result below is inflated by {1 << shift}x and",
            f"every e-/ADU result is deflated by {1 << shift}x. Divide ADU figures",
            f"by {1 << shift} to get true sensor ADU, or re-acquire in a native",
            "16-bit mode. Check Ultra Mode / High Fullwell Mode.",
            "",
        ]

    # -- offset table -------------------------------------------------------
    lines += [
        "## Offset calibration",
        "",
        "Adequate means: no pixel clipped at 0 ADU in *any* Bayer channel, and",
        "`median - 5*sigma > 0`. The recommendation is the **minimum** adequate",
        "offset. Higher is not better: every offset ADU is subtracted from the",
        "usable full well and costs dynamic range.",
        "",
        "| gain | offset | clipped px | clipped % | median | sigma (MAD) | med-5sig | verdict | channels clipping |",
        "|---:|---:|---:|---:|---:|---:|---:|:--|:--|",
    ]
    for result in sorted(analysis.bias, key=lambda r: (r.frameset.gain, r.frameset.offset)):
        stats = result.stats["global"]
        failing = ", ".join(result.failing_channels) or "-"
        lines.append(
            f"| {result.frameset.gain} | {result.frameset.offset} | "
            f"{stats.n_zero} | {stats.zero_fraction * 100:.4f} | "
            f"{stats.median:.1f} | {stats.sigma_mad:.2f} | {stats.headroom:.1f} | "
            f"{'OK' if result.adequate else 'TOO LOW'} | {failing} |"
        )

    lines += ["", "### Per-channel detail", ""]
    for result in sorted(analysis.bias, key=lambda r: (r.frameset.gain, r.frameset.offset)):
        lines += [
            f"**gain {result.frameset.gain}, offset {result.frameset.offset}, "
            f"readout {result.frameset.readout_mode}**",
            "",
            "| channel | clipped px | p0.001 | p0.01 | p0.1 | p1 | median | sigma (MAD) | sigma (std) |",
            "|:--|---:|---:|---:|---:|---:|---:|---:|---:|",
        ]
        for name in ("global", "R", "G1", "G2", "B"):
            stats = result.stats.get(name)
            if stats is None:
                continue
            pct = stats.percentiles
            lines.append(
                f"| {name} | {stats.n_zero} | {pct[0.001]:.1f} | {pct[0.01]:.1f} | "
                f"{pct[0.1]:.1f} | {pct[1.0]:.1f} | {stats.median:.1f} | "
                f"{stats.sigma_mad:.2f} | {stats.sigma_std:.2f} |"
            )
        lines.append("")

    # -- read noise ---------------------------------------------------------
    chosen = analysis.minimum_adequate_offset()
    curve = analysis.read_noise_curve(chosen)
    knee = analysis.detect_hcg_knee(curve)
    derived = analysis.derived_metrics()
    derived_by_gain = {d["gain"]: d for d in derived}

    lines += [
        "## Read noise and conversion gain",
        "",
        "Read noise from bias *pairs*: `sigma = std(b1 - b2) / sqrt(2)`.",
        "",
        "| gain | min adequate offset | sigma_read (ADU, MAD) | sigma_read (ADU, std) | e-/ADU | read noise (e-) | full well (e-) | DR (dB) |",
        "|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for gain, sigma_mad, sigma_std in curve:
        offset = chosen.get(gain)
        record = derived_by_gain.get(gain)
        offset_text = str(offset) if offset is not None else "NONE TESTED"
        if record is None:
            lines.append(
                f"| {gain} | {offset_text} | {sigma_mad:.2f} | {sigma_std:.2f} | "
                "- | - | - | - |"
            )
        else:
            lines.append(
                f"| {gain} | {offset_text} | {sigma_mad:.2f} | {sigma_std:.2f} | "
                f"{record['e_per_adu']:.4f} | {record['read_noise_e']:.2f} | "
                f"{record['full_well_e']:.0f} | {record['dynamic_range_db']:.1f} |"
            )
    lines.append("")

    if knee is not None:
        g0, g1, drop = knee
        lines += [
            "### HCG/LCG knee",
            "",
            f"Largest read-noise drop between adjacent gains: **{g0} -> {g1}**, a "
            f"{drop * 100:.1f}% fall.",
            "",
        ]
        if drop < 0.15:
            lines += [
                "That drop is small. A genuine dual-conversion-gain transition is",
                "usually 30-50%. This is more likely the ordinary fall of read",
                "noise in ADU with increasing analogue gain, not a knee. Widen the",
                "gain sweep around this region before believing it.",
                "",
            ]
        else:
            lines += [
                "That is large enough to be a genuine conversion-gain transition.",
                f"Operating just above gain {g1} buys the low-read-noise mode.",
                "",
            ]
    else:
        lines += [
            "### HCG/LCG knee",
            "",
            "Not detected: read noise never fell between adjacent gains, or fewer",
            "than two gains were measured.",
            "",
        ]

    # -- conversion gain per channel ---------------------------------------
    if analysis.gains:
        lines += [
            "## Conversion gain per Bayer channel",
            "",
            "| gain | global | R | G1 | G2 | B |",
            "|---:|---:|---:|---:|---:|---:|",
        ]
        for result in sorted(analysis.gains, key=lambda g: g.gain):
            cells = [
                f"{result.e_per_adu[name]:.4f}" if name in result.e_per_adu else "-"
                for name in ("global", "R", "G1", "G2", "B")
            ]
            lines.append(f"| {result.gain} | " + " | ".join(cells) + " |")
        lines.append("")

    # -- recommendation -----------------------------------------------------
    lines += ["## RECOMMENDATION", ""]

    adequate_gains = {g: o for g, o in chosen.items() if o is not None}
    if adequate_gains:
        worst = max(adequate_gains.values())
        lines += [
            f"- **Offset {worst}** covers every gain tested. If you change gain",
            "  between targets and do not want to re-tune offset, use this one",
            "  value; it is the maximum of the per-gain minima, so nothing clips.",
            "- Per-gain minima, if you would rather buy back the dynamic range:",
        ]
        for gain, offset in sorted(adequate_gains.items()):
            lines.append(f"  - gain {gain}: offset {offset}")
    else:
        lines += [
            "- **No tested offset was adequate at any gain.** Every candidate",
            "  clipped at least one Bayer channel. Re-run `--bias` with a higher",
            "  offset sweep, e.g. `CAMANA_OFFSETS=\"1000 1500 2000 3000 4000\"`.",
        ]

    lines += [
        "",
        "- Master bias, dark and flat libraries are only valid for the gain,",
        "  offset, readout mode and temperature they were taken at. Change any of",
        "  those four and the library is void.",
        "- Cooling must be on and settled for the numbers above to transfer to a",
        "  real session; read noise and, far more, dark current depend on it.",
        "- **Ultra Mode and High Fullwell Mode are not readable through the API.**",
        "  They change conversion gain and full well outright. Record their state",
        "  by hand alongside this report, or it cannot be reproduced.",
        "",
        "### The gain scale, again",
        "",
        "ToupTek native percent: 100 = unity, 10000 = 100x, range 100..10000.",
        "ZWO-derived advice ('gain 100 on the 2600MC') is on a 0.1 dB scale with a",
        "0..600 range and does not map onto this axis by any simple factor. Treat",
        "any number not measured on this camera as unusable.",
        "",
    ]
    return "\n".join(lines)


# --------------------------------------------------------------- self-test --


def _synthetic_bias(
    shape: tuple[int, int],
    offset: float,
    sigma_read_adu: float,
    rng: np.random.Generator,
) -> np.ndarray:
    """Generate one synthetic bias frame.

    Parameters
    ----------
    shape : tuple of int
        Frame shape ``(rows, cols)``.
    offset : float
        Pedestal level, ADU.
    sigma_read_adu : float
        Read noise to inject, ADU.
    rng : numpy.random.Generator
        Source of randomness.

    Returns
    -------
    numpy.ndarray
        Quantised, clipped frame, float64.
    """
    frame = rng.normal(offset, sigma_read_adu, size=shape)
    return np.clip(np.rint(frame), 0.0, ADU_MAX)


def _synthetic_flat(
    shape: tuple[int, int],
    offset: float,
    sigma_read_adu: float,
    signal_e: float,
    e_per_adu: float,
    prnu: np.ndarray,
    rng: np.random.Generator,
) -> np.ndarray:
    """Generate one synthetic flat frame with shot noise and PRNU.

    Parameters
    ----------
    shape : tuple of int
        Frame shape.
    offset : float
        Bias pedestal, ADU.
    sigma_read_adu : float
        Read noise, ADU.
    signal_e : float
        Mean signal, electrons.
    e_per_adu : float
        Conversion gain to simulate.
    prnu : numpy.ndarray
        Multiplicative pixel-response map, mean 1, same shape as `shape`.
        Fixed across the pair so that differencing cancels it, exactly as
        on real hardware.
    rng : numpy.random.Generator
        Source of randomness.

    Returns
    -------
    numpy.ndarray
        Quantised, clipped frame, float64.
    """
    electrons = rng.poisson(signal_e * prnu).astype(np.float64)
    frame = offset + electrons / e_per_adu + rng.normal(0.0, sigma_read_adu, size=shape)
    return np.clip(np.rint(frame), 0.0, ADU_MAX)


def run_selftest(seed: int = 20260920, verbose: bool = True) -> int:
    """Validate the estimators against synthetic frames with known truth.

    Parameters
    ----------
    seed : int, default 20260920
        RNG seed, so a failure is reproducible.
    verbose : bool, default True
        Print a per-check line to stdout.

    Returns
    -------
    int
        0 if every check passed, 1 otherwise.

    Notes
    -----
    This is the only part of the module that can be run on the dev box.  It
    proves the ``sqrt(2)``, the conversion-gain algebra, the Bayer
    de-interleaving and the bit-shift detector recover values that were put
    in deliberately -- before any of it is pointed at real frames where
    there is no ground truth to check against.
    """
    rng = np.random.default_rng(seed)
    shape = (512, 512)
    failures: list[str] = []

    def check(name: str, got: float, want: float, tol: float) -> None:
        """Record one tolerance check and report it."""
        rel = abs(got - want) / abs(want) if want else abs(got - want)
        ok = rel <= tol
        if not ok:
            failures.append(f"{name}: got {got:.6g}, want {want:.6g} (tol {tol:.1%})")
        if verbose:
            mark = "PASS" if ok else "FAIL"
            print(
                f"  [{mark}] {name:<46} got {got:12.5f}  want {want:12.5f}"
                f"  rel {rel * 100:6.2f}%"
            )

    if verbose:
        print("=== read noise from a bias pair (the sqrt(2)) ===")
    # 1.5 and 2.5 ADU are the cases that exposed the MAD quantisation
    # bias; keep them, they are the regime the HCG mode lives in.
    for truth in (1.5, 2.5, 8.0, 25.0):
        b1 = _synthetic_bias(shape, 600.0, truth, rng)
        b2 = _synthetic_bias(shape, 600.0, truth, rng)
        mad, std = read_noise_from_pair(b1, b2)
        check(f"sigma_read MAD, truth {truth} ADU", mad, truth, 0.03)
        check(f"sigma_read std, truth {truth} ADU", std, truth, 0.03)

    if verbose:
        print("\n=== a missing sqrt(2) would look like this ===")
    b1 = _synthetic_bias(shape, 600.0, 10.0, rng)
    b2 = _synthetic_bias(shape, 600.0, 10.0, rng)
    naive = float(np.std(b1 - b2))
    correct, _ = read_noise_from_pair(b1, b2)
    print(
        f"  [INFO] std(b1-b2) without /sqrt(2) = {naive:.3f} ADU, "
        f"{naive / correct:.3f}x the truth (sqrt(2) = {math.sqrt(2):.3f})"
    )

    if verbose:
        print("\n=== conversion gain from a flat pair ===")
    prnu = rng.normal(1.0, 0.01, size=shape)
    for e_per_adu, signal_e in ((0.25, 8000.0), (1.0, 20000.0), (3.5, 30000.0)):
        sigma_adu = 5.0
        bias_a = _synthetic_bias(shape, 800.0, sigma_adu, rng)
        bias_b = _synthetic_bias(shape, 800.0, sigma_adu, rng)
        flat_a = _synthetic_flat(
            shape, 800.0, sigma_adu, signal_e, e_per_adu, prnu, rng
        )
        flat_b = _synthetic_flat(
            shape, 800.0, sigma_adu, signal_e, e_per_adu, prnu, rng
        )
        got, signal, _ = conversion_gain(flat_a, flat_b, bias_a, bias_b)
        check(f"e-/ADU, truth {e_per_adu}", got, e_per_adu, 0.05)
        check(
            f"signal level at e-/ADU {e_per_adu}",
            signal,
            signal_e / e_per_adu,
            0.02,
        )

    if verbose:
        print("\n=== Bayer de-interleaving (RGGB, offsets 0,0) ===")
    marker = np.zeros((8, 8), dtype=np.float64)
    marker[0::2, 0::2] = 10.0  # R
    marker[0::2, 1::2] = 20.0  # G1
    marker[1::2, 0::2] = 30.0  # G2
    marker[1::2, 1::2] = 40.0  # B
    planes = bayer_planes(marker, "RGGB")
    for name, want in (("R", 10.0), ("G1", 20.0), ("G2", 30.0), ("B", 40.0)):
        check(f"RGGB plane {name}", float(np.mean(planes[name])), want, 1e-9)

    if verbose:
        print("\n=== per-channel offset verdict (B deliberately clipped) ===")
    cfa = np.empty(shape, dtype=np.float64)
    cfa[0::2, 0::2] = _synthetic_bias((256, 256), 500.0, 6.0, rng)  # R, fine
    cfa[0::2, 1::2] = _synthetic_bias((256, 256), 500.0, 6.0, rng)  # G1, fine
    cfa[1::2, 0::2] = _synthetic_bias((256, 256), 500.0, 6.0, rng)  # G2, fine
    cfa[1::2, 1::2] = _synthetic_bias((256, 256), 3.0, 6.0, rng)  # B, clipped
    stats_global = channel_stats(cfa, "global")
    per_channel = {n: channel_stats(p, n) for n, p in bayer_planes(cfa, "RGGB").items()}
    b_clipped = per_channel["B"].n_zero > 0
    r_clean = per_channel["R"].n_zero == 0
    global_pct = stats_global.zero_fraction * 100.0
    print(
        f"  [{'PASS' if b_clipped and r_clean else 'FAIL'}] "
        f"B clips ({per_channel['B'].n_zero} px) while R does not "
        f"({per_channel['R'].n_zero} px); global clipped fraction only "
        f"{global_pct:.3f}%"
    )
    if not (b_clipped and r_clean):
        failures.append("per-channel clipping detection did not isolate B")
    if per_channel["R"].adequate and not per_channel["B"].adequate:
        print("  [PASS] verdict: R adequate, B inadequate - per-channel check works")
    else:
        failures.append("per-channel adequacy verdict wrong")
        print("  [FAIL] per-channel adequacy verdict wrong")

    if verbose:
        print("\n=== bit-shift detection ===")
    native = _synthetic_bias(shape, 600.0, 8.0, rng)
    for shift in (0, 2, 4):
        probe = native * (1 << shift) if shift else native
        got_shift = detect_bit_shift(probe)
        ok = got_shift == shift
        if not ok:
            failures.append(f"bit-shift detect: got {got_shift}, want {shift}")
        print(
            f"  [{'PASS' if ok else 'FAIL'}] "
            f"{16 - shift}-bit data in 16-bit container -> shift {got_shift} "
            f"(want {shift})"
        )

    if verbose:
        print("\n=== HCG knee detection (synthetic 40% step at 1000->1500) ===")
    synth_curve = [
        (100, 12.0, 12.1),
        (200, 11.0, 11.1),
        (500, 10.2, 10.3),
        (1000, 9.8, 9.9),
        (1500, 5.9, 6.0),
        (3000, 5.5, 5.6),
    ]
    knee = CameraAnalysis.detect_hcg_knee(synth_curve)
    ok = knee is not None and knee[0] == 1000 and knee[1] == 1500
    if not ok:
        failures.append(f"HCG knee: got {knee}, want (1000, 1500, ~0.40)")
    print(
        f"  [{'PASS' if ok else 'FAIL'}] knee at {knee[0]}->{knee[1]} "
        f"({knee[2] * 100:.1f}% drop)"
        if knee
        else "  [FAIL] no knee found"
    )

    if verbose:
        print("\n=== derived quantities from known inputs ===")
    sigma_adu, e_per_adu, median = 4.0, 0.8, 500.0
    read_e = sigma_adu * e_per_adu
    full_well = (ADU_MAX - median) * e_per_adu
    dr_db = 20.0 * math.log10(full_well / read_e)
    check("read noise in electrons", read_e, 3.2, 1e-9)
    check("full well (e-)", full_well, (65535.0 - 500.0) * 0.8, 1e-9)
    check("dynamic range (dB)", dr_db, 20.0 * math.log10(full_well / read_e), 1e-9)

    print()
    if failures:
        print(f"SELFTEST FAILED: {len(failures)} check(s)")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print("SELFTEST PASSED: every estimator recovered its known input.")
    return 0


# -------------------------------------------------------------------- CLI --


def _build_parser() -> argparse.ArgumentParser:
    """Construct the command-line parser.

    Returns
    -------
    argparse.ArgumentParser
        Configured parser.
    """
    parser = argparse.ArgumentParser(
        prog="camera_analysis.py",
        description=(
            "Analyse ToupTek ATR2600C bias and flat frames acquired by "
            "camera-analysis.sh: offset adequacy per Bayer channel, read "
            "noise, conversion gain, and the plots and report."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Exit codes: 0 success, 1 analysis error, 2 bad usage, "
            "3 self-test failure."
        ),
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        help="JSON manifest written by camera-analysis.sh",
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=Path("analysis-out"),
        help="where PNGs and the markdown report land (default: analysis-out)",
    )
    parser.add_argument(
        "--pattern",
        default="RGGB",
        choices=sorted(BAYER_PATTERNS),
        help="CFA pattern; the ATR2600C reports RGGB (default: RGGB)",
    )
    parser.add_argument(
        "--no-plots",
        action="store_true",
        help="numbers and report only, no figures",
    )
    parser.add_argument(
        "--show",
        action="store_true",
        help="display figures interactively; needs a display (ssh -X)",
    )
    parser.add_argument(
        "--selftest",
        "--dry-run",
        dest="selftest",
        action="store_true",
        help="validate the estimators on synthetic frames and exit",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=20260920,
        help="RNG seed for --selftest (default: 20260920)",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="debug logging",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """Command-line entry point.

    Parameters
    ----------
    argv : sequence of str, optional
        Arguments; defaults to ``sys.argv[1:]``.

    Returns
    -------
    int
        Process exit code: 0 success, 1 analysis error, 2 bad usage,
        3 self-test failure.
    """
    parser = _build_parser()
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)-7s %(message)s",
    )

    if args.selftest:
        print("camera_analysis.py self-test: synthetic frames, known truth\n")
        return 3 if run_selftest(seed=args.seed) else 0

    if args.manifest is None:
        parser.error("--manifest is required unless --selftest is given")

    try:
        framesets = CameraAnalysis.framesets_from_manifest(args.manifest)
        analysis = CameraAnalysis(
            pattern=args.pattern, keep_samples=not args.no_plots
        )
        analysis.analyse_bias(framesets)
        analysis.analyse_flats(framesets)

        if not analysis.bias:
            msg = "the manifest holds no bias frames; nothing to calibrate"
            raise InsufficientDataError(msg)

        out_dir: Path = args.out_dir
        out_dir.mkdir(parents=True, exist_ok=True)

        if not args.no_plots:
            plot_bias_histograms(analysis.bias, out_dir, args.pattern, args.show)
            plot_offset_sweep(analysis.bias, out_dir, args.show)
            chosen = analysis.minimum_adequate_offset()
            curve = analysis.read_noise_curve(chosen)
            plot_read_noise(
                curve,
                analysis.detect_hcg_knee(curve),
                analysis.derived_metrics(),
                out_dir,
                args.show,
            )
            plot_photon_transfer(analysis.gains, out_dir, args.show)

        report = build_report(analysis)
        report_path = out_dir / "calibration-report.md"
        report_path.write_text(report)
        print(report)
        print(f"\n(report written to {report_path})")
    except CameraAnalysisError as err:
        log.error("%s", err)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
