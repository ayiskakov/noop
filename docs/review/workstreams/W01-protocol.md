# W1 — Protocol

**Phase** 1 · **Decisions** — · **Status** on the [board](../README.md#status-board) ·
**Method** [METHOD.md](../METHOD.md)

Turns raw BLE bytes into typed rows. Pure Swift, no CoreBluetooth, builds on Linux.
`Packages/WhoopProtocol`: 12.1k source lines, 12.0k test lines in 64 files.

## Read first

`docs/PROTOCOL.md` (index), `PROTOCOL_TRANSPORT.md`, `PROTOCOL_WHOOP5.md`, `PROTOCOL_SENSORS.md`,
`PROTOCOL_ECG.md`, `PROTOCOL_COMMANDS.md`, `PROTOCOL_IMPLEMENTATION.md`, `WHOOP5_DEEP_DATA.md`. The
protocol docs are authoritative: check them before deriving any layout from bytes.

## Where to start

Paths under `Packages/WhoopProtocol/Sources/WhoopProtocol/`.

| File | Symbols | Why |
|---|---|---|
| `Framing.swift` | `Reassembler`, `verifyFrame` | Fragment reassembly and CRC gate: every inbound frame passes here |
| `Interpreter.swift` | `parseFrame`, `mappedWhoop5HistoricalVersions`, `rejectedHistoricalRecords` | Frame → typed events; which historical layouts are decoded vs archived |
| `Schema.swift`, `Resources/whoop_protocol.json` | schema lookup | Schema-driven field decode |
| `Streams.swift`, `HistoricalStreams.swift` | `extractStreams`, `extractHistoricalStreams` | Live and historical stream extraction |
| `HistoricalMeta.swift`, `HistoricalLayoutSupport.swift` | `classifyHistoricalMeta` | Historical chunk classification, layout support table |
| `Whoop5RR.swift`, `Whoop5RawOptical.swift`, `Whoop5RawImu.swift` | layout decoders | R-R, optical and IMU layouts |
| `Whoop5Ecg*.swift` | R16 / R17 records, `Whoop5EcgSession` | MG ECG records and the capture state machine |
| `DeviceFamily.swift` | `forRegistryDevice(model:brand:)`, `confirmedRegistryFamily(model:brand:)` | The one canonical family resolver |
| `DeviceConfigWriteGate.swift` | write gate | Which config keys may ever be written |
| `FeatureFlagProbe.swift`, `DeviceConfigReadProbe.swift`, `R22Disable.swift` | probes | Large probe surfaces; must stay behind the write gate |

CLIs: `Sources/whoop-decode`, `Sources/whoop-re`, `Sources/whoop-optical-experiment`.
Tests: `Packages/WhoopProtocol/Tests/WhoopProtocolTests`.

## Contracts this area owns

- Every inbound frame is CRC-verified before any decode.
- An unmapped historical layout is archived through `rejectedHistoricalRecords`, never dropped. Mapping
  a version stops that archive, so a newly mapped layout needs a durable storage lane first (AD-6).
- Every offset traces to a protocol doc or a pinned oracle.
- No `import CoreBluetooth`, `AppKit` or `UIKit`; the package builds on Linux.

## Checks

- [x] CRC gate on every entry path: live, historical, CLI tools. Partial: live, historical, probes and CLIs
      gate; `Whoop5RawImu.decode` does not, and is reachable only through W06-002's dead path, so that fix
      must gate it.
- [x] Every mapped historical version has a decoder test on a real or constructed record. Pass (16, 18, 20,
      21, 26, all on real records).
- [x] `Reassembler` handles fragments out of order, duplicated, oversized length and truncated tail. Fail:
      W01-003.
- [x] Signedness and endianness per field match the docs (including 18-bit signed ECG samples). Pass for
      R16, R17, R18, R21, R26; R20 rests on its oracle JSON; widths in W01-006.
- [x] Strap-clock to Unix conversion covers clock unset and wrap. Pass; the records the gate refuses were
      lost (W01-004, fixed for type 47; EVENT frames still are, W01-012).
- [x] Probes cannot write anything outside `DeviceConfigWriteGate`'s allow-list. Pass: enforced inside
      `BLEManager.send()`.
- [ ] `swift build` on Linux still passes (not CI-enforced). Not run: no Linux host.
- [x] (added) No historical record is neither stored nor archived. Fail: W01-003, W01-004, W01-006,
      W06-003; W01-004's V2 adds W01-011 and W01-012.

## Review passes

- [x] 1 Map · [x] 2 Static sweep · [x] 3 Deep read · [ ] 4 Run · [x] 5 Adversarial

## Gate

`swift test`; oracle output pinned as a literal in a test; Linux build.

## Findings

| ID | Sev | Status | Finding | Location | Evidence | PR |
|---|---|---|---|---|---|---|
| W01-001 | — | Not a bug | v18 R-R may be 1/1024 s ticks, not ms | `Whoop5RR.swift` `milliseconds` | Identity (ms) since a78e2a66, as upstream. P5 check against the strap's own per-second HR: median R-R ratio 1.005 over 666 ten-minute buckets (ticks would give 1.024). Doc residue is W01-005 |  |
| W01-002 | — | Not a bug | v26 optical deltas stored without an absolute base | `Interpreter.swift` `decodeWhoop5HistoricalV26` | Fixed before the review by upstream picks 7bf1449b and fa35005e: `ppg_base_code` (u32, byte 23) stored as `PpgWaveformSample.baseCode`; the newest backup has 0 rows without it. Remaining v26 gaps are W01-006 |  |
| W01-003 | S3 | Verified | `Reassembler` emits any declared length without a header check, so a stray or garbled start-of-frame swallows up to 8 KB of the real frames behind it, and during an offload those records are acked away | `Framing.swift` `Reassembler.feed` | P5 confirmed. V0 oracle over real v18 frames: stray 8-byte tail then 12 frames gave 3 of 12 intact; one flipped length byte then 10 frames gave 1 of 10. Fix: upstream f15360da ported (CRC-16 header gate, drops folded into the reject tally), adapted to 5/MG only. V1: `ReassemblerTests` pins 12 of 12 and 10 of 10 on the real frames and fails with the gate forced open; WhoopProtocol suite green; Strand builds. Linux build not run (no host). The trigger was seen once before the fix: a 6,654-byte reject with a bad header checksum at an offload start in a 2026-09-23 owner log (the row said unobserved until V2). V2 (independent reviewer): 5,649 unique intact real frames of every type in the owner corpus pass the gate fed whole, at every two-way split and at every three-way split inside the header (9.35 M cases); a header drop discards one byte, so a frame starting inside a false header survives; the tests fail with the gate forced open. Sibling sweep: no 4.0 path reaches a 5/MG strap and the CLIs never reassemble; `Tools/linux-capture` lacks the gate (W01-014); a reassembler that outlives its link is W06-033. V3 (11.9.8 on the iPhone): 10 offload sessions, all ending HISTORY_COMPLETE; the v18 rows they delivered cover 826 of 826 seconds; 148 of 148 live IMU buffers intact; every dumped reject is an intact v20 or v21 record (W06-003). The header-drop tally prints only at link teardown and the run had none, so it is still unobserved on real traffic Batch check (2026-09-27, METHOD step 6): a full day and night on 11.9.11 and 11.9.12, which carry this batch. The 24-hour raw export holds 85,007 of 86,400 strap seconds, and the 1,393 missing are three off-wrist spells plus 6 s at clock steps (W06-050); offloads every 10 min end HISTORY_COMPLETE; 9 of 9 stored nights reproduce byte for byte under a V3 replay; recovery is scored on every day past the baseline warm-up; `RealBackupGateTests` passes on that export (49 → 49 migrations, 37 tables, 5.33 M rows). The header-drop tally has still not printed on real traffic (this log holds no link teardown). |  |
| W01-004 | S3 | Verified | An intact historical record refused by the #547 timestamp gate is neither stored nor archived, and its chunk is still acked, so the strap frees it | `HistoricalStreams.swift` `correctedWall`, `rejectedHistoricalRecords` | P5 confirmed with caveat: on 5/MG only the absolute floor and the future bound engage (the session-range half is never armed, `feedsSync: false`); 0 implausible-drop lines in owner logs. V0: oracle, re-dated v18 gave 0 rows and 0 archived. Fix: `rejectedHistoricalRecords` takes the extraction's gate inputs and archives an intact record the gate refuses, including v16 and v26; Backfiller passes them; its drop log says the raw records go to the archive. V1: `RejectedHistoryTests` (far past and future archived, a plausible one not) and fails with the check disabled; WhoopProtocol suite green; Backfiller app tests pass. AD-6. V2 (independent reviewer): real v16, v18, v20, v21 and v26 records re-dated far past, far future and before an armed session start are archived and not stored (248, 156, 2,531, 2,530 and 35 records); plausibly dated ones are stored and not archived; no record is both. The gaps it found are W01-011, W01-012 and W01-013. V3 (11.9.8): the gate refused nothing in the run, so the new path did not fire; the sync stored every record it decoded (see W01-003) Batch check (2026-09-27, METHOD step 6): a full day and night on 11.9.11 and 11.9.12, which carry this batch. The 24-hour raw export holds 85,007 of 86,400 strap seconds, and the 1,393 missing are three off-wrist spells plus 6 s at clock steps (W06-050); offloads every 10 min end HISTORY_COMPLETE; 9 of 9 stored nights reproduce byte for byte under a V3 replay; recovery is scored on every day past the baseline warm-up; `RealBackupGateTests` passes on that export (49 → 49 migrations, 37 tables, 5.33 M rows). The gate still refused nothing, so the new path has not fired on real traffic. |  |
| W01-005 | S4 | Fixed | The protocol docs and the inspector note say v18 R-R words are 1/1024 s ticks; the code (correctly) reads milliseconds | `docs/PROTOCOL_SENSORS.md` R18, `docs/protocol-examples/validate_examples.py`, `Interpreter.swift` rr note | P5 confirmed. Same text upstream. Fix: `PROTOCOL_SENSORS.md` packet 40 and R18 say milliseconds and record why; `PROTOCOL_CONCEPTS.md` notes that WHOOP 5/MG departs from the BLE unit; the tick arithmetic leaves `validate_examples.py`; the inspector note says the word is already milliseconds. V1: `Whoop5RRTests` asserts no R-R note mentions 1024, and fails with the old note. Hygiene gates pass |  |
| W01-006 | S3 | Verified | Mapped v16 and v26 records drop decoded bytes at trim: v16 bytes 26, 28, 29–31 and the per-slot reserved bits; v26 record index and footer bytes 75–82. A wrapped v26 burst counter of 0 is stored as NULL, and footer words are read as single bytes | `HistoricalStreams.swift` ECG and PPG lanes; `Streams.swift` `EcgCandidateSample`, `PpgWaveformSample` | P5 confirmed with caveat. Intact records that bank a row skip the reject archive, so these bytes have no copy after the ack; over 126 real v16 records two of the dropped fields vary. Contradicts the `EcgCandidateSample` doc. Merges W6 slice A #4. AD-6. Decision 2026-09-25 (owner delegated): a storage lane, not the raw archive, which is a rolling 5 MB file v20/v21 already saturate (W06-003). A migration adds a nullable `rawRecord` BLOB to `ecgCandidateSample` and `ppgWaveformSample` holding the full intact record, so no byte is lost at trim and no undocumented field is interpreted. V0 (2026-09-26): over the 214 distinct real v16 frames in the owner's reject archives, byte 29 takes 3 values and byte 30 takes 2, and no column holds either. Fixed: migration `v50-historical-raw-record` adds a nullable `rawRecord` BLOB to both tables; `extractHistoricalStreams` takes the chunk's frames index-aligned with the parse (the ingest fast path leaves `rawHex` empty) and each v16 or v26 row keeps its whole intact frame; the Backfiller and the archive replay pass them. Rows banked before v50 stay NULL; nothing is rewritten. The v26 burst counter's 0 → NULL and the byte-wise footer reads are unchanged, as decided; the bytes behind them are now kept. V1: `HistoricalRawRecordTests` (migration keeps v49 rows and adds a NULL column, insert round trip, NULL without a record, the first record of a second keeps its bytes), extraction tests on the real v16 and v26 fixtures, and `BackfillerRawRecordTests` (the offload's default extractor hands the frames over); dropping the frames in the extraction, the insert or the Backfiller each fails them. V3: all 214 real v16 frames through the new extraction bank 204 rows (10 empty records bank none, as before), each carrying its own frame, and re-decoding each stored frame rebuilds its row exactly; `RealBackupGateTests` on two real backups (49 → 50 and 46 → 50 migrations, 4.42 M and 1.66 M rows) round-trips every table V3 for v26 (2026-09-27 evening export, 11.9.13): the 154 v26 rows banked since the install each carry an intact 88-byte record (CRC valid, its own timestamp equals the row's, no two alike); the 25,060 rows banked before it stay NULL. The v16 half is still due: no ECG session since the install. V3 for v16 (2026-09-28 export, 11.9.13): an MG ECG session banked 38 v16 rows, each carrying an intact 1,584-byte record whose own timestamp equals the row's, no two alike; all 1,838 v26 rows and 38 v16 rows banked since the install carry their record, and none from before it do. V3 is complete for both halves; no independent V2 of the fix was recorded then. V2 (2026-09-30, independent subagent, as the code stands at b39d5a80): holds with caveats. Alignment is one-to-one at both production callers (the Backfiller's default extractor and the archive replay; no other caller exists), a skipped frame keeps its slot, and a count mismatch stores no frame, which the tests pin; a same-length reordered array would pass the guard, and no caller reorders (hardening idea: attach a frame only when its unix at byte 15 equals the row's ts). The insert is `ON CONFLICT DO NOTHING`, so a stored record is never overwritten with NULL; migration v50 is additive and pinned; backup is a whole-file copy and device delete removes whole rows. On a copy of the owner's 2026-09-30 backup, 7,531 v26 and 38 v16 rows carry records of 88 and 1,584 bytes, each with its own timestamp at byte 15 (0 mismatches). The caveats are W01-017 … W01-019 and W02-021 … W02-023. Verified: V1, V2 and V3 are recorded, and the batch check's day and night on the strap ran on 11.9.13 (the 2026-09-27 evening and 2026-09-28 exports). |  |
| W01-007 | S4 | Fixed | `verifyFrame` accepts 13–15-byte frames and bodies not padded to four bytes; `PROTOCOL_TRANSPORT.md` states a stricter rule and `PROTOCOL_IMPLEMENTATION.md` states 13 | `Framing.swift` `FrameLimits`, `verifyFrameWhoop5` | P5 confirmed with caveat: the 13-byte floor is a recorded empirical policy and both CRCs still gate; every real layout is 4-aligned. Fix: `PROTOCOL_TRANSPORT.md` keeps the construction rule and states the acceptance NOOP enforces (exact length, 13-byte floor, both CRCs, no alignment check), agreeing with `PROTOCOL_IMPLEMENTATION.md`. `FrameIntegrityTests.testAcceptanceMatchesTheDocumentedPolicy` pins 15-, 16- and 17-byte frames as accepted |  |
| W01-008 | S4 | Fixed | v18 byte 63 is published as `motion_wear_quality` with the note "2 = poor contact" beside `activity_class` "2 = run" | `Interpreter.swift` `decodeWhoop5Historical` | P5 confirmed with caveat: inspector-only; the duplicate key is deliberate, its note was wrong. Fix: the `motion_wear_quality` note names it the older name of `activity_class`; the key and its value are unchanged. V1: `Whoop5HistoricalTests.testByte63NotesAgree` fails with the old note |  |
| W01-009 | — | Not a bug | v18 bytes 61–62 and 64 (hardware step counter under software override) are not decoded or stored | `Interpreter.swift` step counter | P5 refuted: 151 unique real v18 frames (owner logs and fixtures) never set byte 64 or 61–62. Reopen if a capture shows the override |  |
| W01-010 | S4 | Reported | The reject tally misfiles the reassembler's own drops: of 133,131 false start bytes in a resync oracle, 82,078 hit the declared-length ceiling, which is not counted, 33,546 were counted as `belowMinimumLength`, and only 17,507 as header-checksum drops | `Framing.swift` `Reassembler.feed`; `FrameDiagnostics.swift` | Found by W01-003's V2. Diagnostics only: the readout under-reports resyncs and names the wrong reason |  |
| W01-011 | S4 | Reported | An intact v26 record whose inner record is under 21 bytes is neither stored nor archived: the v26 skip keys on the verdict and the gate, not on a row being banked, as the v16 branch already does | `HistoricalStreams.swift` `rejectedHistoricalRecords` v26 branch | Found by W01-004's V2 with a hand-built record. Every real v26 is 88 bytes, so no real record is known to be affected |  |
| W01-012 | S4 | Reported | EVENT frames (type 48) the #547 timestamp gate refuses are neither stored nor archived, while the Backfiller's drop line says the raw records go to the archive | `HistoricalStreams.swift`; `Backfiller.swift` drop log | Found by W01-004's V2: 7 of 7 real events, re-dated, were lost. The events leave strap flash at the ack |  |
| W01-013 | S4 | Reported | The Backfiller reads `Date()` for the timestamp gate separately from the extraction, so a record dated at the future bound can be refused by one read and not archived by the other when the second ticks between them | `Backfiller.swift` `finishChunk` | Found by W01-004's V2: a one-second window at `now + 86,400 s`. The one-clock rule in `AGENTS.md` |  |
| W01-014 | S4 | Reported | `Tools/linux-capture/whoop_frame.py` `Reassembler` has neither the header gate nor the length floor, so the Linux capture tool still loses the frames behind a stray start byte | `Tools/linux-capture/whoop_frame.py` | Found by W01-003's V2: 3 of 12 frames intact after a stray start byte, and 5,731 of 95,600 mid-frame cases lose a following frame. W11 owns the tool; recorded here beside its Swift twin |  |
| W01-015 | S4 | Reported | The reassembly docs describe the floor and ceiling but not the header gate: `PROTOCOL_IMPLEMENTATION.md` and `BLE_REVERSE_ENGINEERING.md` §Reassembly (the second still gives the 4.0 CRC8 and an 11-byte floor), `PRIVACY_SECURITY.md`, the `Reassembler` doc, and the `HistoricalStreams.swift` doc that calls a below-minimum drop the one way a frame can be lost; `Framing.swift` and `FrameDiagnostics.swift` still name Kotlin twins | docs; `Framing.swift`; `FrameDiagnostics.swift`; `HistoricalStreams.swift` | Found by W01-003's V2 |  |
| W01-016 | S4 | Reported | 5/MG EVENT payload bytes past the kind and the timestamp are dropped at decode for every kind but BATTERY_LEVEL. The decoder's comment says the other payloads are "intentionally left raw", but nothing keeps them | `Interpreter.swift` `decodeWhoop5Event`; the event extractors in `HistoricalStreams.swift` and `Streams.swift` | V0 (2026-09-27 export): 7,282 of 7,966 stored strap events have payload `{}`, and `rawBatch` is empty (raw capture is off by default). Lost with them: the `SET_RTC` payload, which could measure each clock set directly (W06-050), and every unnamed kind's bytes. The names stay unassigned on purpose (`docs/BLE_REVERSE_ENGINEERING.md`) | |
| W01-017 | S4 | Reported | A second distinct record in the same strap second is kept nowhere after the ack: the extraction emits both rows, the insert keeps the first (`ON CONFLICT(deviceId, ts) DO NOTHING`), and the reject classifier skips every intact v16 or v26 record that banks samples, on the premise that its row exists | `HistoricalStreams.swift` the v26 and v16 archive skips; `StreamStore.swift` the ecg and ppg inserts | V2 (2026-09-30, independent subagent, as the code stands at b39d5a80) of W01-006: a synthetic probe of two valid v26 frames with one unix gives 2 rows extracted, 1 stored, 0 archived. Predates W01-006. Not seen on real data: on the 2026-09-30 backup the record index accounts for every v26 record, with one gap explained by other record types sharing the counter |  |
| W01-018 | S4 | Reported | An intact v26 record that decodes no waveform is neither banked nor archived: the v26 archive skip tests only intact and timestamp-accepted, where the v16 skip also requires that the record banks a row (W06-129's reasoning) | `HistoricalStreams.swift` the v26 skip against the v16 skip | V2 (2026-09-30, independent subagent, as the code stands at b39d5a80) of W01-006: a synthetic 31-byte intact v26 is accepted, 0 ppg rows, 0 archived. Every real v26 seen is 88 bytes, so this is a code gap, not observed loss |  |
| W01-019 | S4 | Reported | v18 records drop bytes at trim with no raw copy, the direct sibling of W01-006: bytes 34–35 (an unnamed u16) and 19–20 have no column and no `V18AuxSlot` | `Interpreter.swift` the v18 decode; `HistoricalStreams.swift` the v18 lanes | V2 (2026-09-30, independent subagent, as the code stands at b39d5a80) of W01-006: a byte-coverage map over the three real v18 fixtures leaves bytes 19, 20, 34, 35 and 104 unconsumed and non-zero; 34–35 read 2683, 504 and 0, 19–20 read 0x4666, 0x4666 and 0x0a3d, 104 is a constant 0x01. `docs/PROTOCOL_SENSORS.md` places subseconds at 19–20 for the type-43 prefix; nothing found says so for type-47 v18. Three frames only (W01-009 refuted a neighbour on 151) |  |

## Log

- 2026-09-25 — File created from the plan. W01-001 and W01-002 carried over from upstream issues.
- 2026-09-25 — Phase 1 claimed. Passes 1 Map, 2 Static sweep, 3 Deep read and 5 Adversarial running as one multi-agent workflow; one writer records the results here.
- 2026-09-25 — Passes 1, 2, 3 and 5 done in workflow run `wf_f9451f0b-2c7` (one reviewer, one adversary).
  W01-001 and W01-002 closed as not a bug; W01-003 … W01-009 added (W01-009 refuted by pass 5). Strict-
  concurrency baseline reproduced (2 warnings, `whoop-re` error). Not covered: Linux build, R20 offsets
  re-derived from the doc, R22 and types 51/52 decode, `whoop_protocol.json` against the packet-40 offsets,
  format-2 frames. Next: V0 (pass 4) for every `Reported` row.
- 2026-09-25 — Pass 4 and fixes: W01-003 (upstream f15360da ported), W01-004, W01-005, W01-007, W01-008 fixed with
  tests that fail when reverted; WhoopProtocol suite, `StrandTests` and both app builds green. W01-006 decided
  (a `rawRecord` lane). Branch `review/w01-fixes`. Next: the W01-006 migration; a strap run for W01-003 and
  W01-004, which change what every BLE frame and every offloaded chunk goes through.
- 2026-09-25 — V2 of W01-003 and W01-004 by an independent reviewer: both hold. Six S4 candidates recorded
  (W01-010 … W01-015); the reconnect carry-over and the shared reassembler were filed as W06-033 and W06-034. V3
  from the 11.9.8 strap run: no frame lost on real traffic. Both stay `Fixed` until the batch check's day and
  night on 11.9.8. Next: the W01-006 migration.
- 2026-09-26 — W01-006 fixed on `review/w01-raw-record` (off main): the v16 and v26 rows keep their whole intact frame in
  a new nullable `rawRecord` column (migration v50), so no byte of a mapped record is lost at the trim ack. V0 on the
  owner's reject archives, V1 by mutation, V3 by a replay of every real v16 frame and the real-backup gate. No v26
  frame exists outside the test fixtures, so a strap sync is the v26 check: new rows carry an 88-byte record.
- 2026-09-27 — Owner's 2026-09-27 export (backup, strap log, 24-hour raw CSV; 11.9.11 then 11.9.12): the batch check passes, so W01-003 and W01-004 move to Verified with their caveats kept. W01-016 recorded from the stored events.
- 2026-09-27 — Owner's evening export on 11.9.13: W01-006's v26 half passes V3 (every new v26 row carries its record); the v16 half waits for an ECG session.
- 2026-09-28 — Owner's morning export on 11.9.13: an MG ECG session gave W01-006's v16 half its V3 (38 of 38 new v16 rows carry an intact record). The row stays Fixed until an independent V2 runs.
- 2026-09-30 — Independent V2 of W01-006 holds with caveats; W01-006 moves to Verified. W01-017 … W01-019 recorded from it, and W02-021 … W02-023 in W2.
