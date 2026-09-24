"""Reference implementation of the SleepStagerV3 per-epoch features.

This file is the definition the Swift port (`Packages/StrandAnalytics/.../SleepStagerV3.swift`) is pinned
against: `make_oracle.py` runs it over synthetic nights and writes the expected values into the Swift test
fixture. It is plain numpy on purpose, with every reduction spelled out, so each line has a direct Swift
counterpart. No pandas or scipy semantics are relied on.

Inputs are exactly what the app hands a stager, restricted to one night's staging span:
  grav  (m, 4) rows of (ts, x, y, z): per-second gravity in g
  hr    (m, 2) rows of (ts, bpm): 1 Hz heart rate, integer bpm, <= 0 means no reading
  rr    (m, 2) rows of (ts, rrMs): beat-to-beat intervals stamped with the whole second of the beat
The span is `n` 30 s epochs starting at `span_start` (seconds). Only samples inside
[span_start, span_start + 30 n) are read, so a feature never depends on data the span does not own.
"""
import numpy as np

EPOCH_S = 30
MOVE_MULT = 38.0            # a per-second jerk counts as movement above night floor x this (V2's constant)
MOVE_COUNT_INIT = 60        # epochs assumed since/until movement at the span edges
MOVE_COUNT_CAP = 120
CTX = (2, 5, 10, 20)        # +- epochs of motion context
HRSD = ((150, "5"), (330, "11"), (600, "20"))  # HR std half-windows (s) around the epoch centre
HRSD_MIN = 10               # more than this many present seconds for an HR std
HR_CTX = (5, 10, 30)
HR_TREND = 10
MINUTES_CAP = 720.0         # elapsed-time feature stops growing after 12 h, the longest night trained on
TIME_DECAYS = (10, 30, 90)  # minutes: exp(-t / tau) curves that let a linear head learn the sleep-onset descent
HRV_HALF = 150              # 5-min centred beat window
HRV_MIN_BEATS = 20
SPEC_MIN_BEATS = 30
SPEC_MIN_SPAN = 120.0
DFA_MIN_BEATS = 64
HRV_CTX = 10
RESAMPLE_HZ = 4.0
NPERSEG = 256
LF = (0.04, 0.15)
HF = (0.15, 0.40)

MOTION = ["act_mean", "act_max", "move_frac", "since_move", "until_move"] + [f"act_ctx{w}" for w in CTX]
POSTURE = ["dangn"] + [f"dangn_ctx{w}" for w in CTX]
BASE = (MOTION + POSTURE + ["hr_z", "hr_pct"] +
        [f"hrsd{name}_{k}" for _, name in HRSD for k in ("pct", "z")] + [f"hr_ctx{w}_z" for w in HR_CTX] +
        ["hr_trend", "hr_over_low", "clock", "minutes"] + [f"time_e{tau}" for tau in TIME_DECAYS])
HRV_NAMES = ["meanNN", "sdnn", "lnrmssd", "pnn50", "lnlf", "lnhf", "lnlfhf", "resp_bpm", "hf_peaked", "dfa_a1",
             "beats_per_min"]
HRV = [f"hrv_{name}_{k}" for name in HRV_NAMES for k in ("r", "ctx")]


# ---------------------------------------------------------------------------------------------- reductions
# Every sum is taken left to right (numpy's `sum` is pairwise), so the Swift port's plain loops reproduce it
# to the last bit wherever no transcendental function intervenes.

def seqsum(x):
    return np.cumsum(x)[-1] if x.size else 0.0


def rowsum(a):
    return np.cumsum(a, axis=1)[:, -1]


def nanmean(x):
    x = x[~np.isnan(x)]
    return seqsum(x) / x.size if x.size else np.nan


def nanstd(x):
    """Population standard deviation over the present values."""
    x = x[~np.isnan(x)]
    if not x.size:
        return np.nan
    m = seqsum(x) / x.size
    return np.sqrt(seqsum((x - m) ** 2) / x.size)


