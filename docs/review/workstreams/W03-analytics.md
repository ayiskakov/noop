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

## Log

- 2026-09-25 — File created from the plan. W03-001 and W03-002 carried over from the 5/MG sleep audit.
