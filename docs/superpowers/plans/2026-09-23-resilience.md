# Resilience — physiological recovery time (Experimental)

**Status:** in progress · **Tracking:** 2 PRs · **Started:** 2026-09-23
**Lives in:** the Healthspan tab, as its own section with an **Experimental** badge, behind a default-off
toggle. **Sibling plan:** [Healthspan upgrade](2026-09-23-healthspan-v2.md)

## The idea

Body Age answers "how healthy are my habits". Resilience answers a different question: **how quickly
does my body return to its normal state after it is knocked off it** (a hard week, a short night, travel,
an illness)?

Pyrkov et al. (Nat Commun 2021, doi 10.1038/s41467-021-23014-1, PMC8149842) model the day-to-day
fluctuation δx of an organism-state indicator as a Langevin process, `dδx/dt = −ε·δx + f(t)`. Its
autocorrelation decays as `C(Δt) ~ exp(−ε·Δt)`, and `τ = 1/ε` is the **recovery time**.

What they report:
- τ grows with age, from **~2 weeks at 40 to > 8 weeks at 90** (blood-count indicator, DOSI).
- **Log daily step counts** from wristband wearers (3,032 F / 1,783 M, aged 20–85, ≥ 30 days up to
  5 years each) show the same exponential autocorrelation and a recovery rate that falls **at the same
  pace** as the blood-based one.
- The variance of the fluctuations rises with age (`σ² ~ B/ε`), a second hallmark.
- Extrapolated, both diverge at ~120–150 years.

GeroSense (Pyrkov, Aging 2021, doi 10.18632/aging.202816) proposes the mean together with the
autocorrelation of these fluctuations as a minimal biomarker set. No consumer app shows this.

## Honesty constraints (these shape the UI)

1. **The published τ is cohort-level.** Pyrkov averaged autocorrelation functions over age-matched
   cohorts, then fitted. A per-person τ from one person's history is **not validated** and is noisy. The
   UI always shows τ with its interval, never a bare number, and never an "age".
2. **Only log steps is a published signal.** Resting HR and ln-RMSSD are NOOP extensions and are labelled
   as such.
3. **The cohort reference** (~2 weeks at 40 → > 8 weeks at 90) is drawn as context for where a
   population sits, not as a norm the user is scored against.
4. **Nothing feeds another score.** No Body Age, recovery or illness gate reads it (AGENTS.md rule on
   deriving physiological signals).

## Method (per signal, per window)

1. **Signal.** Daily `ln(steps)` (validated); nightly resting HR and `ln(RMSSD)` (extensions). Days with
   no reading are missing, not zero.
2. **Window.** Trailing **180 days**; needs ≥ 90 observed days. A shorter history shows a collecting
   countdown.
3. **Remove the known structure** that is not recovery dynamics:
   - subtract the per-weekday mean (steps are strongly weekly);
   - remove a linear trend over the window (a slow drift would otherwise inflate τ).
4. **Autocorrelation** C(k) for lags k = 1…28, pairwise over observed days.
5. **Fit** `C(k) = A · exp(−k/τ)` over k ≥ 1. The free amplitude `A < 1` absorbs day-level noise (a
   "nugget"). Weighted non-linear least squares, τ bounded to [1, 180] days.
6. **Bias and interval.** Autocorrelation from a few hundred points is biased toward shorter τ. A
   **parametric bootstrap** (simulate OU + noise with the fitted A, τ, σ, the same n and the same missing
   pattern; seeded RNG so it is deterministic) gives a bias-corrected τ and a 90 % interval.
   *As built (R1):* the plain basic-bootstrap interval covered the truth in only ~50 % of seeds at
   τ ≥ 14 (the bias depends strongly on τ), so the bootstrap is **inverted** instead: simulate at each τ
   on a 16-point log grid, with the amplitude re-scaled per τ so its median fit matches the measured one;
   the estimate is the τ whose median τ̂ equals the measured τ̂, and the interval is every τ whose central
   90 % of τ̂ covers it. Coverage at τ = 7/14/28/56: 86/88/89/93 of 100 seeds. Intervals are wide (a
   median high/low ratio of about 30): that is what one person's half-year can support.
