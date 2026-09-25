# W2 — Storage

**Phase** 1 · **Decisions** [AD-2](../DECISIONS.md#ad-2) · **Status** on the
[board](../README.md#status-board) · **Method** [METHOD.md](../METHOD.md)

Durable on-device persistence on GRDB/SQLite: migrations, decoded streams, metric caches, raw outbox,
backup settings. `Packages/WhoopStore`: 8.2k source lines, 9.1k test lines in 50 files.

## Read first

`docs/DATA_MODEL.md`, `docs/ARCHITECTURE.md` §4 and §7 (both drift from the code; see W12-001).

## Where to start

Paths under `Packages/WhoopStore/Sources/WhoopStore/`.

| File | Symbols | Why |
|---|---|---|
| `WhoopStore.swift` | `WhoopStore` actor, `DatabasePool` setup | Open, WAL, busy timeout, the multi-instance comment at the top |
| `Database.swift` | `makeMigrator()` | All 49 migrations, `v1` … `v49-ecg-r16-record` |
| `StreamStore.swift` | `insert(_:deviceId:)` | Stream writes and natural keys |
| `Reads.swift` | read APIs | What screens and analytics read |
| `MetricsCache.swift`, `MetricSeriesStore.swift` | caches | Derived rows (AD-8) |
| `RawOutbox.swift` | `pruneRaw` | Raw outbox and pruning |
| `BackupSettings.swift` | `whitelist`, `appleDefaultsKey` | The versioned `.noopbak` settings contract |
| `BackupProvenance.swift` | provenance JSON | Backup metadata |
| `DeviceRegistryStore.swift` | registry rows | Active strap, family resolution inputs |
| `SleepSessionDedup.swift`, `SleepMerge.swift`, `DismissedSleepSpans.swift`, `TimestampHeal.swift` | row rewrites | Code that deletes or rewrites rows: the data-loss traps |
| `DatabaseIntegrity.swift` | integrity probe | What happens on a corrupt file |
| `ScoreInputProvenanceStore.swift` | provenance | Which inputs produced a score (AD-8) |

Tests: `Packages/WhoopStore/Tests/WhoopStoreTests`.

## Contracts this area owns

- Migrations are append-only and each is pinned by a test.
- Natural key `(deviceId, ts)` on streams; dedup keys and hashes on disk are platform-stable.
- The backup whitelist carries only Int, Double and String; adding a key is additive, renaming or
  retyping one breaks every existing backup.
- Decoded rows commit before raw is queued; prune never loses a metric.

## Checks

- [x] No existing migration was mutated (`git log -p` on `Database.swift`); each new one has a test. Pass:
      all 49 bodies unchanged over 48 commits; all 49 ids pinned by the schema oracle (W02-015 refuted).
- [x] A copy of the newest real backup migrates to head, with row counts per table preserved. Pass:
      `StrandTests/RealBackupGateTests` over three backups (v46, v48, v49 to v49); every table that existed
      before is unchanged, apart from the ECG purge v48 and v49 document.
- [x] Every dedup, merge, heal and dismiss path has a test proving unrelated rows survive; window-wide
      deletes get extra scrutiny. Fail: W02-005, W02-006.
- [x] Every key and hash that reaches disk is platform-stable (no `hashValue`). Pass: `hashValue` appears
      only in an in-memory memo key.
- [x] Backup export → import reproduces the same rows and settings; each whitelist kind matches how the
      app reads that key. Pass on a quiescent file (`RealBackupGateTests`: 37 tables, every row and setting
      equal); kinds match. Not under live writers: W02-002, W02-003, W02-004.
- [x] Two `WhoopStore` instances on one file cannot run the migrator concurrently (AD-2). Pass in process
      (`StoreOpenGate`); `Tools/Backfill` is outside the gate. Write contention: W02-008.
- [x] Prune never removes raw data for a chunk whose decoded rows are not committed. Pass.
- [x] Integrity failure leads to a defined, visible outcome, not a crash or silent reset. Fail: W02-009.

## Review passes

- [x] 1 Map · [x] 2 Static sweep · [x] 3 Deep read · [ ] 4 Run · [x] 5 Adversarial

## Gate

Migration test on a copy of a real backup; `.noopbak` round-trip; row-level diff.

## Findings

| ID | Sev | Status | Finding | Location | Evidence | PR |
|---|---|---|---|---|---|---|
| W02-001 | S4 | Reported | A restore stamps `backup.lastRestoreAt` into `UserDefaults.standard` even when the caller injects `settingsDefaults`, so every restore test writes the test host's real defaults and a later debug export reports a restore that never happened | `Strand/Data/DataBackup.swift` `restore(from:toDatabaseAt:…)` | Found while building the Phase 1 gate: the write is unconditional; only `DebugDataDiagnostics` reads it |  |
| W02-002 | S2 | Fixed | Restore's pre-import snapshot and its failed-import rollback copy only the main file after deleting the live WAL, so uncheckpointed commits are lost while the UI says the data was kept; a main-only copy after a partial checkpoint can be malformed | `DataBackup.swift` `restore` snapshot and rollback | P5 confirmed with caveat (found by both slices). V0: `DataBackupLiveStoreTests.testPreImportSnapshotHoldsCommitsStillInTheWal` — 50 committed rows still in the WAL; the snapshot did not even hold the `hrSample` table. Fix: the snapshot goes through SQLite's backup API on a fresh connection (`WhoopStore.writeSnapshot(ofDatabaseAt:to:)`), falling back to the main file plus its WAL when the live file cannot be read; rollbacks restore both. V1: passes; failed on the old copy. V3: `RealBackupGateTests` on three real backups: a restore over an open store keeps a side file whose every table matches the store it replaced. V2 (independent subagent): the snapshot path holds (live files byte-identical, pools unaffected); two defects fixed in a follow-up: a snapshot that failed part way left an empty side file that blocked the byte-copy fallback, so the restore aborted (V0: file-size limit, reproduced), and the source connection could checkpoint the live file on close. The copy now opens the source read-only and removes a partial destination; `CheckpointBusyTests.testAFailedSnapshotLeavesNoPartialCopy` fails without the cleanup |  |
| W02-003 | S2 | Fixed | Export can ship an incomplete or torn database: a TRUNCATE checkpoint blocked by a reader returns normally, the live main file is zipped with no snapshot while writers commit, and the pre-zip `quick_check` reads through the WAL so it cannot see either; on macOS the checkpoint runs before the save panel opens | `WhoopStore.swift` `checkpointWALImpl`; `DataBackup.swift` `runExport`, `writeVerifiedBackupZip` | P5 confirmed. V0: `CheckpointBusyTests` — with a reader holding an older snapshot, `checkpointWAL()` returned normally after the busy timeout and the main file copied alone was malformed (SQLITE_CORRUPT). Fix: exports zip a snapshot written through SQLite's backup API (`WhoopStore.writeSnapshot(to:)`), taken after the macOS save panel; `checkpointWAL()` throws `CheckpointBlocked`. V1: both tests pass and bite; `DataBackupLiveStoreTests` restores every row from a backup taken under a reader and a writer, and fails with the old checkpoint-and-copy path. AD-2. V3: `RealBackupGateTests` on three real backups (1.7M to 3.5M rows): the snapshot export, taken with a store open on the file, restores every row of every table. V2 (independent subagent): the snapshot is one consistent read (16 of 16 whole under a writer and a reader holding snapshots); follow-up for its finding that the copy needs as much free space as the store, filled the volume before failing (V0: SQLite error 13), and was reported as "try again in a moment": the copy now checks free space first and the export names the real reason. The space check has no automated test |  |
| W02-004 | S3 | Deferred | A restore swaps the file under both open pools and nothing closes them or relaunches: until the user quits, every offload stalls and every Repository write fails (mostly behind `try?`), while comments claim a restore forces a relaunch | `DataBackup.swift` `restore`; `BackupSettings.swift` `apply` comment | P5: the first pass's silent-loss claim is refuted for the real stack (writes through a pre-swap GRDB pool throw SQLITE_IOERR_VNODE, so the Backfiller holds acks). Degraded behaviour and a false claim remain. AD-2. Deferred 2026-09-25 (owner): to Phase 5 with W02-016; the fix is a single store owner that can close, swap and reopen the file. Until then writes after a restore fail loudly (the Backfiller holds acks) and the UI asks for a relaunch |  |
| W02-005 | S2 | Fixed | "Delete all of this device's data" and "Forget device" leave the device's computed `<id>-noop` rows (scored days, sleeps, workouts, metric series) on disk and on screen | `Strand/Data/DeviceRegistry.swift` `deleteDeviceData`, `forget`; `DeviceRegistryStore.swift` `deleteAllData` | P5 confirmed. V0: `testDeleteAllDataAlsoClearsTheComputedSibling` failed (the sibling row survived). Fix a617df30 cleared `<id>-noop`. V2 found a regression in it: the canonical `my-whoop-noop` also holds days scored from a re-added strap or another registered source, and hand-edited nights, so Forget on an archived `my-whoop` deleted them. Follow-up: the sibling is cleared only when it is the device's alone (a non-canonical id, or `my-whoop` with no other device registered), and user-edited nights are never cleared; three tests pin it and the regression test fails with the old rule. WhoopStore suite green. Multi-device remainder is W07-002 |  |
| W02-006 | S3 | Fixed | The #547 timestamp heal deletes every raw row before 2023-11-14 from every source, including imported workout-file HR, while it exempts imported computed rows | `TimestampHeal.swift` `healImplausibleTimestamps` | P5 confirmed with caveat: needs a heal re-run (a bad-clock sync) and an activity file older than the floor; owner logs show 0 implausible drops. V0: `TimestampHealTests.testImportedActivityHeartRateBelowFloorSurvives` failed (the imported row was purged). Fix: the far-past floor spares `WhoopStore.importedRawSourceIds`; the future bound still applies. V1: passes, bites, WhoopStore suite green; a StrandImport test pins the id to `ActivityFileImporter.sourceId` |  |
| W02-007 | S3 | Deferred | Deleted-sleep and dismissed-workout tombstones live only in UserDefaults, outside the database and the backup whitelist, so a restore on a new device re-detects nights and workouts the user deleted | `Repository.swift` `dismissedSleepSpans`; `WorkoutSource.swift` `dismissedDefaultsKey`; `BackupSettings.swift` | P5 confirmed with caveat: new device or fresh install only; `workouts.autoDetectDismissed` is a 30-day list and out of scope. AD-9 evidence. Deferred 2026-09-25 (owner): to Phase 4 with AD-9, which settles where durable decisions about rows live. Only a restore on a new device or a fresh install is affected |  |
| W02-008 | S3 | Fixed | Two pool writers on one file use deferred transactions, so a write transaction that reads first fails at once with SQLITE_BUSY while the other instance writes; the 5 s busy timeout never applies, and `IntelligenceEngine` swallows the failure | `WhoopStore.swift` `init(path:)`; `MetricsCache.swift` `upsertSleepSessions` | P5 confirmed. V0: `DatabasePoolConcurrencyTests.testReadFirstWriteWaitsForTheOtherInstancesWrite` failed in 0.2 s with `database is locked`. Fix: `defaultTransactionKind = .immediate` (GRDB's multi-writer setting). V1: passes, and failed before; WhoopStore suite green. Trade-off for V2: an immediate transaction holds the write lock through its read phase, so a long Repository read-then-write now makes a BLE write wait (up to the 5 s timeout) instead of failing itself. AD-2 |  |
| W02-009 | S3 | Deferred | A live store that fails to open (corrupt file, failed migration, locked data protection) leaves no visible state: `Repository` logs to NSLog and every read returns empty, so the app looks like a fresh install | `Strand/Data/Repository.swift` `ensureStore` | P5 confirmed. A NOTADB file is not quarantined (the probe returns early), so the open fails on every launch. Deferred 2026-09-25 (owner): to Phase 3 with AD-14 (the error policy), which owns how an open failure reaches the UI |  |
| W02-010 | S4 | Fixed | `WhoopStoreInfo.schemaVersion` is 18 while the schema is at 49, and that value goes into every backup manifest and every `APP_VERSION_CHANGED` event | `WhoopStore.swift` `WhoopStoreInfo`; `DataBackup.swift` `currentManifestJSON`; `AppModel.swift` | P5 confirmed (found by both slices). All 6 owner manifests say 18; nothing reads it back. Fix: `schemaVersion` is the registered migration count (49 today); four tests that pinned 18 removed; `SchemaOracleTests` pins it to the oracle's migration list, so reverting to 18 fails it. WhoopStore suite green |  |
| W02-011 | S4 | Fixed | The v48 and v49 migration comments justify the ECG purge with "the strap re-offloads v16 records on the next sync"; acked records are trimmed, so the purge was permanent | `Database.swift` v48, v49 comments | P5 confirmed. V0: the claim contradicts the trim-after-ack path (`Backfiller.finishChunk`) and `docs/PROTOCOL_ECG.md` makes no re-offload claim. Fix: the comments say the purge was permanent and the export escape needs the old build. Comment-only; migration bodies unchanged. Fork-only |  |
| W02-012 | S4 | Fixed | `StreamStore.insert` counts v18 aux rows offered, not accepted, so a re-offload prints `v18aux=N` as newly banked beside zeros | `StreamStore.swift` `insert(_:deviceId:…)` | P5 confirmed. V0: `DeepCaptureChannelsTests.testResyncReportsNoNewAuxRows` reported 2 on a duplicate insert. Fix: count `db.changesCount`, which also stops a re-offload spending the retention-sweep budget. V1: passes, failed before; WhoopStore suite green |  |
| W02-013 | S4 | Fixed | The step-revision cache witness is per `WhoopStore` instance, not per process as documented, so Repository's instance never sees BLEManager's step inserts | `Reads.swift` `stepDataRevisionSignature` | P5 confirmed with caveat: no wrong step count shown; the days witness still invalidates. Fix: the doc says per instance and names what does the invalidating. Doc-only; one shared store per process (W02-016) would make the component real. AD-2 |  |
| W02-014 | S4 | Fixed | The activity-file import comment says an identical timestamp overwrites; the insert keeps the first row, and its `try?` drops the HR silently while the import reports success | `Strand/Screens/DataSourcesView.swift` activity import | P5 confirmed. V0: `InsertTests.testDuplicateHeartRateKeepsTheFirstRow` pins first-wins (the comment claimed overwrite). Fix: the comment states first-wins, and a failed HR insert now fails the import through its existing catch instead of `try?`. Strand builds |  |
| W02-015 | — | Not a bug | The v36 migration's stored output depends on a helper that changed after it shipped | `Database.swift` v36 | P5 refuted: the divergence needs spaced capability tokens, which no Apple writer produces and the restore gate refuses from Android. All 49 migration bodies are otherwise unchanged |  |
| W02-016 | S3 | Reported | AD-2 Amend: one `WhoopStore` per process per path, immediate transactions, and a single owner that can close, swap and reopen the file for restore and snapshot it for export | `WhoopStore.swift` `StoreOpenGate`; `BLEManager.swift`, `Repository.swift` opens | Design row for the AD-2 verdict ([DECISIONS.md](../DECISIONS.md#ad-2)). `defaultTransactionKind = .immediate` can land first as a fix for W02-008; the shared instance is Phase 5 |  |
| W02-017 | S4 | Reported | A failed rollback still reports "Your existing data was kept" or "rolled back automatically and is unchanged": `rollBack` copies with `try?` and returns nothing, so a failed copy leaves an empty store on the next launch while the message names no side file | `DataBackup.swift` `rollBack`, restore failure messages | Found by V2 of W02-002 (pre-existing). Needs a Bool from `rollBack` and a message naming `whoop-replaced-*.sqlite` (new string) |  |
| W02-018 | S4 | Reported | The iOS export leaves the full `NOOP-backup-<date>.noopbak` in tmp after the share sheet, and the temp sweep never removes it (it matches a case-sensitive `noop-` prefix) | `DataBackup.swift` `runExport` iOS branch; `AppModel.swift` `isNoopTempScratch` | Found by V2 of W02-003 (pre-existing). A full copy of the health store sits in tmp until iOS purges it |  |
| W02-019 | S3 | Reported | The staging-build first-launch import copies the official app's live `whoop.sqlite`, `-wal` and `-shm` one at a time while that app may run; a checkpoint between the copies gives a malformed or short store | `Strand/Collect/StorePaths.swift` `importOfficialContainerStoreIfNeeded` | Found by V2 of W02-003 (pre-existing, same pattern). macOS fork staging builds only. `WhoopStore.writeSnapshot(ofDatabaseAt:to:)` now exists for exactly this |  |
| W02-020 | S4 | Reported | After "Delete all of this device's data" or "Forget device" the dashboard is not refreshed, so deleted scores stay on screen until the next refresh | `Strand/Data/DeviceRegistry.swift` `deleteDeviceData`, `forget` | Found by V2 of W02-005 (pre-existing). The Apple Health purge does refresh |  |

## Log

- 2026-09-25 — File created from the plan.
- 2026-09-25 — Phase 1 claimed. Passes 1 Map, 2 Static sweep, 3 Deep read and 5 Adversarial running as one multi-agent workflow (AD-2 evidence included); one writer records the results here.
- 2026-09-25 — Passes 1, 2, 3 and 5 done in workflow run `wf_f9451f0b-2c7` (two reviewers, one
  adversary). W02-001 found while building the gate test; W02-002 … W02-015 from the workflow (duplicates
  merged, W02-015 refuted by pass 5). Exit-gate half done: `RealBackupGateTests` passes on three real
  backups. Not covered: a stress run of offload inserts against a rescore, Repository write transactions
  longer than 5 s, the full-disk path, NoopLocalAccess opens (W5). Next: V0 (pass 4) for every `Reported` row.
- 2026-09-25 — Pass 4 and fixes: W02-002, W02-003, W02-005, W02-006, W02-008, W02-010 to W02-014 fixed; V2 by an
  independent subagent found a data-loss regression in the first W02-005 fix and three follow-ups in the backup
  fixes, all fixed; W02-017 to W02-020 added from V2. W02-004, W02-007 and W02-009 deferred by the owner. V3:
  `RealBackupGateTests` passes on three real backups after every fix. Branch `review/w02-fixes`. Next: batch
  check on the strap once merged, then W02-017 to W02-020.
