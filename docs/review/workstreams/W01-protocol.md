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
- [x] Strap-clock to Unix conversion covers clock unset and wrap. Pass; the records the gate refuses are
      lost (W01-004).
- [x] Probes cannot write anything outside `DeviceConfigWriteGate`'s allow-list. Pass: enforced inside
      `BLEManager.send()`.
- [ ] `swift build` on Linux still passes (not CI-enforced). Not run: no Linux host.
- [x] (added) No historical record is neither stored nor archived. Fail: W01-003, W01-004, W01-006,
      W06-003.

## Review passes

- [x] 1 Map · [x] 2 Static sweep · [x] 3 Deep read · [ ] 4 Run · [x] 5 Adversarial

## Gate

`swift test`; oracle output pinned as a literal in a test; Linux build.

## Findings

| ID | Sev | Status | Finding | Location | Evidence | PR |
|---|---|---|---|---|---|---|
| W01-001 | — | Not a bug | v18 R-R may be 1/1024 s ticks, not ms | `Whoop5RR.swift` `milliseconds` | Identity (ms) since a78e2a66, as upstream. P5 check against the strap's own per-second HR: median R-R ratio 1.005 over 666 ten-minute buckets (ticks would give 1.024). Doc residue is W01-005 |  |
| W01-002 | — | Not a bug | v26 optical deltas stored without an absolute base | `Interpreter.swift` `decodeWhoop5HistoricalV26` | Fixed before the review by upstream picks 7bf1449b and fa35005e: `ppg_base_code` (u32, byte 23) stored as `PpgWaveformSample.baseCode`; the newest backup has 0 rows without it. Remaining v26 gaps are W01-006 |  |
| W01-003 | S3 | Reported | `Reassembler` emits any declared length without a header check, so a stray or garbled start-of-frame swallows up to 8 KB of the real frames behind it, and during an offload those records are acked away | `Framing.swift` `Reassembler.feed` | P5 confirmed. Oracle over real v18 frames: stray 8-byte tail then 12 frames gives 3 of 12 intact; one flipped length byte then 10 frames gives 1 of 10. Upstream fixed it in f15360da (CRC-16 header gate), not yet picked. Trigger unobserved in owner logs |  |
| W01-004 | S3 | Reported | An intact historical record refused by the #547 timestamp gate is neither stored nor archived, and its chunk is still acked, so the strap frees it | `HistoricalStreams.swift` `correctedWall`, `rejectedHistoricalRecords` | P5 confirmed with caveat: on 5/MG only the absolute floor and the future bound engage (the session-range half is never armed, `feedsSync: false`). Oracle: v18 re-dated below the floor or 3 days ahead gives 0 rows, 0 archived. 0 implausible-drop lines in owner logs. Also found by W6 slice A. AD-6 |  |
| W01-005 | S4 | Reported | The protocol docs and the inspector note say v18 R-R words are 1/1024 s ticks; the code (correctly) reads milliseconds | `docs/PROTOCOL_SENSORS.md` R18, `docs/protocol-examples/validate_examples.py`, `Interpreter.swift` rr note | P5 confirmed. A contributor following the doc would shorten every stored R-R by 2.4 %. Same text upstream |  |
| W01-006 | S3 | Reported | Mapped v16 and v26 records drop decoded bytes at trim: v16 bytes 26, 28, 29–31 and the per-slot reserved bits; v26 record index and footer bytes 75–82. A wrapped v26 burst counter of 0 is stored as NULL, and footer words are read as single bytes | `HistoricalStreams.swift` ECG and PPG lanes; `Streams.swift` `EcgCandidateSample`, `PpgWaveformSample` | P5 confirmed with caveat. Intact records that bank a row skip the reject archive, so these bytes have no copy after the ack; over 126 real v16 records two of the dropped fields vary. Contradicts the `EcgCandidateSample` doc. Merges W6 slice A #4. AD-6 |  |
| W01-007 | S4 | Reported | `verifyFrame` accepts 13–15-byte frames and bodies not padded to four bytes; `PROTOCOL_TRANSPORT.md` states a stricter rule and `PROTOCOL_IMPLEMENTATION.md` states 13 | `Framing.swift` `FrameLimits`, `verifyFrameWhoop5` | P5 confirmed with caveat: the 13-byte floor is a recorded empirical policy and both CRCs still gate; every real layout is 4-aligned. Doc fix |  |
| W01-008 | S4 | Reported | v18 byte 63 is published as `motion_wear_quality` with the note "2 = poor contact" beside `activity_class` "2 = run" | `Interpreter.swift` `decodeWhoop5Historical` | P5 confirmed with caveat: inspector-only; the duplicate key is deliberate, its note is wrong. `Whoop5HistoricalTests` pins the key |  |
| W01-009 | — | Not a bug | v18 bytes 61–62 and 64 (hardware step counter under software override) are not decoded or stored | `Interpreter.swift` step counter | P5 refuted: 151 unique real v18 frames (owner logs and fixtures) never set byte 64 or 61–62. Reopen if a capture shows the override |  |

## Log

- 2026-09-25 — File created from the plan. W01-001 and W01-002 carried over from upstream issues.
- 2026-09-25 — Phase 1 claimed. Passes 1 Map, 2 Static sweep, 3 Deep read and 5 Adversarial running as one multi-agent workflow; one writer records the results here.
- 2026-09-25 — Passes 1, 2, 3 and 5 done in workflow run `wf_f9451f0b-2c7` (one reviewer, one adversary).
  W01-001 and W01-002 closed as not a bug; W01-003 … W01-009 added (W01-009 refuted by pass 5). Strict-
  concurrency baseline reproduced (2 warnings, `whoop-re` error). Not covered: Linux build, R20 offsets
  re-derived from the doc, R22 and types 51/52 decode, `whoop_protocol.json` against the packet-40 offsets,
  format-2 frames. Next: V0 (pass 4) for every `Reported` row.