7. **Fluctuation amplitude** σ of the de-structured series: Pyrkov's second hallmark.
8. **Daily readout.** Recompute for the window ending each day, which gives a τ trend over months.
9. **Knocks.** Detect perturbations (a day > 2σ from the rolling baseline, e.g. an RHR spike during
   illness) and measure the observed return-to-baseline half-life for each one. *As built:* the baseline
   is the median of the prior 28 days (weekday pattern removed), frozen at the knock's start; the scale
   is a MAD; the day after the peak must still be > 1σ out, so a lone outlier day is not a knock. A
   half-life is reported only when the fitted return explains ≥ 50 % of the path and its decay constant is
   off the search bounds (a flat fit pinned at the ceiling read 41.6 days beside a 2-day observed return). This is concrete evidence
   of the same quantity, and the UI's most intuitive element.

## PR R1 — Engine (`Packages/StrandAnalytics/ResilienceEngine.swift`, pure)

- `ResilienceEngine.analyze(series:[(dayIndex, value)], signal:) -> Result?` returns `tau`, `tauLow`,
  `tauHigh`, `amplitude A`, `sigma`, `acf [k: C(k)]`, the `fitted curve`, `observedDays` and
  `daysUntilReady`.
- `ResilienceEngine.knocks(series:) -> [Knock]` returns start day, peak deviation and the observed
  recovery half-life.
- **Verification** (AGENTS.md: recover *multiple* injected values, not one):
  - synthetic OU series with injected τ = 7, 14, 28, 56 days, with weekly structure, noise and 20 %
    missing days; the bias-corrected τ must land inside the interval, and the interval must cover the
    truth in ≥ 85 % of seeds;
  - white noise must give τ at the floor with a wide interval;
  - a pure linear trend must be removed, not read as a long τ;
  - weekly-only structure must not create a 7-day τ;
  - pin one fixed-seed run's outputs verbatim as an oracle JSON.

## PR R2 — Experimental UI (Healthspan tab section + detail screen)

**Settings:** an `Experimental · Resilience` card; `@AppStorage("noop.resilienceEnabled")`, default
**false**.

**Healthspan tab section** (shown only when the toggle is on; carries an "Experimental" badge):
- **Hero card:** "Recovery time ≈ 16 days (11–24)". A horizontal band shows the interval, with the
  cohort reference ticks (≈ 2 weeks at 40, > 8 weeks at 90) drawn faintly on the same axis and captioned
  "population averages, for context".
- **Three signal chips:** Steps (published) · Resting HR (extension) · HRV (extension), each with its τ
  and interval; tap one to switch the section.

**Detail screen** (tap the hero):
1. **"How your body settles":** the measured autocorrelation points C(1…28) with the fitted exponential
   and its interval ribbon. The actual evidence, shown plainly.
2. **"Your last knocks":** the three most recent detected perturbations, each a small chart of deviation
   vs days since the knock, with the fitted return curve and "back to baseline in ~N days". The most
   intuitive element.
3. **Trend:** τ over the last 6–12 months (daily rolling), interval as a ribbon, so a lengthening recovery
   time is visible.
4. **Fluctuation amplitude:** σ over time, the second hallmark.
5. **Collecting state:** "x of 90 days observed", per signal.
6. **Method sheet:** plain-language Langevin/recovery explanation, the cohort-vs-individual caveat, the
   extension labels and the references.

**Loader:** one static `ResilienceLoader` in `Strand/Data` reads `repo.dailyMetrics` (read-only, off the
main actor) and calls the engine. It is the single funnel every card reads; there is no persistence
(the computation is cheap).

**Verification:**
- design tokens only;
- new copy in `Strand/Resources/Localizable.xcstrings` with de / es / fr / pt-PT (`i18n-coverage` gate);
- local `xcodebuild` of `Strand` and `NOOPiOS`;
- screenshots in the PR;
- a note on how many days of the user's own history the first readout used.

## Checklist

- [x] PR R1 — `ResilienceEngine` + synthetic-recovery tests + oracle
- [ ] PR R2 — Settings toggle, Healthspan section, detail screen, loader, translations

## References

- Pyrkov TV et al., *Longitudinal analysis of blood markers reveals progressive loss of resilience and
  predicts human lifespan limit*, Nat Commun 2021;12:2765, doi 10.1038/s41467-021-23014-1 (PMC8149842)
- Pyrkov TV et al., *Quantitative characterization of biological age and frailty based on locomotor
  activity records*, Aging 2018, PMC6224248
- Pyrkov TV et al., GeroSense, Aging 2021, doi 10.18632/aging.202816
