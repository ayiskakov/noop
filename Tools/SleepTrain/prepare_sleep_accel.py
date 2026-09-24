#!/usr/bin/env python3
"""PhysioNet sleep-accel v1.0.0 (Walch et al., SLEEP 2019; ODC-By 1.0) -> the SleepTrain night format.

    python3 prepare_sleep_accel.py <extracted sleep-accel root> <out dir>

Same mapping as Tools/SleepPSG/Sources/sleeppsg/SleepAccel.swift: per-second mean of the raw accelerometer
as gravity, heart rate at its own (sparse) sample times, no R-R (the dataset has none), labels on the PSG
30 s grid with N1+N2 -> light and N3+N4 -> deep. Samples within 30 minutes either side of the scored span
are kept.
"""
import os
import sys
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sleeptrain.data import write_night  # noqa: E402

CODE = {0: "wake", 1: "light", 2: "light", 3: "deep", 4: "deep", 5: "rem"}
PAD = 1800


def main(root, out):
    ids = sorted(f.split("_")[0] for f in os.listdir(f"{root}/labels") if f.endswith("_labeled_sleep.txt"))
    for sid in ids:
        lab = np.loadtxt(f"{root}/labels/{sid}_labeled_sleep.txt", ndmin=2)
        scored = [(int(round(t / 30.0)) * 30, CODE.get(int(round(c)))) for t, c in lab]
        scored = [(t, s) for t, s in scored if s is not None]
        t0, t1 = scored[0][0], scored[-1][0] + 30
        truth = [None] * ((t1 - t0) // 30)
        for t, s in scored:
            truth[(t - t0) // 30] = s
        lo, hi = t0 - PAD, t1 + PAD
        m = np.loadtxt(f"{root}/motion/{sid}_acceleration.txt", ndmin=2)
        sec = np.floor(m[:, 0]).astype(np.int64)
        keep = (sec >= lo) & (sec < hi)
        sec, m = sec[keep], m[keep]
        u, inv = np.unique(sec, return_inverse=True)
        cnt = np.bincount(inv)
        g = np.stack([np.bincount(inv, weights=m[:, j]) / cnt for j in (1, 2, 3)], axis=1)
        grav = np.column_stack([u - t0, g])
        h = np.loadtxt(f"{root}/heart_rate/{sid}_heartrate.txt", delimiter=",", ndmin=2)
        hs = np.floor(h[:, 0]).astype(np.int64)
        bpm = np.round(h[:, 1])
        keep = (hs >= lo) & (hs < hi) & (bpm > 0) & (bpm < 300)
        hr = np.column_stack([hs[keep] - t0, bpm[keep]])
        hr = hr[np.argsort(hr[:, 0], kind="stable")]
        write_night(out, sid, grav, hr, np.zeros((0, 2)), truth)
        print(sid, len(truth), "epochs", flush=True)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
