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

- [ ] No existing migration was mutated (`git log -p` on `Database.swift`); each new one has a test.
- [ ] A copy of the newest real backup migrates to head, with row counts per table preserved.
- [ ] Every dedup, merge, heal and dismiss path has a test proving unrelated rows survive; window-wide
      deletes get extra scrutiny.
- [ ] Every key and hash that reaches disk is platform-stable (no `hashValue`).
- [ ] Backup export → import reproduces the same rows and settings; each whitelist kind matches how the
      app reads that key.
- [ ] Two `WhoopStore` instances on one file cannot run the migrator concurrently (AD-2).
- [ ] Prune never removes raw data for a chunk whose decoded rows are not committed.
- [ ] Integrity failure leads to a defined, visible outcome, not a crash or silent reset.

## Review passes

- [ ] 1 Map · [ ] 2 Static sweep · [ ] 3 Deep read · [ ] 4 Run · [ ] 5 Adversarial

## Gate

Migration test on a copy of a real backup; `.noopbak` round-trip; row-level diff.

## Findings

| ID | Sev | Status | Finding | Location | Evidence | PR |
|---|---|---|---|---|---|---|

## Log

- 2026-09-25 — File created from the plan.
