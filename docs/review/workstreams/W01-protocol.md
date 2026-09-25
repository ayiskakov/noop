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

- [ ] CRC gate on every entry path: live, historical, CLI tools.
- [ ] Every mapped historical version has a decoder test on a real or constructed record.
- [ ] `Reassembler` handles fragments out of order, duplicated, oversized length and truncated tail.
- [ ] Signedness and endianness per field match the docs (including 18-bit signed ECG samples).
- [ ] Strap-clock to Unix conversion covers clock unset and wrap.
- [ ] Probes cannot write anything outside `DeviceConfigWriteGate`'s allow-list.
- [ ] `swift build` on Linux still passes (not CI-enforced).

## Review passes

- [ ] 1 Map · [ ] 2 Static sweep · [ ] 3 Deep read · [ ] 4 Run · [ ] 5 Adversarial

## Gate

`swift test`; oracle output pinned as a literal in a test; Linux build.

## Findings

| ID | Sev | Status | Finding | Location | Evidence | PR |
|---|---|---|---|---|---|---|
| W01-001 | S2 | Reported | v18 R-R may be 1/1024 s ticks, not ms | `Whoop5RR.swift` (to confirm) | Upstream #1505; state in the fork unchecked | |
| W01-002 | S2 | Reported | v26 optical deltas stored without an absolute base | `Whoop5RawOptical.swift` (to confirm) | Upstream #2019; state in the fork unchecked | |

## Log

- 2026-09-25 — File created from the plan. W01-001 and W01-002 carried over from upstream issues.
