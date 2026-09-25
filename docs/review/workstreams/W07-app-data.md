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

## Log

- 2026-09-25 — File created from the plan. W07-001 seeded from the baseline scan.
