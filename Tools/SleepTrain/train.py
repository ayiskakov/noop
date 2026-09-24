#!/usr/bin/env python3
"""Train SleepStagerV3, report its cross-validated agreement with PSG, and write the Swift model file.

    python3 train.py --wearanize DIR --sleep-accel DIR [--dreamt DIR] [--swift PATH] [--report PATH]

DIRs are prepared night-format cohorts (prepare_*.py). Wearanize+ and sleep-accel are the training data.
DREAMT, when given, is scored as an independent test only and never enters a fit.

Every night is used twice: once over its whole PSG-scored span (the stager's view when the band gives no
sleep window) and once cropped to the window `SleepStager.bandSleepWindow` would allow, emulated from the
PSG hypnogram (the stager's view when it does). The HRV head trains on Wearanize+ (the only training cohort
with beat intervals); the base head trains on both cohorts.

Agreement is Cohen's kappa over every scored epoch of the PSG span, with every epoch outside the staged span
counted as wake, plus the mean of per-subject kappas, per-stage F1, the pooled stage-share bias in percentage
points, and the per-subject minute bias of each stage with its 95 % limits of agreement (Menghini 2021).
Cross-validation is 10-fold grouped by subject, the held-out subjects' nights never in the fit.
"""
import argparse
import os
import sys
from multiprocessing import Pool

# One BLAS thread per process: the folds already run in parallel, and a single-threaded reduction order makes
# the fitted coefficients, and so the generated Swift file, the same on every run.
for _v in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "VECLIB_MAXIMUM_THREADS"):
    os.environ.setdefault(_v, "1")
import numpy as np  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sleeptrain.data import load_dir, band_window, SI  # noqa: E402
from sleeptrain.features import features  # noqa: E402
from sleeptrain.model import fit_head, stage, HRV_NAMES, BASE_NAMES, uses_hrv  # noqa: E402

FOLDS = 10


def build(args):
    night, view = args
    a, b = night.scored_span()
    if view == "window":
        w = band_window([t in ("light", "deep", "rem") for t in night.truth[a:b]])
        if w is None:
            return None
        s0, s1 = a + w[0], a + w[1]
    else:
        s0, s1 = a, b
    return dict(sid=night.sid, cohort=night.cohort, view=view, span=(s0, s1), scored=(a, b),
                F=features(night.grav, night.hr, night.rr, 30 * s0, s1 - s0), truth=night.truth,
                truth2=night.truth2)


def whole_night(rec, path):
    """(truth, prediction) over the scored span; epochs outside the staged span are wake."""
    a, b = rec["scored"]
    s0, s1 = rec["span"]
    pred = np.zeros(b - a, int)
    pred[s0 - a: s1 - a] = path
    return np.array([SI[t] if t else -1 for t in rec["truth"][a:b]]), pred


def kappa(m):
    """Cohen's kappa of a confusion matrix, NaN where it is undefined (no epochs, or one class on both sides),
    as `Confusion.kappa` in Tools/SleepPSG returns it."""
    n = m.sum()
    if n == 0:
        return np.nan
    po, pe = np.trace(m) / n, (m.sum(1) @ m.sum(0)) / n / n
    return np.nan if pe >= 1 else (po - pe) / (1 - pe)


def first_after_onset(labels, k):
    """Minutes from the first sleep epoch to the first epoch of stage `k`, or None."""
    on = next((i for i, x in enumerate(labels) if x in (1, 2, 3)), None)
    f = next((i for i, x in enumerate(labels) if x == k), None) if on is not None else None
    return None if f is None else (f - on) / 2.0


def latency(pairs, k):
    d, early = [], 0
    for t, p in pairs:
        a, b = first_after_onset(list(t), k), first_after_onset(list(p), k)
        if a is not None and b is not None:
            d.append(b - a)
        early += b is not None and b < 5
    return f"{np.mean(d):+.0f} ({early})"


