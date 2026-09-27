# W7 — App data layer

**Phase** 2 · **Decisions** [AD-1](../DECISIONS.md#ad-1), [AD-7](../DECISIONS.md#ad-7),
[AD-8](../DECISIONS.md#ad-8) · **Status** on the [board](../README.md#status-board) ·
**Method** [METHOD.md](../METHOD.md)

Glue between the store, analytics and screens: scoring orchestration, metric resolution, backups,
imports, rescore. `Strand/Data`: 17.4k lines in 54 files. Holds the two biggest bug hot spots in the
repo; its only CI is `StrandTests` on app-path PRs.

## Read first

`docs/ARCHITECTURE.md` §7 and §9, `docs/DATA_MODEL.md`, `docs/ANALYTICS.md`, and the
"two readouts of one fact" bullet in `AGENTS.md`.

## Where to start

Paths under `Strand/Data/`.

| File | Symbols | Why |
|---|---|---|
| `IntelligenceEngine.swift` (3.5k lines, 46 fix commits) | `analyzeRecent(…)`, `runEffortRescoreIfNeeded`, `runTimestampHealIfNeeded`, `recomputeFitnessAgeOnly` | Orchestrates scoring and writes derived rows |
| `Repository.swift` (3.5k lines, 32 fix commits) | `Repository`, `MetricSeriesResolution`, `SourcedDailyMetric`, `RepositoryFreshness` | What every screen reads; source resolution |
| `MetricCatalog.swift` | catalog | 43 `"my-whoop"` literals (AD-7) |
| `DataBackup.swift`, `BackupSync.swift` | backup and restore | `.noopbak` build and restore |
| `HealthspanPipeline.swift`, `ResilienceLoader.swift`, `DayCycleIntelligenceIntegration.swift` | pipelines | Secondary score pipelines |
| `RescoreBackgroundPolicy.swift` | policy | When derived rows are rebuilt |
| `DeviceRegistry.swift` | registry | Active strap id vs the partition key |
| `WorkoutSource.swift`, `LiftSession*.swift` | workouts and lifting | Session state and persistence |
| `Units.swift`, `Profile.swift` | units and profile | Conversions every screen relies on |

Tests: `StrandTests` (only three file names match IntelligenceEngine, Rescore or Repository — thin for
the two biggest hot spots).

## Contracts this area owns

- Each screen-facing fact has one resolver.
- Derived rows are rebuilt deterministically: the same inputs give the same rows.
- Backup restore reproduces the same derived rows.

## Checks

- [ ] For each pure-logic type here, decide whether it moves to a package (AD-1); list candidates.
- [ ] Classify every `"my-whoop"` literal as read or write, and test with two straps registered (AD-7).
- [ ] A rescore cannot race an offload or another rescore (single-flight, or serialised).
- [ ] `IntelligenceEngine` fix history: group the 46 fixes by cause and check each cause is closed,
      not just its last symptom.
- [ ] Restore of a real backup, then a rescore, produces the same rows the backup held.
- [ ] Cached rows vs a fresh compute over a backup (replay harness) differ only where explained (AD-8).

## Review passes

- [ ] 1 Map · [ ] 2 Static sweep · [ ] 3 Deep read · [ ] 4 Run · [ ] 5 Adversarial

## Gate

`StrandTests`; both app builds; replay over a backup with every changed row explained.

## Findings

| ID | Sev | Status | Finding | Location | Evidence | PR |
|---|---|---|---|---|---|---|
| W07-001 | S3 | Reported | `"my-whoop"` literal at 193 sites, against the `AGENTS.md` rule that reads thread the active strap id | `MetricCatalog.swift` 43, `TodayView.swift` 21, `Repository.swift` 16 | Pattern scan in `BASELINE.md` | |
| W07-002 | S2 | Reported | Deleting a re-added strap's data (`whoop-<uuid>`) leaves the scores computed from it, because the engine writes every computed row under the canonical `my-whoop-noop`; deleting `my-whoop` clears that canonical sibling, including days scored from another strap | `IntelligenceEngine.swift` `deviceId`; `DeviceRegistryStore.swift` `deleteAllData` | Remainder of W02-005: with more than one registered device the canonical computed namespace is shared, so `deleteAllData` now leaves it in place rather than deleting another device's days (the V2 regression of a617df30). Deleting a device in a multi-device install still leaves the scores computed from it on screen. Needs per-day attribution (`dayOwnership` records overrides only; provenance covers only some metrics). AD-7 | |
| W07-003 | S3 | Reported | A stored sleep session that re-detection no longer produces is never removed unless it overlaps a fresh one: sleep has no delete-reinsert reconcile (the #899 heal only collapses overlaps, as its own comment says), so a once-detected session survives every later pass | `IntelligenceEngine.swift` sleep write and #899 heal; `MetricsCache.swift` `upsertSleepSessions` | V0 (2026-09-27 export, replay harness on 11.9.12): 1 of 10 stored sessions, a short daytime one with no user edit, is found by neither V2 nor V3 over its day's full data, nor at 8 window cuts from 5 min to 10 h after its end, nor with the band, gravity or R-R stream removed, nor with band and gravity trimmed at its start; the band never scored SLEEP inside it. What produced it is not reconstructed. It stays out of the day's sleep total, but every reader of `sleepSession` sees it | |
| W07-004 | S3 | Reported | Post-offload re-scores that run in the background cost 27.6–79.5 s of CPU each (52–488 s elapsed), every 10 minutes while the strap offloads; foreground passes cost 1.9–26.8 s | `IntelligenceEngine` post-offload re-score | V0 (2026-09-27 log, 11.9.12): 13 `re-score: cost` lines, 5 backgrounded; one backgrounded pass's `steps` phase took 591 s of wall time at a 16 % CPU share. Battery cost not measured | |
| W07-005 | S4 | Fixed | Every re-score reprints its per-day diagnostic lines (sleep, resp, hrv and rhr for about 10 days each, plus workout detect and effort), mostly unchanged since the last pass: after W06-118 they are the largest share of a strap log and limit its ring to about 2 h | `IntelligenceEngine.swift` per-day `diagnosticSink` lines; `RepeatedDayLineFilter.swift` | Found by W06-108's V2 review. V0 (2026-09-27 log, current session, 64 min): 12 re-scores, 960 `day=` lines. Correction: not all ungated. `dayOwner` (`.universal`, on whenever any Test Centre mode is) is 120 of them and `detectedBout` (`.workouts`) 12 more; the untagged per-day lines are 840, 70 a pass, and 733 are byte-identical to the previous pass. V0 test: `testAnUnchangedPassWithholdsItsDayLinesAndCountsThem` fails on the unfixed code (pass 2 with `dayCache reused=2/2` reprints every per-day line). Fixed (change-only, not a Test Centre gate: these lines are the proof of what was scored in a report sent without Test Centre): the untagged per-day lines go through `emitDayLine` → `RepeatedDayLineFilter`, keyed by the text through `day=YYYY-MM-DD` plus the occurrence in the pass. A pass withholds a line identical to the last print on its key and ends with `re-score: N per-day line(s) unchanged since their last print, not repeated (oldest print HH:mm:ss)`. An unchanged line prints again once its last print is 1 h old: at this log's density with W06-118 and this fix (about 1,800 lines an hour) the durable tail's 2,000 lines span about 67 min and the live ring about 2.8 h, so each scored day keeps a copy in both; a generation (1,000 lines) cannot be promised one, and its job is the stop. Readers checked: `CaptureAccumulator` (the Test Centre "K of N" row) and `CaptureCompleteness` (the bundle's INCOMPLETE guard) count distinct `sleep day=` days or presence, and both scan `live.exportableLogText()`, the whole ring plus generations rather than the lines since a mode started, so the hourly copy keeps every scored day where they look. Lines are compared before `redactPii` (counts and day keys only). V1: `RepeatedDayLineTests` (10) pass; `StrandTests` (2,069, 2 skipped) passes; `Strand` and `NOOPiOS` (no watch) build. Mutations: printing every line fails the 2 engine tests; dropping the per-line age check fails `testALineWhoseHourEndsDuringAPassPrints`; dropping the occurrence index fails 7. Oracle (the Swift filter over the log's 12 passes): 840 → 171 printed + 11 summaries; the first pass prints 70 and the hour refresh 68. Left, recorded here: `dayOwner` still prints 10 lines a pass with any Test Centre mode on (so in W06-108's V3 run), and per-pass constants (`sleep SKIPPED`, `Dedup(#899) … removed 0`, `detectedBout`) repeat too; the next lever if the 2 h target is missed. V3 due: the W06-108 strap run's log |  |

## Log

- 2026-09-25 — File created from the plan. W07-001 seeded from the baseline scan.
- 2026-09-27 — W07-003 and W07-004 recorded from the owner's 11.9.12 export (replay harness and strap log).
- 2026-09-27 — W07-005 recorded from the sixth W6 batch's V2 review.
- 2026-09-27 — W07-005 fixed on `review/w07-day-line-repeats` (stacked on `review/w06-fixes-6`): change-only per-day lines with an hourly refresh and a per-pass summary. V3 rides the W06-108 strap run.
