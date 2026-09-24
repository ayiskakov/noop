"""The on-disk night format every SleepTrain step shares, and the band-window emulation.

A prepared cohort is a directory of per-night CSV files, all timed in whole seconds from the night's first
PSG epoch (`ts` 0 = the start of truth epoch 0; earlier samples have negative `ts`):

  {id}_grav.csv    ts,x,y,z      per-second gravity (g)
  {id}_hr.csv      ts,bpm        heart rate, integer bpm
  {id}_rr.csv      ts,rr         beat-to-beat intervals (ms), stamped with the beat's whole second
  {id}_truth.csv   truth         one PSG label per 30 s epoch: wake, light, deep, rem, or none (unscored)
  {id}_truth2.csv  truth         optional second scorer, same grid

That is the shape the app hands `SleepStagerV3`, so training reads exactly what the stager will read. The
`Tools/SleepPSG` replay reads the same files.
"""
import csv
import os
import numpy as np

STAGES = ["wake", "light", "deep", "rem"]
SI = {s: i for i, s in enumerate(STAGES)}

# SleepStager.bandSleepWindow: a persistent run is 10 consecutive asleep epochs; the window keeps 10 epochs of
# grace before the first run and after the last.
BAND_PERSIST = 10
BAND_GRACE = 10


class Night:
    def __init__(self, sid, cohort, grav, hr, rr, truth, truth2=None):
        self.sid, self.cohort = sid, cohort
        self.grav, self.hr, self.rr = grav, hr, rr
        self.truth = truth
        self.truth2 = truth2

    def scored_span(self):
        """First and one-past-last scored epoch."""
        idx = [i for i, t in enumerate(self.truth) if t is not None]
        return idx[0], idx[-1] + 1


def _read(path, cols):
    if not os.path.exists(path):
        return np.zeros((0, cols))
    with open(path) as f:
        rows = f.read().split("\n")[1:]
    rows = [r for r in rows if r]
    if not rows:
        return np.zeros((0, cols))
    return np.array([[float(v) for v in r.split(",")] for r in rows]).reshape(-1, cols)


def _labels(path):
    if not os.path.exists(path):
        return None
    with open(path) as f:
        rows = list(csv.reader(f))[1:]
    return [None if r[0] == "none" else r[0] for r in rows]


def load_dir(path, cohort=None):
    cohort = cohort or os.path.basename(os.path.normpath(path))
    ids = sorted(f[: -len("_truth.csv")] for f in os.listdir(path) if f.endswith("_truth.csv"))
    out = []
    for sid in ids:
        p = os.path.join(path, sid)
        out.append(Night(sid, cohort, _read(p + "_grav.csv", 4), _read(p + "_hr.csv", 2), _read(p + "_rr.csv", 2),
                         _labels(p + "_truth.csv"), _labels(p + "_truth2.csv")))
    return out


def write_night(path, sid, grav, hr, rr, truth, truth2=None):
    """grav (m, 4) float, hr (m, 2), rr (m, 2); ts already relative to truth epoch 0."""
    os.makedirs(path, exist_ok=True)
    p = os.path.join(path, sid)
    with open(p + "_grav.csv", "w") as f:
        f.write("ts,x,y,z\n")
        for t, x, y, z in grav:
            f.write(f"{int(t)},{float(x)!r},{float(y)!r},{float(z)!r}\n")
    with open(p + "_hr.csv", "w") as f:
        f.write("ts,bpm\n")
        for t, b in hr:
            f.write(f"{int(t)},{int(b)}\n")
    with open(p + "_rr.csv", "w") as f:
        f.write("ts,rr\n")
        for t, v in rr:
            f.write(f"{int(t)},{int(v)}\n")
    for suffix, labels in (("_truth.csv", truth), ("_truth2.csv", truth2)):
        if labels is None:
            continue
        with open(p + suffix, "w") as f:
            f.write("truth\n")
            for s in labels:
                f.write(f"{s or 'none'}\n")


def band_window(asleep):
    """Emulate SleepStager.bandSleepWindow on a per-epoch asleep flag: [first persistent run - grace,
    last persistent run + grace] as a half-open epoch range, or None when no run is persistent."""
    n = len(asleep)
    run, onset = 0, None
    for i in range(n):
        run = run + 1 if asleep[i] else 0
        if run >= BAND_PERSIST:
            onset = i - BAND_PERSIST + 1
            break
    run, final = 0, None
    for i in range(n - 1, -1, -1):
        run = run + 1 if asleep[i] else 0
        if run >= BAND_PERSIST:
            final = i + BAND_PERSIST - 1
            break
    if onset is None or final is None or onset > final:
        return None
    return max(0, onset - BAND_GRACE), min(n, final + BAND_GRACE + 1)
