#!/usr/bin/env python3
"""Wearanize+ OA (Radboud University, CC BY 4.0, DOI 10.34973/xrmf-5726) -> the SleepTrain night format.

    python3 prepare_wearanize.py <out dir> [subject ids ...]        # download + process
    python3 prepare_wearanize.py <out dir> --npz <dir of cached .npz>

Keeps what a wrist strap could see: the Empatica E4's per-second gravity (ACC / 64 g), its 1 Hz HR and its
PPG inter-beat intervals, plus both human hypnograms. Nothing from the PSG montage is kept except the ECG,
which is used for one purpose only: to put the E4 on the PSG clock. The E4 clock drifts against the PSG
recorder (about -5 s per hour), so a linear E4 -> PSG time map is fitted per subject from the
cross-correlation of E4 inter-beat intervals with ECG R-R intervals, hour by hour. No sleep label is involved
in the alignment.

Each subject needs ~360 MB of Parquet and the raw E4 zip; they are downloaded to a temporary directory and
deleted after processing. The Radboud server refuses more than ~4 parallel downloads.
"""
import io
import os
import subprocess
import sys
import tempfile
import zipfile
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sleeptrain.data import write_night  # noqa: E402

BASE = "https://webdav.data.ru.nl/dcmn/DSC_wrnzpoa_t0000925a_195_v1"
CODE = {0: "wake", 1: "light", 2: "light", 3: "deep", 4: "rem"}
CURL = ["curl", "-sf", "--retry", "6", "--retry-delay", "15", "--retry-all-errors"]


def process(sid, tmp):
    """Download one subject and return its arrays on the PSG clock (seconds from the first PSG epoch)."""
    import pyarrow.parquet as pq
    import neurokit2 as nk
    pqf, zf = f"{tmp}/Sub{sid}s1.parquet", f"{tmp}/Sub{sid}s1_e4.zip"
    try:
        subprocess.run(CURL + ["-o", pqf, f"{BASE}/Wearanize%2B_OA_PlugNPlay_Parquet_v1.1/Sub{sid}s1.parquet"],
                       check=True)
        subprocess.run(CURL + ["-o", zf, f"{BASE}/Wearanize%2B_OA_raw_v1.1/1.Raw_data/Sub{sid}s1/3.Empatica/"
                                         f"Sub{sid}s1_Empatica_data.zip"], check=True)
        cols = ["Device", "SamplingRate", "SleepScores"] + [f"SignalData.{c}" for c in ("ACCX", "ACCY", "ACCZ", "HR",
                                                                                       "ECG 2")]
        tb = pq.read_table(pqf, columns=cols)
        devs = tb.column("Device").to_pylist()
        e4 = devs.index("Empatica E4")
        psg = next(i for i in range(len(devs)) if (tb.column("SleepScores")[i].as_py() or {}).get("ManualScores1"))
        fs_e4, fs_psg = tb.column("SamplingRate")[e4].as_py(), tb.column("SamplingRate")[psg].as_py()

        def get(c, i):
            return np.array(tb.column(c)[i].as_py(), float)
        ax, ay, az, hr, ecg = get("ACCX", e4), get("ACCY", e4), get("ACCZ", e4), get("HR", e4), get("ECG 2", psg)
        sc = tb.column("SleepScores")[psg].as_py()
        fsa, fse = fs_e4["ACCX"], fs_psg["ECG 2"]
        dur = len(ecg) / fse
        ns = int(len(ax) // fsa)
        g = np.stack([a[: int(ns * fsa)].reshape(ns, int(fsa)).mean(1) / 64.0 for a in (ax, ay, az)], 1)
        _, info = nk.ecg_peaks(nk.ecg_clean(ecg, sampling_rate=fse), sampling_rate=fse, correct_artifacts=False)
        pk = np.asarray(info["ECG_R_Peaks"]) / fse
        # The parquet E4 streams start at an unknown offset into the raw E4 recording: find it by matching the
        # raw HR sequence exactly, then carry the raw IBI timestamps across.
        z = zipfile.ZipFile(zf)
        rh = np.loadtxt(io.StringIO(z.read("HR.csv").decode()))
        rh0, rhr = rh[0], rh[2:]
        ibi_text = z.read("IBI.csv").decode()
        ib = np.loadtxt(io.StringIO(ibi_text), delimiter=",", skiprows=1, ndmin=2)
        ib0 = float(ibi_text.split(",")[0])
        n = 600
        off = next((k for k in range(0, len(rhr) - n)
                    if abs(rhr[k] - hr[0]) < 0.01 and np.allclose(rhr[k:k + n], hr[:n], atol=0.01)), None)
        if off is None:
            raise RuntimeError("raw HR does not match parquet HR")
        ibt = ib[:, 0] + ib0 - (rh0 + off)
        lags, centres = [], []
        for h0 in range(0, int(dur), 3600):
            m = (ibt >= h0 + 60) & (ibt < h0 + 3600)
            if m.sum() < 300:
                continue
            shifts = np.arange(-240, 240, 0.25)
            corr = [np.corrcoef(np.interp(ibt[m] + s, pk[1:], np.diff(pk)), ib[m, 1])[0, 1] for s in shifts]
            j = int(np.nanargmax(corr))
            if corr[j] > 0.5:
                lags.append(shifts[j])
                centres.append(np.median(ibt[m]))
        if len(lags) >= 2:
            b, a = np.polyfit(centres, lags, 1)
        elif len(lags) == 1:
            b, a = 0.0, lags[0]
        else:
            raise RuntimeError("no reliable E4/ECG alignment")

        def warp(t):
            return t + a + b * t
        return dict(grav_t=warp(np.arange(ns) + 0.5), grav=g, hr_t=warp(np.arange(len(hr)) + 0.5), hr=hr,
                    ibi_t=warp(ibt), ibi=ib[:, 1], s1=np.array(sc["ManualScores1"], int),
                    s2=np.array(sc["ManualScores2"], int))
    finally:
        for f in (pqf, zf):
            if os.path.exists(f):
                os.remove(f)


def write(out, sid, d):
    """Store the arrays the way the strap would: whole-second stamps, integer bpm and integer ms."""
    grav = np.column_stack([np.floor(d["grav_t"]), d["grav"]])
    hr = np.column_stack([np.floor(d["hr_t"]), np.round(d["hr"])])
    hr = hr[hr[:, 1] > 0]
    rr = np.column_stack([np.floor(d["ibi_t"]), np.round(np.asarray(d["ibi"], float) * 1000.0)])
    order = np.argsort(rr[:, 0], kind="stable")
    write_night(out, sid, grav, hr, rr[order], [CODE.get(int(c)) for c in d["s1"]],
                [CODE.get(int(c)) for c in d["s2"]])


def main(argv):
    out = argv[0]
    if len(argv) > 2 and argv[1] == "--npz":
        for f in sorted(os.listdir(argv[2])):
            if f.endswith(".npz"):
                write(out, f[:-4], dict(np.load(os.path.join(argv[2], f))))
                print(f[:-4], flush=True)
        return
    ids = argv[1:] or [f"{i:03d}" for i in range(1, 131)]
    with tempfile.TemporaryDirectory() as tmp:
        for sid in ids:
            if os.path.exists(os.path.join(out, f"{sid}_truth.csv")):
                continue
            try:
                write(out, sid, process(sid, tmp))
                print(sid, "ok", flush=True)
            except Exception as e:  # a subject without E4, ECG or scores is skipped, not fatal
                print(sid, "skipped:", e, flush=True)


if __name__ == "__main__":
    main(sys.argv[1:])