def summary(name, pairs):
    M, ks, mins = np.zeros((4, 4)), [], []
    for t, p in pairs:
        ok = t >= 0
        m = np.zeros((4, 4))
        np.add.at(m, (t[ok], p[ok]), 1)
        M += m
        ks.append(kappa(m))
        mins.append([(np.sum(p[ok] == i) - np.sum(t[ok] == i)) / 2.0 for i in range(4)])
    mins = np.array(mins)
    # A night whose kappa is undefined is left out of the per-night mean, as `sleeppsg --section v3` leaves
    # it out, so the two reports print the same figure for the same cohort.
    ks = [k for k in ks if not np.isnan(k)]
    f1 = [2 * M[i, i] / (M[i].sum() + M[:, i].sum()) for i in range(4)]
    share = (M.sum(0) - M.sum(1)) / M.sum() * 100
    return (f"| {name} | {len(pairs)} | {kappa(M):.3f} | {np.mean(ks) if ks else np.nan:.3f} | "
            + " / ".join(f"{x:.2f}" for x in f1) + " | " + " / ".join(f"{x:+.1f}" for x in share) + " | "
            + " / ".join(f"{mins[:, i].mean():+.0f} ± {1.96 * mins[:, i].std(ddof=1):.0f}" for i in range(4)) + " | "
            + f"{latency(pairs, 2)} / {latency(pairs, 3)} |")


HEADER = ("| Evaluation | nights | kappa | mean subject kappa | F1 wake / light / deep / rem | stage share bias pp "
          "| minute bias ± 1.96 SD wake / light / deep / rem | first deep / REM latency bias, min (nights < 5 min) |"
          "\n|---|---|---|---|---|---|---|---|")


def folds(ids):
    ids = sorted(ids)
    return [set(ids[i::FOLDS]) for i in range(FOLDS)]


_RECS = None


def _init(recs):
    global _RECS
    _RECS = recs


def _fold(args):
    """One fold: fit on every training night except the held-out subjects', stage those subjects' `view`.
    `shipped` refits both heads and picks per night by beat coverage, as the app does; `base` forces the
    base head."""
    kind, cohort, view, held = args
    train = [r for r in _RECS if not (r["cohort"] == cohort and r["sid"] in held)]
    if kind == "shipped":
        hrv = fit_head([r for r in train if r["cohort"] == "wearanize"], HRV_NAMES)
        base = fit_head(train, BASE_NAMES)

        def run(F):
            return stage(F, hrv, base)
    else:
        head = fit_head(train, BASE_NAMES)

        def run(F):
            return head.decode(head.posteriors(F))
    return [whole_night(r, run(r["F"])) for r in _RECS
            if r["cohort"] == cohort and r["sid"] in held and r["view"] == view]


def cross_validate(pool, kind, recs, cohort, view):
    ids = {r["sid"] for r in recs if r["cohort"] == cohort}
    return [p for part in pool.map(_fold, [(kind, cohort, view, held) for held in folds(ids)]) for p in part]


def inter_scorer(recs):
    """The second Wearanize+ scorer against the first, over the epochs both scored."""
    pairs = []
    for r in recs:
        if r["cohort"] != "wearanize" or r["view"] != "span" or not r["truth2"]:
            continue
        a, b = r["scored"]
        t1 = np.array([SI[x] if x else -1 for x in r["truth"][a:b]])
        t2 = np.array([SI[x] if x else -1 for x in r["truth2"][a:b]])
        ok = (t1 >= 0) & (t2 >= 0)
        pairs.append((np.where(ok, t1, -1), np.where(ok, t2, 0)))
    return pairs


def swift_array(v, indent, fmt=lambda x: repr(float(x))):
    items = [fmt(x) for x in np.ravel(v)]
    lines, line = [], ""
    for it in items:
        if len(line) + len(it) + 2 > 100:
            lines.append(line)
            line = ""
        line += it + ", "
    lines.append(line)
    pad = " " * indent
    return "[\n" + "\n".join(pad + "    " + ln.rstrip() for ln in lines) + "\n" + pad + "]"


def swift_head(name, head, doc):
    pad = " " * 8
    rows = ",\n".join(pad + "    " + swift_array(row, 12) for row in head.coef)
    trans = ",\n".join(pad + "    " + swift_array(row, 12) for row in head.transition)
    names = swift_array(np.array(head.names, dtype=object), 8, fmt=lambda n: f'"{n}"')
    return f"""    /// {doc}
    static let {name} = Head(
        features: {names},
        mean: {swift_array(head.mean, 8)},
        scale: {swift_array(head.scale, 8)},
        coef: [
{rows}
        ],
        intercept: {swift_array(head.intercept, 8)},
        prior: {swift_array(head.prior, 8)},
        transition: [
{trans}
        ])
"""