def median(x):
    s = np.sort(x[~np.isnan(x)])
    if not s.size:
        return np.nan
    h = s.size // 2
    return s[h] if s.size % 2 else 0.5 * (s[h - 1] + s[h])


def percentile(x, q):
    """Linear-interpolation percentile over the present values (numpy's default method)."""
    s = np.sort(x[~np.isnan(x)])
    if not s.size:
        return np.nan
    pos = q / 100.0 * (s.size - 1)
    lo = int(np.floor(pos))
    hi = min(lo + 1, s.size - 1)
    return s[lo] + (pos - lo) * (s[hi] - s[lo])


def zscore(x):
    m, sd = nanmean(x), nanstd(x)
    if np.isnan(m):
        return np.full_like(x, np.nan)
    return (x - m) / (sd if sd > 0 else 1.0)


def pct_rank(x):
    """Percentile rank of each present value: average rank of its ties (1-based) / count present."""
    ok = ~np.isnan(x)
    v = x[ok]
    out = np.full_like(x, np.nan)
    if not v.size:
        return out
    s = np.sort(v)
    below = np.searchsorted(s, v, side="left")
    through = np.searchsorted(s, v, side="right")
    out[ok] = (below + (through - below + 1) / 2.0) / v.size
    return out


def centred_mean(x, w):
    """Mean of the present values in [i - w, i + w], clipped to the span; NaN when none is present."""
    n = x.size
    ok = ~np.isnan(x)
    cs = np.concatenate([[0.0], np.cumsum(np.where(ok, x, 0.0))])
    cc = np.concatenate([[0], np.cumsum(ok)])
    lo = np.clip(np.arange(n) - w, 0, n)
    hi = np.clip(np.arange(n) + w + 1, 0, n)
    cnt = cc[hi] - cc[lo]
    with np.errstate(invalid="ignore", divide="ignore"):
        return np.where(cnt > 0, (cs[hi] - cs[lo]) / np.maximum(cnt, 1), np.nan)


def robust(x):
    """Per-night scaling to the 5th-95th percentile range."""
    lo, hi = percentile(x, 5), percentile(x, 95)
    if np.isnan(lo):
        return np.full_like(x, np.nan)
    return (x - lo) / (hi - lo if hi > lo else 1.0)


# ------------------------------------------------------------------------------------------ per-second grid

def per_second(span_start, n, grav, hr):
    S = EPOCH_S * n
    g = np.full((S, 3), np.nan)
    if len(grav):
        idx = grav[:, 0].astype(np.int64) - span_start
        ok = (idx >= 0) & (idx < S)
        cnt = np.bincount(idx[ok], minlength=S)
        for j in range(3):
            s = np.bincount(idx[ok], weights=grav[ok, j + 1], minlength=S)
            g[:, j] = np.where(cnt > 0, s / np.maximum(cnt, 1), np.nan)
    h = np.full(S, np.nan)
    if len(hr):
        idx = hr[:, 0].astype(np.int64) - span_start
        ok = (idx >= 0) & (idx < S) & (hr[:, 1] > 0)
        cnt = np.bincount(idx[ok], minlength=S)
        s = np.bincount(idx[ok], weights=hr[ok, 1].astype(float), minlength=S)
        h = np.where(cnt > 0, s / np.maximum(cnt, 1), np.nan)
    return g, h


def beat_times(rr, span_start, n):
    """Beats inside the span as (time, interval ms). A second that carries c beats places them at
    ts + j / c in their stored order, so times are strictly increasing."""
    if not len(rr):
        return np.zeros(0), np.zeros(0)
    ts = rr[:, 0].astype(np.int64)
    order = np.argsort(ts, kind="stable")
    ts, v = ts[order], rr[order, 1].astype(float)
    keep = (ts >= span_start) & (ts < span_start + EPOCH_S * n)
    ts, v = ts[keep], v[keep]
    t = (ts - span_start).astype(float)
    i = 0
    while i < ts.size:
        j = i
        while j + 1 < ts.size and ts[j + 1] == ts[i]:
            j += 1
        c = j - i + 1
        t[i:j + 1] = float(ts[i] - span_start) + np.arange(c) / c
        i = j + 1
    return t, v


