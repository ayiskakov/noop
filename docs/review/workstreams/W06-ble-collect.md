# W6 — BLE and collection

**Phase** 1 (safe-trim and backfill), 3 (the rest) · **Decisions** [AD-3](../DECISIONS.md#ad-3),
[AD-5](../DECISIONS.md#ad-5), [AD-6](../DECISIONS.md#ad-6) · **Status** on the
[board](../README.md#status-board) · **Method** [METHOD.md](../METHOD.md)

The only CoreBluetooth surface, plus live collection and historical offload. `Strand/BLE` 12.4k lines,
`Strand/Collect` 2.4k lines. No default CI; BLE behaviour is only proven on a real strap.

## Read first

`docs/CONTRIBUTING.md` §BLE safety contract, `docs/ARCHITECTURE.md` §5–6, `docs/PROTOCOL_COMMANDS.md`,
`docs/SAFEGUARDS.md`, `docs/RAW_DATA_CAPTURE.md`, and the `didBond` and diagnostics bullets in
`AGENTS.md`.

## Where to start

| File | Symbols | Why |
|---|---|---|
| `Strand/BLE/BLEManager.swift` (7.2k lines) | `peripheral(_:didUpdateValueFor:)`, `connectHandshakeDone`, `didBond`, `requestSync`, `startKeepAlive`, `startBackfillTimer`, `armBackfillTimeout`, `routeBackfillFrame`, `isOffloadFrame`, `stopUnexpectedRealtimeImu` | Handshake, bonding, watchdogs, keep-alive, live/historical split, fail-safes |
| `Strand/BLE/FrameRouter.swift` | `handle(frame:)` | Drives live UI state from every frame |
| `Strand/BLE/LiveState.swift` | published state | Bridge from BLE to SwiftUI |
| `Strand/BLE/Commands.swift` | command set | The curated command list |
| `Strand/BLE/SourceCoordinator.swift`, `StandardHRSource.swift`, `FTMSSource.swift`, `LiveHRSource.swift` | sources | Standard HR and fitness-machine sources |
| `Strand/BLE/StuckStrapDetector.swift` | detector | Reboot hint from `strap_trim` vs frontier |
| `Strand/BLE/HelloSuppression.swift`, `ClientHelloOutcome.swift`, `DisUnbondedRead.swift` | handshake variants | Paths that leave a strap deliberately unbonded |
| `Strand/Collect/Backfiller.swift` | `finishChunk`, `setCursor("strap_trim", …)` | Historical chunk assembly and the durable trim cursor |
| `Strand/Collect/Collector.swift` | `flush` | Live batch ingest |
| `Strand/Collect/RawHistoryArchive.swift` | archive | Unmapped layouts archived for later decode |
| `Strand/Collect/PrunePolicy.swift`, `ClockPolicy.swift`, `StorePaths.swift` | policies | Prune window, clock handling, file locations |

Tests: `StrandTests` (23 files match BLE, bond, hello, backfill, offload, trim, collector or raw
history); app tests only run under `xcodebuild … test`.

## Contracts this area owns

- No destructive command, ever; every non-trivial command is confirmation-gated and never sent
  automatically.
- The strap trims only after the `strap_trim` cursor is durable; every offload is resumable.
- Historical frames are processed in delegate order through one serial drain.
- A diagnostic line asserts only what it observed.

## Checks

- [ ] Inventory every command send site: automatic or user-initiated, gated or not.
- [ ] Every reader of `didBond`, and every watchdog, listed with its trigger and what it undoes.
- [x] Every path from frame to trim ack writes the cursor first; a failed cursor write holds the ack.
      Pass (insert, archive, raw, cursor, then ack; all 9 owner logs agree), but no test pins it (W06-007),
      it holds against app death only (W06-011), and the cursor is write-only (W06-016).
- [x] Live frame types with no historical twin (realtime HR, ECG R17) are not lost at offload start or
      end (AD-5). Pass for stored data: 0x2A37 never reads `backfilling`, and ECG R17 and the IMU flood are
      never diverted. Split defects: W06-009, W06-013, W06-015.
- [x] Nothing bypasses the serial backfill drain; `Collector.flush` and `Backfiller.finishChunk`
      snapshot-and-clear before their first `await`. Snapshot-and-clear passes in all three places; the
      single drain does not survive a disconnect (W06-008).
- [ ] Keep-alive, reconnect and bond watchdogs cannot fight each other (#1635 shape).
- [ ] Main-thread cost of a full offload measured on the iPhone (AD-3). Lead: W06-004.
- [ ] Each log line checked against what the code has actually observed at that point. Done for the
      safe-trim, backfill and split lines only (fail: W06-005, W06-016, W06-018); the rest is Phase 3.

## Review passes

Phase 1 part (safe-trim, backfill, live/historical split):
- [x] 1 Map · [x] 2 Static sweep (no app strict-concurrency build) · [x] 3 Deep read · [ ] 4 Run · [x] 5 Adversarial

Phase 3 part (the rest):
- [ ] 1 Map · [ ] 2 Static sweep · [ ] 3 Deep read · [ ] 4 Run · [ ] 5 Adversarial

## Gate

`StrandTests`; both app builds; a strap run on the iPhone with the strap log attached, and the PR says
exactly what was tested on hardware.

## Findings

| ID | Sev | Status | Finding | Location | Evidence | PR |
|---|---|---|---|---|---|---|
| W06-001 | S4 | Reported | GET_CLOCK reply dropped for 5/MG | `BLEManager.swift` 5/MG handshake; `FrameRouter.swift` `COMMAND_RESPONSE` | State confirmed: sent on every connect, the reply is only hex-logged (10 replies in owner logs), no decode sets a clock, `clockRef` stays nil. No effect on history dating (records carry unix seconds) or safe-trim, so lowered from S3; what remains is readout truth (W06-019), Phase 3 |  |
| W06-002 | S2 | Fixed | A Raw Data Collector session on a 5/MG never records an IMU sample: `ImuSessionFileStore.append` is reachable only through `Collector.ingest(frame:parsed:)`, which nothing calls | `Collector.swift` `ingest`, `recordGroundTruthImu`; `BLEManager.swift` 5/MG frame loop | P5 confirmed (found by W1 and W6). #1709 moved IMU storage behind an ingest seam 5/MG never enters; upstream has the same gap. V0: 0 production callers of `Collector.ingest(frame:parsed:)`, the only path to `ImuSessionFileStore.append`. Fix: the 5/MG frame loop calls `Collector.bankImuForSessions` for every frame, live and offload, gated to intact 1244-byte buffers. V1: `CollectorImuBankingTests` (intact banked, CRC-flipped refused); Strand and NOOPiOS (no watch) build. V3 pending: a Raw Data Collector session on the iPhone must report covered seconds |  |
| W06-003 | S3 | Reported | Mapped v20 (optical) and v21 (IMU) have no storage lane: every record goes to the 5 MB rolling reject archive, which one sync saturates, so only the newest ~630–720 of each survive after the strap has trimmed them | `Interpreter.swift` `mappedWhoop5HistoricalVersions`; `HistoricalStreams.swift` `rejectedHistoricalRecords`; `RawHistoryArchive.swift` | P5 confirmed with caveat: nothing consumes v20/v21, so no shown metric is wrong; a retention decision is missing. Every line in the 9 archives in the repo root is type 47 v16, v20 or v21. Root cause of W06-004 and W06-005. AD-6 |  |
| W06-004 | S3 | Reported | Every over-cap reject-archive rewrite runs on the main actor (about 290 ms for a 5 MB archive on an M-series Mac) and, with v20/v21 holding the archive at cap, recurs every 7–8 chunks through an offload | `RawHistoryArchive.swift` `archive`, `evictLines`; `Backfiller.swift` `rejectedSink` | Found by pass 5 (missed by pass 3). AD-3 evidence; measure on the iPhone in Phase 3 |  |
| W06-005 | S3 | Reported | Every sync that carries v20/v21 records ends with the error "couldn't be decoded (unrecognised strap firmware layout) … saved on this Mac", on iOS too; the strap log calls them "CRC/unmapped layout", and Sleep's freshness note takes its sync-failed branch | `BLEManager.swift` `exitBackfilling`; `Backfiller.swift` `finishChunk` log | P5 confirmed (found by W1 and W6). 410 such lines across 9 owner logs; 181 of 193 dumped rejects are intact v20 or v21 |  |
| W06-006 | S3 | Reported | A session whose persist stalled (acks held after a store failure) never surfaces as an error on 5/MG: HISTORY_COMPLETE stamps `lastSyncedAt`, and both timeout branches clear `lastSyncError` | `BLEManager.swift` `exitBackfilling`, backfill timeout | P5 confirmed, broader than first reported. `persistStalled` reaches only a debug-export key |  |
| W06-007 | S3 | Reported | No test pins any hold-ack path of the safe-trim invariant (insert, archive, raw or cursor failure; `persistStalled` holding a later empty END); the `SpyBackfillStore` the Backfiller doc names does not exist | `Backfiller.swift` `finishChunk`; `StrandTests` | P5 confirmed: deleting any `return` after a catch in `finishChunk` still passes every test |  |
| W06-008 | S3 | Reported | The single-drain contract breaks across a disconnect: `didDisconnectPeripheral` clears `backfillDraining` while a drain can still be suspended in `finishChunk`, so a reconnect starts a second drain and an END can be acked before the records it covers are ingested | `BLEManager.swift` `didDisconnectPeripheral`, `routeBackfillFrame`, `drainBackfillFrames` | P5 confirmed with caveat (found by both slices). A twin shows reordering; needs a `finishChunk` suspended across a full reconnect plus strap pipelining, neither proven on hardware |  |
| W06-009 | S3 | Reported | `isOffloadFrame` omits type 52 (HISTORICAL_IMU_DATA_STREAM, which the Android twin routes to the Backfiller) and 54; such frames go to the live router, which drops them, and the END ack frees them | `BLEManager.swift` `isOffloadFrame` | P5 confirmed with caveat (found by both slices): 0 type-52 frames in owner logs. The archive filter is type-47-only, so routing alone would not keep the bytes |  |
| W06-010 | S3 | Reported | On the over-cap path a failed read of the reject archive is treated as empty, and the atomic rewrite replaces every archived line while returning `.written` | `RawHistoryArchive.swift` `archive` | P5 confirmed with caveat. Twin: 8 lines, file made unreadable, one more append leaves 1 line. Credible trigger: an archive under Complete protection from a pre-#1138 build, read during a locked background relaunch |  |
| W06-011 | S3 | Reported | The ack goes out before the chunk is durable against power loss or a kernel panic: WAL with `synchronous=NORMAL`, an archive append with plain `fsync` (not `F_FULLFSYNC`), and an over-cap rewrite with none | `WhoopStore.swift` `init(path:)`; `RawHistoryArchive.swift` `archive` | P5 confirmed with caveat: a documented trade-off and safe against app death; AD-6 should say so or use FULL for the offload writer |  |
| W06-012 | S3 | Reported | A WHOOP-to-WHOOP switch attributes the previous strap's buffered live rows and an in-flight historical chunk to the new strap | `SourceCoordinator.swift` `switchToWhoop`; `BLEManager.swift` `setActiveDeviceId`; `Collector.swift`; `Backfiller.swift` | P5 confirmed with caveat: needs two registered WHOOPs and a switch mid-offload; the code comments already concede the case |  |
| W06-013 | S3 | Reported | After an offload ends early, historical EVENT frames reach `FrameRouter.handle`, whose EVENT branch has no age gate: an old double tap becomes a phantom action, and a replayed event can re-kick the aborted sync | `BLEManager.swift` `abortBackfill`; `FrameRouter.swift` EVENT branch | P5 confirmed with caveat: needs the strap to ignore the unconfirmed abort opcode, or a `finishChunk` that completes after the timeout exit |  |
| W06-014 | S3 | Reported | `bootstrapStore` checks `collector == nil` before two awaits, so an iOS state-restoration relaunch can run it twice: two stores open, buffered HR in the first Collector is dropped, and the second Backfiller can end a running offload or ack an END with an empty chunk | `BLEManager.swift` `bootstrapStore` | P5 confirmed with caveat and rated S4; kept at S3 because acking an empty chunk frees records. The window is the store-open time before the first offload |  |
| W06-015 | S4 | Reported | During an offload, live EVENT side effects (charging, battery, alarm fired, bonded) are suppressed, and events queued behind a processed HISTORY_COMPLETE are discarded | `BLEManager.swift` offload branch, `exitBackfilling` | P5 confirmed with caveat: transient live state; the events stay banked in flash |  |
| W06-016 | S4 | Reported | The `strap_trim` cursor is write-only, yet code and docs call it what makes the offload resumable, and a failed write of it still stalls history; the ack is fire-and-forget, and `lastAckedTrim` and `syncChunksThisSession` count acks that `send()` dropped | `Backfiller.swift`; `BLEManager.swift` `ackHistoricalChunk` | P5 confirmed: 0 production reads of `cursor("strap_trim")`. AD-6 |  |
| W06-017 | S4 | Reported | With raw capture on, the historical raw batch id is keyed on the trim alone and inserted `ON CONFLICT DO NOTHING`, so chunks sharing a trim (sentinel ENDs) lose their raw frames silently | `Backfiller.swift` raw enqueue; `RawOutbox.swift` `enqueueRawBatch` | P5 confirmed with caveat: raw capture is off by default; 0 sentinel ENDs in owner logs |  |
| W06-018 | S4 | Reported | The unexpected-realtime-IMU fail-safe cannot send anything on 5/MG (its guard and the `send()` allowlist exclude each other), yet logs "stop requested" every 30 s | `BLEManager.swift` `stopUnexpectedRealtimeImu`, `send` allowlist | P5 confirmed: 128 firings, 0 writes. Wiring it would send an automatic stop, which the BLE contract forbids; the fix is the log line or removal |  |
| W06-019 | S4 | Reported | The 5/MG "Clock latched" readout says "no (records dated 1970/71)" after any decoded offload: a sentinel `StrapRange(newestUnix: 0)` is read as a date, while `rtcWarning` on the same card ignores 0 | `LiveState.swift` `setStrapFirmwareLayout`; `ConnectionReadout.swift` `clockLatchedLabel` | P5 confirmed. Two readouts of one fact disagree on the Devices card |  |
| W06-020 | S4 | Reported | `ARCHITECTURE.md` §4–5, AD-5 and in-code comments describe a live/historical split the 5/MG code does not have; the Collector's puffin ingest, flush and clock path have no caller | `docs/ARCHITECTURE.md`; `BLEManager.swift`; `Collector.swift` | P5 confirmed. Feeds the AD-5 amendment and W12 |  |
| W06-021 | S4 | Reported | `StuckStrapDetector` is inert on 5/MG: `strapNewestTs` is never set, `strapNeedsReboot` has no reader, and its recovery sends a command the 5/MG allowlist drops | `StuckStrapDetector.swift`; `BLEManager.swift` `checkStrapLiveness` | P5 confirmed. Dead code; fork-only |  |
| W06-022 | S4 | Reported | `ClockPolicy.shouldSetClock` has had no caller since a5ad278c, and its doc contradicts the 5/MG path, which sets the clock on every connect | `ClockPolicy.swift` | P5 confirmed. Dead code; fork-only |  |
| W06-023 | S4 | Reported | AD-5 Amend: the architecture doc and AD-5 describe the split the code has; `isOffloadFrame` is pinned by a test; EVENT side effects gate on event age; the drain carries a generation token | `BLEManager.swift` frame loop; `docs/ARCHITECTURE.md` §4–5 | Design row for the AD-5 verdict ([DECISIONS.md](../DECISIONS.md#ad-5)); the fixes are W06-008, W06-009, W06-013, W06-020 |  |
| W06-024 | S3 | Reported | AD-6 Amend: restate safe-trim as "every record the strap will free is in a durable lane or the archive before the ack"; no layout is mapped without a lane; the archive never evicts records NOOP understands | `Backfiller.swift` `finishChunk`; `HistoricalStreams.swift` `rejectedHistoricalRecords`; `RawHistoryArchive.swift` | Design row for the AD-6 verdict ([DECISIONS.md](../DECISIONS.md#ad-6)); covers W01-003, W01-004, W01-006, W06-003, W06-010, W06-011, W06-016. Hold-ack tests (W06-007) first |  |

## Log

- 2026-09-25 — File created from the plan. W06-001 carried over from an upstream issue.
- 2026-09-25 — Phase 1 claimed. Passes 1 Map, 2 Static sweep, 3 Deep read and 5 Adversarial running as one multi-agent workflow over the safe-trim and backfill part only (AD-5, AD-6 evidence included); one writer records the results here.
- 2026-09-25 — Phase 1 part: passes 1, 2, 3 and 5 done in workflow run `wf_f9451f0b-2c7` (two reviewers,
  one adversary). W06-001 state confirmed and lowered to S4; W06-002 … W06-022 added (duplicates across
  the two slices and W1 merged). Not covered: strap-side semantics (does the strap pipeline chunks before an
  ack; a second HISTORY_START mid-session), the kill-mid-offload strap run, R22 deep-data routing, the RR
  source-precedence read filter. Next: V0 (pass 4) for every `Reported` row; the hold-ack tests (W06-007)
  come before any fix in this area.
