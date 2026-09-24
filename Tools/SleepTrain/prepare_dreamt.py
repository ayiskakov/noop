#!/usr/bin/env python3
"""DREAMT v2.2.0 `data_64Hz` (PhysioNet, Restricted Health Data License 1.5.0) -> the SleepTrain night format.

    python3 prepare_dreamt.py <data_64Hz dir> <out dir>

DREAMT is used as an INDEPENDENT TEST cohort only (sleep-clinic patients on an Empatica E4), never as training
data for the shipped model: its licence limits use to scientific research. Access needs a PhysioNet account and
the signed data use agreement; the files must stay on the machine that downloaded them.

Each `S###_whole_df.csv` is the E4 merged onto a 64 Hz grid with the PSG label per row. The first PSG-scored
row starts epoch 0; stages W / N1 / N2 / N3 / R map to wake / light / light / deep / rem, and an epoch takes
the label at its midpoint. Gravity is the per-second mean of ACC / 64 g, HR the per-second mean of the E4's
1 Hz HR. The E4 IBI column is forward-filled, so a beat shows only as a CHANGE of value: consecutive equal
intervals merge into one run, and a run whose length is (k - 1) * v + v_next (within 50 ms) hides k - 1 beats
of value v. Any other run length is a detection gap. Incomplete (still downloading) files are skipped.
"""
import os
import sys
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sleeptrain.data import write_night  # noqa: E402

MAP = {"W": "wake", "N1": "light", "N2": "light", "N3": "deep", "R": "rem"}
PAD = 1800


def beats(ts, ibi):
    c = np.nonzero(~np.isnan(ibi[1:]) & ((ibi[1:] != ibi[:-1]) | np.isnan(ibi[:-1])))[0] + 1
    if not c.size:
        return np.zeros(0), np.zeros(0)
    bt, bv = [ts[c[0]]], [ibi[c[0]]]
    for a, b in zip(c[:-1], c[1:]):
        gap, va, vb = ts[b] - ts[a], ibi[a], ibi[b]
        k = int(round((gap - vb) / va))
        if 1 <= k <= 4 and abs(gap - vb - k * va) < 0.05:
            for j in range(1, k + 1):
                bt.append(ts[a] + j * va)
                bv.append(va)
        bt.append(ts[b])
        bv.append(vb)
    return np.array(bt), np.array(bv) * 1000.0


def complete(path):
    with open(path, "rb") as f:
        f.seek(-300, 2)
        return f.read().decode(errors="ignore").strip().split("\n")[-1].count(",") == 13


def main(src, out):
    import pandas as pd
    for name in sorted(os.listdir(src)):
        if not name.endswith("_whole_df.csv"):
            continue
        sid = name.split("_")[0]
        if os.path.exists(os.path.join(out, f"{sid}_truth.csv")) or not complete(os.path.join(src, name)):
            continue
        d = pd.read_csv(os.path.join(src, name), engine="pyarrow")
        st = d.Sleep_Stage.astype(str).to_numpy()
        ts = d.TIMESTAMP.to_numpy(float)
        scored = np.isin(st, list(MAP))
        t0 = ts[np.argmax(st != "P")]
        n = int((ts[np.nonzero(scored)[0][-1]] - t0) // 30) + 1
        rel = ts - t0
        sec = np.floor(rel).astype(np.int64)
        keep = (sec >= -PAD) & (sec < 30 * n + PAD)
        u, inv = np.unique(sec[keep], return_inverse=True)
        cnt = np.bincount(inv)
        g = np.stack([np.bincount(inv, weights=d[c].to_numpy(float)[keep] / 64.0) / cnt
                      for c in ("ACC_X", "ACC_Y", "ACC_Z")], axis=1)
        hr = np.bincount(inv, weights=np.nan_to_num(d.HR.to_numpy(float)[keep])) / cnt
        bt, rr = beats(rel, d.IBI.to_numpy(float))
        kb = (bt >= -PAD) & (bt < 30 * n + PAD)
        mid = np.clip(np.searchsorted(rel, 30 * np.arange(n) + 15), 0, len(st) - 1)
        write_night(out, sid, np.column_stack([u, g]), np.column_stack([u, np.round(hr)])[np.round(hr) > 0],
                    np.column_stack([np.floor(bt[kb]), np.round(rr[kb])]), [MAP.get(st[i]) for i in mid])
        print(sid, n, "epochs", flush=True)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
