#!/usr/bin/env python3
"""Write the oracle fixture that pins the Swift SleepStagerV3 to this reference.

    python3 make_oracle.py [--model PATH] [--out PATH]

Defaults: the committed `SleepStagerV3Model.swift` and
`Packages/StrandAnalytics/Tests/StrandAnalyticsTests/oracles/sleep_stager_v3.json`.

The synthetic nights are generated from SplitMix64 with integer arithmetic only (gravity is an integer over
1024, exact in binary), so `SleepStagerV3OracleTests` rebuilds byte-identical inputs from the same seeds
instead of the fixture carrying hours of samples. For each case the fixture keeps the reference's features
and both heads' posteriors on every `stride`-th staged epoch, every epoch's beat count, the head chosen, every
label and the final segments. Rerun whenever the model file or the feature definition changes.
"""
import argparse
import json
import math
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sleeptrain.model import Head, stage_session  # noqa: E402
from sleeptrain.features import BASE, HRV  # noqa: E402

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
MODEL = os.path.join(REPO, "Packages/StrandAnalytics/Sources/StrandAnalytics/SleepStagerV3Model.swift")
OUT = os.path.join(REPO, "Packages/StrandAnalytics/Tests/StrandAnalyticsTests/oracles/sleep_stager_v3.json")
MASK = (1 << 64) - 1

# name, seed, start, epochs, rr mode, HR gap [from, to) in seconds from start or None,
# sleep window as seconds from start or None, stride
CASES = [
    ("band night with beats", 1, 1_700_000_017, 600, "full", None, (1207, 600 * 30 - 900), 20),
    ("whole session, no beats, HR gap", 2, 1_700_100_000, 360, "none", (3600, 5400), None, 15),
    ("short nap, sparse beats", 3, 1_700_200_010, 50, "sparse", None, None, 2),
]


class SplitMix64:
    def __init__(self, seed):
        self.s = seed & MASK

    def next(self):
        self.s = (self.s + 0x9E3779B97F4A7C15) & MASK
        z = self.s
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK
        return z ^ (z >> 31)

    def below(self, n):
        return self.next() % n


def synth(seed, start, n_epochs, rr_mode, hr_gap):
    """Streams for a synthetic night. Mirrored exactly by the Swift test; change both or neither."""
    rng = SplitMix64(seed)
    stages = []
    while len(stages) < n_epochs:
        if len(stages) < 20:
            stages.append(0)
            continue
        stages += [1] * (10 + rng.below(20)) + [2] * (5 + rng.below(25)) + [1] * (5 + rng.below(15))
        stages += [3] * (5 + rng.below(25))
        if rng.below(3) == 0:
            stages += [0] * (1 + rng.below(6))
    stages = stages[:n_epochs]
    base_hr, rsa = [72, 60, 54, 63], [30, 20, 35, 8]
    posture = [700, 300, 600]
    grav, hr = [], []
    for s in range(30 * n_epochs):
        st = stages[s // 30]
        if st == 0 and rng.below(40) == 0:
            posture = [rng.below(2048) - 1024, rng.below(2048) - 1024, rng.below(2048) - 1024]
        amp = 300 if st == 0 and rng.below(4) == 0 else (6 if st == 3 else 3)
        if rng.below(97) != 0:
            grav.append((start + s, *[(p + rng.below(2 * amp + 1) - amp) / 1024.0 for p in posture]))
        bpm = base_hr[st] + rng.below(7) - 3 + (s // 600) % 4
        if not (hr_gap and hr_gap[0] <= s < hr_gap[1]) and rng.below(53) != 0:
            hr.append((start + s, bpm))
    rr = []
    if rr_mode != "none":
        t, end_ms = start * 1000 + 400, (start + 30 * n_epochs) * 1000
        while t < end_ms:
            s = t // 1000 - start
            st = stages[min(s // 30, n_epochs - 1)]
            tri = abs((t // 250) % 16 - 8)
            v = 60000 // base_hr[st] + rsa[st] * tri // 8 - rsa[st] // 2 + rng.below(21) - 10
            if rng.below(211) == 0:
                v *= 2
            elif rng.below(307) == 0:
                v = 250
            t += v
            if rr_mode == "sparse" and (s // 60) % 3 != 0:
                continue
            rr.append((t // 1000, v))
    return grav, hr, rr


def parse_head(text, name):
    """Read one `Head(...)` literal back out of the generated Swift file."""
    body = text[text.index(f"static let {name} = Head("):]

    def arr(label):
        i = body.index("[", body.index(f"{label}:"))
        depth = 0
        for j in range(i, len(body)):
            depth += {"[": 1, "]": -1}.get(body[j], 0)
            if depth == 0:
                return json.loads(re.sub(r",\s*\]", "]", body[i:j + 1]))
    return Head(arr("features"), arr("mean"), arr("scale"), arr("coef"), arr("intercept"), arr("prior"),
                arr("transition"))


def load_heads(path):
    text = open(path).read() + "\n"
    return parse_head(text, "hrvHead"), parse_head(text, "baseHead")


def num(x):
    x = float(x)
    return None if math.isnan(x) else x


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=MODEL)
    ap.add_argument("--out", default=OUT)
    a = ap.parse_args()
    hrv, base = load_heads(a.model)
    cases = []
    for name, seed, start, n_epochs, rr_mode, hr_gap, window, stride in CASES:
        grav, hr, rr = synth(seed, start, n_epochs, rr_mode, hr_gap)
        end = start + 30 * n_epochs
        w = (start + window[0], start + window[1]) if window else None
        labels, segments, d = stage_session(start, end, grav, hr, rr, w, hrv, base)
        picks = list(range(0, d["n"], stride))
        cases.append(dict(
            name=name, seed=seed, start=start, epochs=n_epochs, rr=rr_mode,
            hrGap=list(hr_gap) if hr_gap else None, window=list(w) if w else None,
            samples=dict(grav=len(grav), hr=len(hr), rr=len(rr)),
            spanStart=d["span_start"], n=d["n"], head=d["head"], stride=stride,
            features={k: [num(d["F"][k][i]) for i in picks] for k in BASE + HRV},
            beats=[int(b) for b in d["F"]["beats"]],
            hrvPosteriors=[[num(p) for p in d["P_hrv"][i]] for i in picks],
            basePosteriors=[[num(p) for p in d["P_base"][i]] for i in picks],
            labels="".join(x[0] for x in labels),
            segments=[[s0, s1, st] for s0, s1, st in segments]))
        print(name, d["head"], d["n"], "epochs", "".join(x[0] for x in labels)[:80])
    doc = dict(schemaVersion=1,
               note=("Generated by Tools/SleepTrain/make_oracle.py from sleeptrain/features.py and model.py over "
                     "SplitMix64 synthetic nights, with the committed SleepStagerV3Model.swift. Do not edit."),
               cases=cases)
    with open(a.out, "w") as f:
        json.dump(doc, f, indent=1)
        f.write("\n")
    print("wrote", a.out, os.path.getsize(a.out), "bytes")


if __name__ == "__main__":
    main()