def write_swift(path, hrv, base, counts):
    text = f"""// GENERATED by Tools/SleepTrain/train.py. Do not edit by hand: rerun the tool (see its README).
//
// The two SleepStagerV3 heads (per-feature standardisation, multinomial logistic-regression weights for
// wake / light / deep / rem in that order, class prior and the counted stage-transition matrix).
// Trained on open polysomnography only:
//   Wearanize+ OA, Radboud University, CC BY 4.0, DOI 10.34973/xrmf-5726 ({counts['wearanize']} nights, Empatica E4)
//   PhysioNet sleep-accel v1.0.0, Walch et al. SLEEP 2019, ODC-By 1.0 ({counts['sleep-accel']} nights, Apple Watch)

extension SleepStagerV3 {{
{swift_head("hrvHead", hrv, "Motion, heart rate and beat-interval features. Trained on Wearanize+.")}
{swift_head("baseHead", base, "Motion and heart rate only. Trained on Wearanize+ and sleep-accel.")}}}
"""
    with open(path, "w") as f:
        f.write(text)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wearanize", required=True)
    ap.add_argument("--sleep-accel", required=True)
    ap.add_argument("--dreamt")
    ap.add_argument("--swift")
    ap.add_argument("--report")
    ap.add_argument("--jobs", type=int, default=os.cpu_count())
    ap.add_argument("--no-cv", action="store_true", help="only refit and write the model")
    a = ap.parse_args()

    cohorts = [(a.wearanize, "wearanize"), (a.sleep_accel, "sleep-accel")] + ([(a.dreamt, "dreamt")] if a.dreamt else [])
    jobs = [(n, v) for path, c in cohorts for n in load_dir(path, c) for v in ("span", "window")]
    with Pool(a.jobs) as pool:
        recs = [r for r in pool.map(build, jobs, chunksize=1) if r is not None]
    train = [r for r in recs if r["cohort"] != "dreamt"]
    test = [r for r in recs if r["cohort"] == "dreamt"]
    counts = {c: len({r["sid"] for r in recs if r["cohort"] == c}) for _, c in cohorts}

    out = ["## SleepStagerV3 agreement with PSG", "",
           f"Training nights: Wearanize+ {counts['wearanize']}, sleep-accel {counts['sleep-accel']}. "
           "`window` = staged inside the band-style sleep window taken from the PSG hypnogram, wake outside; "
           "`span` = the whole scored span staged.", "", HEADER]

    def add(line):
        out.append(line)
        print(line, flush=True)

    if not a.no_cv:
        add(summary("Wearanize+ second human scorer vs first (ceiling)", inter_scorer(train)))
        with Pool(a.jobs, initializer=_init, initargs=(train,)) as pool:
            for view in ("window", "span"):
                for cohort, name in (("wearanize", "Wearanize+"), ("sleep-accel", "sleep-accel")):
                    add(summary(f"{name}, V3 as shipped, {view}", cross_validate(pool, "shipped", train, cohort, view)))
            add(summary("Wearanize+, base head forced (no beats), window",
                        cross_validate(pool, "base", train, "wearanize", "window")))

    hrv = fit_head([r for r in train if r["cohort"] == "wearanize"], HRV_NAMES)
    base = fit_head(train, BASE_NAMES)
    for view in ("window", "span"):
        if test:
            pairs = [whole_night(r, stage(r["F"], hrv, base)) for r in test if r["view"] == view]
            add(summary(f"DREAMT (independent test), V3 as shipped, {view}", pairs))
    hrv_share = np.mean([uses_hrv(r["F"]) for r in recs if r["cohort"] == "wearanize" and r["view"] == "window"])
    out += ["", f"HRV head chosen on {hrv_share:.0%} of Wearanize+ windows (beat coverage rule)."]
    if a.report:
        with open(a.report, "w") as f:
            f.write("\n".join(out) + "\n")
    if a.swift:
        write_swift(a.swift, hrv, base, counts)
        print("wrote", a.swift)


if __name__ == "__main__":
    main()
