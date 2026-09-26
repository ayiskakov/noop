# W3 — Analytics

**Phase** 2 · **Decisions** [AD-8](../DECISIONS.md#ad-8) · **Status** on the
[board](../README.md#status-board) · **Method** [METHOD.md](../METHOD.md)

All physiological math as pure functions: HRV, recovery, strain, sleep staging, workouts, baselines,
stress, ECG beats. Database-free. `Packages/StrandAnalytics`: 33.1k source lines, 31.7k test lines in
204 files.

## Read first

`docs/ANALYTICS.md`, `docs/VALIDATION_PROTOCOL.md`, `docs/RR-OPTIMIZATION.md`, `docs/FITNESS_AGE.md`,
`docs/sleep-heart-rate-contrast.md`, and the "deriving a physiological signal" bullet in `AGENTS.md`.

## Where to start

Paths under `Packages/StrandAnalytics/Sources/StrandAnalytics/`.

| File | Symbols | Why |
|---|---|---|
| `AnalyticsEngine.swift` | `analyzeDay(…)` → `DayResult` | The per-day pipeline every score flows through |
| `SleepStager.swift` (3.3k lines) | `detectSleep(…, stager:)`, `stageWindow(…)`, `bandSleepWindow` | Sleep detection and the restage funnel |
| `SleepStagerV2.swift`, `SleepStagerV3.swift` | stagers | V3 is the default; V2 and V1 stay selectable |
| `SleepStageTotals.swift`, `WakeMotionRefinement.swift` | totals, wake refinement | What the Sleep screen and scores read |
| `HRVAnalyzer.swift`, `RecoveryScorer.swift`, `StrainScorer.swift`, `Baselines.swift` | scorers | Headline scores and their baselines |
| `ReadinessEngine.swift`, `ResilienceEngine.swift`, `VitalityEngine.swift`, `CircadianEngine.swift`, `IllnessSignalEngine.swift` | engines | Secondary scores, several feeding notifications |
| `DaytimeStress.swift`, `StressOnsetDetector.swift` | stress | Stress curve and onsets |
| `WorkoutDetector.swift`, `AutoWorkoutDetector+Trace.swift`, `WorkoutTypeClassifier.swift`, `SedentaryDetector.swift`, `StepsEstimateEngine.swift` | activity | Workout and step detection |
| `EcgBeats.swift`, `EcgStrip.swift`, `RhythmScreener.swift` | ECG | Beat detection and rhythm measurements on R16 |
| `AnalyticsMemo.swift` | `AnalyticsMemoCache` | Memo caches: stale-result risk |
| `LocalDayWindows.swift` | day windows | The local-day boundary every daily figure depends on |

Tests: `Tests/StrandAnalyticsTests`, pinned oracles in `Tests/StrandAnalyticsTests/oracles/`, twins in
`Tools/oracle-twins/`. Stager benches: `Tools/SleepBench`, `Tools/SleepPSG`, `Tools/SleepTrain`.

## Contracts this area owns

- Pure: no database, no UI, no clock reads that are not passed in.
- Outputs feed stored rows, so a formula change is a stored-data change (AD-8).
- A derived physiological signal is validated on varying inputs, not on one matching night.

## Checks

- [ ] List which scorers and engines have a pinned oracle and which do not; add oracles where outputs
      reach disk.
- [ ] Edge inputs give defined output: empty night, one sample, long gap, DST night, time-zone change,
      a night crossing local and UTC midnight differently.
- [ ] Each memo cache keys on every input that changes its output.
- [ ] Stager selection (V1, V2, V3) is either recorded on rows or triggers a consistent rescore (AD-8).
- [ ] `detectSleep` defaults `stager:` to `.v1` and `hrOnlySessions` to `.v2`, while the app runs `.v3`.
      Both shipping call sites pass it explicitly (checked 2026-09-25); decide whether the defaults should
      go so a new caller cannot silently run an old recipe.
- [ ] Baselines define warm-up, outlier handling and zero-variance cases; no division by zero or NaN
      reaching a stored field.
- [ ] Hot paths over a full day of 1 Hz samples are not quadratic.

## Review passes

- [ ] 1 Map · [ ] 2 Static sweep · [ ] 3 Deep read · [ ] 4 Run · [ ] 5 Adversarial

## Gate

Oracle over the input space or a wide spread, pinned in a test; replay-harness diff over backups with
every changed row explained; SleepBench / SleepPSG for any stager change.

## Findings

| ID | Sev | Status | Finding | Location | Evidence | PR |
|---|---|---|---|---|---|---|
| W03-001 | S3 | Reported | In-bed start from gravity counts evening lead-ins, which drags sleep efficiency down | `SleepStager.swift` (to confirm) | 5/MG sleep audit of 2026-09-24, left open after PR #20 | |
| W03-002 | S3 | Reported | Staging misses early-cycle REM on some nights | Stager recipe (to confirm) | Same audit | |
| W03-003 | S2 | Fixed | The 5/MG SpO₂ candidate night (low, dips, mean, evidence count) was resolved per second, but the strap measures byte 82 in 30-record windows whose rolling value blips for single seconds: a one-second blip became the night's low and a dip no window showed, and the evidence count was seconds of one measurement | `Spo2CandidateNight.swift` `nightlySpo2CandidateNight`; `Spo2EstimateCard.swift`; `validate_spo2_candidate.py` `night_mean_at_offset` | V0: `testASingleSecondBlipInsideAWindowIsNotADip` fails on the old resolver (1 dip, low 77, in a 95–96 window). V1: oracle re-pinned and matched line for line by an independent Python implementation (17 cases); on all 11 backups the resolver and that implementation agree on every night; package suite, `StrandTests`, both app builds, i18n and hygiene gates pass. V2 (independent reviewer and `/code-review high`): a continuous stream would collapse into one window (fixed: a 60 s window cap, twice the observed window so a clock step cannot split one); the Dips caption claimed seconds below the threshold (fixed: it counts readings, the dip properties are renamed `dipSamples`/`dipSpanSeconds`); nights scored before the window keys showed per-second Low and Dips under per-reading copy (fixed: dashes); the comparison tool valued a window by its mean (fixed: the app's lower median); stale comments and copy (fixed). Left as before: a night whose readings all failed still resolves to nil; the night chart plots raw seconds, labelled as such. V3: 7 stored nights replayed on `main` and on the fix: in-band seconds unchanged on all 7, displayed mean moves on 1 by one point, the low rises on 6, dips fall from 10 to 1 (the one left is a whole window below the threshold) | |
| W03-004 | S4 | Fixed | The strap-estimate card and the Settings toggle said the strap reports the value every second; it measures a 30-second reading about every 20 minutes of band SLEEP on the straps measured so far, and some readings fail. `docs/WHOOP5_DEEP_DATA.md` described the per-second runs | `Spo2EstimateCard.swift` footnote and trace caption, `SettingsView.swift` `spo2CandidateCard`, `docs/WHOOP5_DEEP_DATA.md` | `docs/PROTOCOL_SENSORS.md` "Byte 82 measurement windows" (175 of 175 windows predicted on one MG) | |
| W03-005 | S4 | Reported | The strap-log SpO₂ candidate line resolves over the one stored session it describes, while the scoring pass resolves over all of the day's detected sessions, so on a day with more than one session its "(shown as …%)" can differ from the screen. Found in W03-003's V2; predates it | `DebugDataDiagnostics.swift` (`nightlySpo2CandidateNight([det], …)`) | Code reading; not yet reproduced | |

## Log

- 2026-09-25 — File created from the plan. W03-001 and W03-002 carried over from the 5/MG sleep audit.
- 2026-09-26 — Out-of-phase fix at the owner's request, from the BLE-dossier fact-check: W03-003 and W03-004 on
  `review/w03-spo2-windows`. The byte 82 window facts behind them are in `docs/PROTOCOL_SENSORS.md`. W3's own
  review passes are not started.
- 2026-09-26 — V2 of W03-003/004 by an independent reviewer and `/code-review high`; every confirmed point fixed on
  the same branch, then re-validated on all 11 backups (resolver = independent Python implementation on every
  night). W03-005 added from that review. Next: the strap check (a night on the new build, the card showing
  "N of M" readings, the strap log's window line).
