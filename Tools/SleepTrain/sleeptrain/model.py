"""The SleepStagerV3 model: two multinomial logistic-regression heads and an HMM decoder.

A head turns one night's features into per-epoch stage posteriors; the decoder is a Viterbi pass whose
transition matrix and start distribution are counted from the training hypnograms. The base head reads motion
and heart rate; the HRV head reads the beat features as well. On a night where at least half the epochs have
enough beats, both heads run and their log-posteriors are averaged with equal weight before decoding (with
the HRV head's decoder statistics); otherwise the base head stages the night alone. `SleepStagerV3.swift`
mirrors every step here.
"""
import numpy as np
from .data import SI, STAGES
from .features import BASE, HRV, HRV_MIN_BEATS, impute, features

HRV_COVERAGE = 0.5      # fraction of the span's epochs that need HRV_MIN_BEATS beats for the HRV head
PROB_FLOOR = 1e-6
PRIOR_POWER = 0.5       # emission = log P - PRIOR_POWER * log prior: tempers the classifier's class prior
C = 0.1                 # inverse L2 strength; the Wearanize+ CV is flat across 0.01-1
# Weight of the HRV head's log-posterior when both heads run; the base head gets the rest. Equal weights, not
# tuned: against the HRV head alone this moved Wearanize+ CV kappa 0.554 -> 0.547 and DREAMT 0.320 -> 0.313,
# and cut the REM over-count 2.1 -> 0.1 pp and 7.9 -> 5.9 pp, where the HRV head alone out of domain calls REM
# high (a quarter to over a third of sleep on a WHOOP night).
HRV_BLEND = 0.5


class Head:
    def __init__(self, names, mean, scale, coef, intercept, prior, transition):
        self.names, self.mean, self.scale = list(names), np.asarray(mean), np.asarray(scale)
        self.coef, self.intercept = np.asarray(coef), np.asarray(intercept)
        self.prior, self.transition = np.asarray(prior), np.asarray(transition)

    def posteriors(self, F):
        z = (impute(F, self.names, self.mean) - self.mean) / self.scale
        logits = np.tile(self.intercept, (z.shape[0], 1))
        for j in range(z.shape[1]):             # feature by feature, the order the Swift port accumulates in
            logits += self.coef[:, j] * z[:, j:j + 1]
        e = np.exp(logits - logits.max(axis=1, keepdims=True))
        return e / (((e[:, 0] + e[:, 1]) + e[:, 2]) + e[:, 3])[:, None]

    def decode(self, P):
        return self.decode_log(np.log(np.maximum(P, PROB_FLOOR)))

    def decode_log(self, logp):
        em = logp - PRIOR_POWER * np.log(self.prior)
        return viterbi(em, np.log(self.transition), np.log(self.prior))


def viterbi(logem, logT, logp0):
    """Most likely state path. A tie keeps the lower state index, in both the step and the final pick."""
    n, k = logem.shape
    if n == 0:
        return np.zeros(0, int)
    V = logp0 + logem[0]
    back = np.zeros((n, k), int)
    for t in range(1, n):
        cand = V[:, None] + logT
        back[t] = cand.argmax(axis=0)
        V = cand.max(axis=0) + logem[t]
    path = [int(V.argmax())]
    for t in range(n - 1, 0, -1):
        path.append(int(back[t][path[-1]]))
    return np.array(path[::-1])


def uses_hrv(F):
    return F["beats"].size > 0 and np.mean(F["beats"] >= HRV_MIN_BEATS) >= HRV_COVERAGE


def blended_log_posteriors(F, hrv_head, base_head):
    return (HRV_BLEND * np.log(np.maximum(hrv_head.posteriors(F), PROB_FLOOR))
            + (1 - HRV_BLEND) * np.log(np.maximum(base_head.posteriors(F), PROB_FLOOR)))


def stage(F, hrv_head, base_head):
    """Stage indices (into STAGES) for every epoch of the span."""
    if uses_hrv(F):
        return hrv_head.decode_log(blended_log_posteriors(F, hrv_head, base_head))
    return base_head.decode(base_head.posteriors(F))


def labelled(rec):
    """(features dict, stage index per span epoch or -1 when unscored) for a built record."""
    s0, s1 = rec["span"]
    return rec["F"], np.array([SI[t] if t else -1 for t in rec["truth"][s0:s1]])


def fit_head(recs, names, c=C):
    from sklearn.linear_model import LogisticRegression
    Xs, ys = [], []
    for r in recs:
        F, y = labelled(r)
        Xs.append(impute(F, names))
        ys.append(y)
    X, y = np.vstack(Xs), np.concatenate(ys)
    m = y >= 0
    mean = X[m].mean(axis=0)
    scale = X[m].std(axis=0)
    scale[scale == 0] = 1.0
    lr = LogisticRegression(max_iter=5000, C=c).fit((X[m] - mean) / scale, y[m])
    T = np.ones((4, 4))
    for yy in ys:
        ok = (yy[:-1] >= 0) & (yy[1:] >= 0)
        np.add.at(T, (yy[:-1][ok], yy[1:][ok]), 1)
    prior = np.bincount(y[m], minlength=4) / m.sum()
    return Head(names, mean, scale, lr.coef_, lr.intercept_, prior, T / T.sum(axis=1, keepdims=True))


HRV_NAMES = BASE + HRV
BASE_NAMES = BASE
__all__ = ["Head", "viterbi", "uses_hrv", "stage", "fit_head", "HRV_NAMES", "BASE_NAMES", "STAGES"]


# ------------------------------------------------------------------- the app's entry point, for the oracle

def epoch_starts(start, end):
    """SleepStagerV3.epochStarts: the wall-clock 30 s grid inside [start, end)."""
    e = ((start + 29) // 30) * 30
    out = []
    while e < end:
        out.append(e)
        e += 30
    return out


def in_window(e, window, end):
    """SleepStagerV2.epochInSleepWindow: the session-grid instant the epoch holds, or the one before `end` for
    the session's cut-short last epoch."""
    t = e + ((window[0] - e) % 30 + 30) % 30
    if t >= end:
        t -= 30
    return window[0] <= t < window[1]


def stage_session(start, end, grav, hr, rr, window, hrv_head, base_head):
    """SleepStagerV3.stageSession without the memo: (labels per grid epoch, segments, span detail or None)."""
    epochs = epoch_starts(start, end)
    if not epochs:
        return [], [(start, end, "light")], None
    idx = [i for i, e in enumerate(epochs) if window is None or in_window(e, window, end)]
    labels = ["wake"] * len(epochs)
    detail = None
    if idx:
        a, b = idx[0], idx[-1]
        F = features(grav, hr, rr, epochs[a], b - a + 1)
        for k, s in enumerate(stage(F, hrv_head, base_head)):
            labels[a + k] = STAGES[s]
        detail = dict(span_start=epochs[a], n=b - a + 1, F=F, P_hrv=hrv_head.posteriors(F),
                      P_base=base_head.posteriors(F), head="hrv" if uses_hrv(F) else "base")
    segments = []
    for i, e in enumerate(epochs):
        s0 = start if i == 0 else e
        s1 = end if i == len(epochs) - 1 else epochs[i + 1]
        if segments and segments[-1][2] == labels[i]:
            segments[-1] = (segments[-1][0], s1, labels[i])
        else:
            segments.append((s0, s1, labels[i]))
    return labels, segments, detail
