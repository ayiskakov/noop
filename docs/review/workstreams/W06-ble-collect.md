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
- [ ] Every path from frame to trim ack writes the cursor first; a failed cursor write holds the ack.
- [ ] Live frame types with no historical twin (realtime HR, ECG R17) are not lost at offload start or
      end (AD-5).
- [ ] Nothing bypasses the serial backfill drain; `Collector.flush` and `Backfiller.finishChunk`
      snapshot-and-clear before their first `await`.
- [ ] Keep-alive, reconnect and bond watchdogs cannot fight each other (#1635 shape).
- [ ] Main-thread cost of a full offload measured on the iPhone (AD-3).
- [ ] Each log line checked against what the code has actually observed at that point.

## Review passes

- [ ] 1 Map · [ ] 2 Static sweep · [ ] 3 Deep read · [ ] 4 Run · [ ] 5 Adversarial

## Gate

`StrandTests`; both app builds; a strap run on the iPhone with the strap log attached, and the PR says
exactly what was tested on hardware.

## Findings

| ID | Sev | Status | Finding | Location | Evidence | PR |
|---|---|---|---|---|---|---|
| W06-001 | S3 | Reported | GET_CLOCK reply dropped for 5/MG | `BLEManager.swift` handshake (to confirm) | Upstream #827; state in the fork unchecked | |

## Log

- 2026-09-25 — File created from the plan. W06-001 carried over from an upstream issue.