def clean_beats(t, rr):
    """Drop impossible intervals, then any more than 20 % away from the median of its 11-beat neighbourhood."""
    ok = (rr >= 300) & (rr <= 2000)
    t, rr = t[ok], rr[ok]
    if rr.size < 5:
        return t, rr
    med = np.array([median(rr[max(0, i - 5): i + 6]) for i in range(rr.size)])
    ok = np.abs(rr - med) <= 0.2 * med
    return t[ok], rr[ok]


# ------------------------------------------------------------------------------------------------- HRV

def linear_detrend(x, y):
    xm, ym = seqsum(x) / x.size, seqsum(y) / y.size
    sxx = seqsum((x - xm) ** 2)
    slope = seqsum((x - xm) * (y - ym)) / sxx if sxx > 0 else 0.0
    return y - (ym + slope * (x - xm))


def welch_psd(y):
    """Welch power spectral density: Hann (periodic) windows of NPERSEG samples, 50 % overlap, each segment
    mean-removed, one-sided density, averaged. Same definition as scipy.signal.welch's defaults."""
    step = NPERSEG // 2
    nseg = (y.size - NPERSEG) // step + 1
    k = np.arange(NPERSEG)
    w = 0.5 - 0.5 * np.cos(2 * np.pi * k / NPERSEG)
    p = np.zeros(NPERSEG // 2 + 1)
    for s in range(nseg):
        seg = y[s * step: s * step + NPERSEG]
        seg = seg - seqsum(seg) / NPERSEG
        p += np.abs(np.fft.rfft(seg * w)) ** 2
    p *= 1.0 / (RESAMPLE_HZ * seqsum(w ** 2) * nseg)
    p[1:-1] *= 2.0
    return np.arange(NPERSEG // 2 + 1) * RESAMPLE_HZ / NPERSEG, p


def band_power(f, p, lo, hi):
    m = (f >= lo) & (f < hi)
    ff, pp = f[m], p[m]
    return seqsum((ff[1:] - ff[:-1]) * (pp[1:] + pp[:-1]) / 2.0)


def spectral(t, rr):
    """(lf, hf, hf peak frequency, hf peakedness) of the 4 Hz resampled, linearly detrended tachogram."""
    if rr.size < SPEC_MIN_BEATS or t[-1] - t[0] < SPEC_MIN_SPAN:
        return (np.nan,) * 4
    m = int(np.ceil((t[-1] - t[0]) * RESAMPLE_HZ))
    g = t[0] + np.arange(m) / RESAMPLE_HZ
    y = linear_detrend(g - t[0], np.interp(g, t, rr))
    f, p = welch_psd(y)
    lf, hf = band_power(f, p, *LF), band_power(f, p, *HF)
    m = (f >= HF[0]) & (f < HF[1])
    ph = p[m]
    peak = f[m][int(np.argmax(ph))]
    total = seqsum(ph)
    return lf, hf, peak, (ph.max() / total if total > 0 else np.nan)


def dfa_alpha1(rr):
    x = np.cumsum(rr - seqsum(rr) / rr.size)
    scales = np.arange(4, 17)
    F = []
    for n in scales:
        k = x.size // n
        if k < 2:
            return np.nan
        seg = x[: k * n].reshape(k, n)
        i = np.arange(n, dtype=float)
        im = (n - 1) / 2.0
        sm = (rowsum(seg) / n)[:, None]
        slope = (rowsum((i - im) * (seg - sm)) / seqsum((i - im) ** 2))[:, None]
        res = seg - sm - slope * (i - im)
        F.append(seqsum(np.sqrt(rowsum(res ** 2) / n)) / k)
    F = np.array(F)
    if np.any(F <= 0):
        return np.nan
    lx, ly = np.log(scales.astype(float)), np.log(F)
    lxm, lym = seqsum(lx) / lx.size, seqsum(ly) / ly.size
    return seqsum((lx - lxm) * (ly - lym)) / seqsum((lx - lxm) ** 2)


def epoch_hrv(t, rr, n):
    """Raw HRV measures per epoch over the 5-min window centred on it, and the beat count per window."""
    out = np.full((n, len(HRV_NAMES)), np.nan)
    count = np.zeros(n, dtype=int)
    for e in range(n):
        c = EPOCH_S * e + EPOCH_S / 2
        a, b = np.searchsorted(t, c - HRV_HALF, "left"), np.searchsorted(t, c + HRV_HALF, "left")
        tt, x = t[a:b], rr[a:b]
        count[e] = x.size
        if x.size < HRV_MIN_BEATS:
            continue
        d = np.diff(x)
        rmssd = np.sqrt(seqsum(d ** 2) / d.size)
        lf, hf, peak, peaked = spectral(tt, x)
        out[e] = [seqsum(x) / x.size, nanstd(x), np.log(rmssd + 1e-6), np.count_nonzero(np.abs(d) > 50) / d.size,
                  np.log(lf + 1e-6), np.log(hf + 1e-6),
                  np.log(lf / hf + 1e-9) if hf > 0 else np.nan,
                  peak * 60.0, peaked,
                  dfa_alpha1(x) if x.size >= DFA_MIN_BEATS else np.nan,
                  x.size / (2 * HRV_HALF) * 60.0]
    return out, count


# ------------------------------------------------------------------------------------------ the features

def features(grav, hr, rr, span_start, n):
    """Every V3 feature for the n epochs of the span, as {name: array(n)} (NaN = no measurement), plus
    `beats` = beat count in each epoch's 5-min HRV window (the HRV head's coverage test)."""
    grav = np.asarray(grav, float).reshape(-1, 4)
    hr = np.asarray(hr, float).reshape(-1, 2)
    rr = np.asarray(rr, float).reshape(-1, 2)
    S = EPOCH_S * n
    g, h = per_second(span_start, n, grav, hr)
    F = {}

    # motion: per-second gravity jerk relative to the night's own floor
    jerk = np.full(S, np.nan)
    if S > 1:
        d = g[1:] - g[:-1]
        jerk[1:] = np.sqrt(d[:, 0] * d[:, 0] + d[:, 1] * d[:, 1] + d[:, 2] * d[:, 2])
    floor = median(jerk)
    floor = floor if floor > 0 else 1e-6
    rel = jerk / floor
    ljerk = np.log1p(np.where(np.isnan(rel), 0.0, rel))
    moving = np.where(np.isnan(rel), 0.0, (rel > MOVE_MULT).astype(float))
    F["act_mean"] = rowsum(ljerk.reshape(n, EPOCH_S)) / EPOCH_S
    F["act_max"] = ljerk.reshape(n, EPOCH_S).max(axis=1)
    F["move_frac"] = rowsum(moving.reshape(n, EPOCH_S)) / EPOCH_S
    mv = F["move_frac"] > 0
    since, until = np.zeros(n), np.zeros(n)
    c = MOVE_COUNT_INIT
    for i in range(n):
        c = 0 if mv[i] else min(c + 1, MOVE_COUNT_CAP)
        since[i] = c
    c = MOVE_COUNT_INIT
    for i in range(n - 1, -1, -1):
        c = 0 if mv[i] else min(c + 1, MOVE_COUNT_CAP)
        until[i] = c
    F["since_move"], F["until_move"] = np.log1p(since), np.log1p(until)
    for w in CTX:
        F[f"act_ctx{w}"] = centred_mean(F["act_mean"], w)
    # No jerk anywhere in the span (no gravity, or none in two consecutive seconds) is no motion measurement:
    # its columns are missing, not the stillest night the model ever saw.
    if np.all(np.isnan(jerk)):
        for k in MOTION:
            F[k] = np.full(n, np.nan)

    # posture: change of the z-angle between 5 s block means, relative to the night's median change
    ang = np.arctan2(g[:, 2], np.sqrt(g[:, 0] * g[:, 0] + g[:, 1] * g[:, 1])) * (180.0 / np.pi)
    blocks = np.array([nanmean(ang[5 * j: 5 * j + 5]) for j in range(S // 5)])
    dblk = np.zeros(blocks.size)
    if blocks.size > 1:
        d = np.abs(blocks[1:] - blocks[:-1])
        dblk[1:] = np.where(np.isnan(d), 0.0, d)
    dang = rowsum(dblk.reshape(n, EPOCH_S // 5))
    med = median(dang)
    F["dangn"] = np.log1p(dang / (med if med > 0 else 1e-6))
    for w in CTX:
        F[f"dangn_ctx{w}"] = centred_mean(F["dangn"], w)
    # Likewise no two consecutive blocks with gravity is no posture measurement.
    if blocks.size < 2 or np.all(np.isnan(blocks[1:] - blocks[:-1])):
        for k in POSTURE:
            F[k] = np.full(n, np.nan)

    # heart rate
    ehr = np.array([nanmean(h[EPOCH_S * e: EPOCH_S * e + EPOCH_S]) for e in range(n)])
    F["hr_z"], F["hr_pct"] = zscore(ehr), pct_rank(ehr)
    for half, name in HRSD:
        sd = np.full(n, np.nan)
        for e in range(n):
            c = EPOCH_S * e + EPOCH_S // 2
            win = h[max(0, c - half): c + half]
            if np.count_nonzero(~np.isnan(win)) > HRSD_MIN:
                sd[e] = nanstd(win)
        F[f"hrsd{name}_pct"], F[f"hrsd{name}_z"] = pct_rank(sd), zscore(sd)
    for w in HR_CTX:
        F[f"hr_ctx{w}_z"] = zscore(centred_mean(ehr, w))
    trend = np.zeros(n)
    for e in range(1, n):
        trend[e] = nanmean(ehr[e: e + HR_TREND]) - nanmean(ehr[max(0, e - HR_TREND): e])
    F["hr_trend"] = zscore(trend)
    sd = nanstd(ehr)
    F["hr_over_low"] = (ehr - percentile(ehr, 5)) / (sd if sd > 1e-6 else 1e-6)

    # time of night
    F["clock"] = np.arange(n) / max(1, n - 1)
    F["minutes"] = np.minimum(np.arange(n) * (EPOCH_S / 60.0), MINUTES_CAP)
    # A linear head reads `minutes` as a straight line, which cannot say "little deep in the first 20 minutes,
    # then plenty" or "no REM for the first hour"; these decays can. Without them the model staged deep within
    # 5 min of onset on 37 of 88 Wearanize+ nights (PSG: 0).
    for tau in TIME_DECAYS:
        F[f"time_e{tau}"] = np.exp(-F["minutes"] / tau)

    # heart-rate variability from the beat stream
    t, v = beat_times(rr, span_start, n)
    t, v = clean_beats(t, v)
    H, count = epoch_hrv(t, v, n)
    for j, name in enumerate(HRV_NAMES):
        r = robust(H[:, j])
        F[f"hrv_{name}_r"] = r
        F[f"hrv_{name}_ctx"] = centred_mean(r, HRV_CTX)
    F["beats"] = count.astype(float)
    return F


def impute(F, names, absent=None):
    """Model input matrix: each feature's missing values take that night's median of the feature, so a gap
    reads as typical for the night, not as extreme. A feature missing all night takes `absent[j]`, the head's
    training mean, so it standardises to 0 (`Head.posteriors` passes it). Fitting passes none and would fill 0,
    but no training night has a whole-night gap in a column its head reads."""
    X = np.empty((F[names[0]].size, len(names)))
    for j, name in enumerate(names):
        x = F[name].astype(float).copy()
        m = median(x)
        x[np.isnan(x)] = (0.0 if absent is None else absent[j]) if np.isnan(m) else m
        X[:, j] = x
    return X
