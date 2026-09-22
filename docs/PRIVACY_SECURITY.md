# Privacy & Security

This document describes NOOP's privacy posture, security model, and the hardening
applied to the parts of the codebase that touch untrusted input. It is written
against the actual source tree; file paths and identifiers below are real and can
be checked.

> **Not affiliated with WHOOP. Not a medical device.** NOOP is an independent,
> unofficial, local-first companion app. It interoperates with a WHOOP strap that
> **you own**, reading **your own** biometric data from **your own** device. It is
> not affiliated with, endorsed by, or connected to WHOOP, Inc. All computed
> outputs (Charge, Effort, Rest, HRV, SpO₂, skin temperature, respiratory rate — Charge/Effort/Rest
> being NOOP's own recovery/strain/sleep scores, not WHOOP's)
> are approximations and are not clinically validated. Self-tracking features such
> as the Mind / mood check-in and nutrition import are **informational only** and are
> **not** a diagnosis, treatment, or dietary/medical advice. Use at your own risk;
> your data stays on your device unless you explicitly export it or enable an optional network path.
> See `DISCLAIMER.md`, `TERMS.md`, and
> `ATTRIBUTION.md` at the repo root.

---

## 1. Design principle: offline by default

NOOP is **offline by default**. The biometric pipeline — strap → on-device decode →
local SQLite — has no network layer at all: no phone-home, no analytics, no accounts,
no login, no cloud sync, and no telemetry. Everything NOOP computes about you lives in a
single SQLite file on your own device.

There are exactly **two** network paths, both opt-in or switchable off: the **AI Coach** (§1.1a)
and the **update check** (§1.1b). The AI Coach is off until you turn it on with your own API key;
when you ask it a question it sends a short text summary of your recent metrics to the provider you
choose. The update check reads one public GitHub URL and can be turned off. Nothing else in the app
touches the network. (The default-off self-hosted push export permitted by [`SCOPE.md`](SCOPE.md)
and specified in [`PUSH_PROTOCOL.md`](PUSH_PROTOCOL.md) has no client in this tree.)

Data enters or leaves NOOP only through these explicit paths:

| Path | Transport | Direction |
|------|-----------|-----------|
| Live collection | Bluetooth LE, strap → device | Read-only from the strap |
| File import (Apple Health, WHOOP CSV, nutrition CSV, FIT / GPX / TCX) | User-selected files on disk | Read-only from disk |
| Apple Health export, incl. iOS "Export for Shortcuts" | On-device, user-initiated | NOOP → your Apple Health, on your device only (§1.3) |

The **network** paths are the opt-in AI Coach (§1.1a) and the update check (§1.1b); the
biometric pipeline produces no network traffic of any kind. The Apple Health export above is
an **on-device** hand-off, not a network upload — see §1.3.

### 1.1 Network code: the two exceptions

The biometric pipeline and all five Swift packages
(`WhoopProtocol`, `WhoopStore`, `StrandAnalytics`, `StrandImport`, `StrandDesign`)
contain **no** use of `URLSession`, `URLRequest`, `NWConnection`, `dataTask`, or any
other networking API. These Swift packages are **shared by the macOS and iOS apps** (iOS is
build-from-source only — no App Store / TestFlight — and was folded into the main tree in
v1.94), so the privacy behaviour described here applies equally to both. The networking
anywhere in the app is the AI Coach (`Strand/AI/AICoach.swift`), described in §1.1a, and
the update check (`Strand/System/UpdateChecker.swift`), described in §1.1b.

The package manifests reference dependency *download* URLs that Swift Package Manager
resolves at build time, never at runtime:

```
Packages/WhoopStore/Package.swift   → https://github.com/groue/GRDB.swift.git
Packages/StrandImport/Package.swift → https://github.com/weichsel/ZIPFoundation.git
```

GRDB.swift is the SQLite layer; ZIPFoundation is the archive reader used by the
importers. Neither opens a socket.

### 1.1a The AI Coach (optional, off by default, bring your own key)

The AI Coach lets you ask questions about your data in plain language. It is one of the two
network paths (the other is the update check, §1.1b), and only on your terms:

- **Off until you enable it.** You enter your own API key for the provider you choose
  (Anthropic, OpenAI, or a local / self-hosted OpenAI-compatible LLM such as Ollama or
  LM Studio). No key, no network calls, ever.
- **What is sent.** When you ask a question, NOOP builds a compact **text** summary of
  your recent metrics (Charge, Effort, Rest, HRV, resting HR over ~14 days, plus
  30-day averages and recent workouts) and sends it, with your question, directly to
  your chosen endpoint (e.g. `api.anthropic.com` / `api.openai.com` for the hosted
  providers). If you point the Coach at a local / self-hosted LLM, that endpoint is on
  your own machine and the request never leaves it.
- **What is NOT sent.** No raw biometric streams, no Bluetooth data, no account or
  device identifiers — only the summary text and your question.
- **Your key, your relationship.** The request goes from your device straight to the
  provider you picked, under your own account. NOOP runs no server in between and keeps
  no copy.

If you never enable the AI Coach and switch the automatic update check off (§1.1b), NOOP makes zero
application network connections.

### 1.1b The update check

NOOP is sideloaded on both platforms — there is no App Store to update it — so an install
that is never told about a release simply runs an old build indefinitely. Two paths address that, and
both read the **same** public endpoint: `https://api.github.com/repos/ryanbr/noop/releases/latest`.

- **"Check for updates"** in Settings → About. Runs only when tapped. It has always existed;
  it was previously undocumented here, which is why this section is new rather than merely amended.
- **"Check automatically"**, beside it. At most once a day, after onboarding (and, on iOS, after the
  Terms gate), NOOP reads that endpoint and — if a newer release exists — puts a row in the Updates
  inbox. **On by default**, and switchable off, at which point it makes no request at all.

What is sent: nothing. It is an unauthenticated `GET` of a public URL, carrying no identifier, no
account, no device information and no biometric data. What comes back is a version number and the
release notes. **It never installs anything** — on iOS no API permits that for a sideloaded app (see
[docs/IOS.md](IOS.md)); the row tells you a release exists and where to get it.

The request is a plain HTTPS call, so your IP address is visible to GitHub exactly as it would be if
you opened the releases page in a browser. If that is not a trade you want, turn the toggle off; the
manual button then remains the only way NOOP touches the network for this.

Code: `Strand/System/UpdateChecker.swift` + `Strand/System/UpdateAvailability.swift`.

### 1.2 The macOS sandbox (and what it means for the AI Coach)

On macOS the App Sandbox is the backstop. The app ships with a minimal entitlement set
(`Strand/Resources/Strand.entitlements`):

```xml
<key>com.apple.security.app-sandbox</key>                       <true/>
<key>com.apple.security.device.bluetooth</key>                  <true/>
<key>com.apple.security.files.user-selected.read-write</key>    <true/>
<key>com.apple.security.network.client</key>                    <true/>
```

That is the entire entitlement file. Four keys:

- **`app-sandbox`** — the process runs inside the macOS App Sandbox container.
- **`device.bluetooth`** — permits BLE access to talk to the strap. The matching
  `NSBluetoothAlwaysUsageDescription` string (declared in `project.yml`) states
  plainly: *"NOOP connects directly to your WHOOP strap over Bluetooth to read heart
  rate, R-R intervals, battery, and sensor data locally on your Mac. Nothing leaves
  your device."*
- **`files.user-selected.read-write`** — lets the app read import files the user
  explicitly picks (and write the database in its own container).
- **`network.client`** — outbound socket access. Added for the AI Coach on a
  signed/sandboxed build, where the sandbox otherwise refuses any socket the app tries
  to open (#128); the update check (§1.1b) relies on the same entitlement. The
  ad-hoc distributed build applies **no** entitlements at all (unsigned build + ad-hoc
  re-sign), so this key only matters for a signed/sandboxed build. The entitlement only
  permits the socket the sandbox would otherwise refuse — it doesn't make either feature
  call out on its own; the Coach stays off until you deliberately turn it on, and the
  automatic update check can be switched off.

Notably **absent**:

- `com.apple.security.network.server` — no inbound listener.
- No `files.downloads`, `files.documents`, or any broad filesystem entitlement —
  the app cannot wander the disk; it sees only what the user hands it through the
  open panel, plus its own sandbox container.

This is the structural guarantee behind "offline by default" on macOS: the sandbox
permits exactly the two exceptions above and nothing else — no
undeclared entitlement could smuggle out a connection the user didn't ask for. The
property is enforced by the OS, not merely by convention.

> **Note on Hardened Runtime.** `project.yml` currently sets
> `ENABLE_HARDENED_RUNTIME: NO` for local development builds. Distributable /
> notarized builds should enable the Hardened Runtime; it composes with, and does
> not weaken, the sandbox entitlements above.

### 1.3 iOS Apple Health export ("Export for Shortcuts") — on-device, user-initiated, one-way

On iOS NOOP can hand your metrics to **Apple Health**. This is the one path where data leaves
NOOP's own store — but it never leaves your **device**, and never touches the network.

- **You initiate it; NOOP writes only what you enable.** Nothing is exported automatically. You
  choose which metrics to push, and NOOP writes only those, only when you trigger the export. There
  is no background sync.
- **On-device, not a network upload.** The export is a local hand-off to Apple Health on the same
  phone. No NOOP server, no cloud, no telemetry is involved — consistent with §1.
- **HealthKit-free option.** The **"Export for Shortcuts"** path produces data for the Apple
  Shortcuts app rather than writing through HealthKit directly, so you can route it with a Shortcut
  you control. Where it does write to Apple Health, it does so through Apple's permission-gated APIs:
  you grant access per data type, and you can revoke it in iOS Settings at any time.
- **Once it's in Apple Health, it's yours and Apple's, not NOOP's.** NOOP cannot read back, manage,
  or delete what you exported; that store, its backups (e.g. iCloud Health if *you* enabled it), and
  its sharing settings are governed by Apple and by your choices. **You are responsible for the data
  you push into Apple Health and for anything you or your Shortcuts then do with it.** See
  `DISCLAIMER.md` §5.3 and `TERMS.md` §5.

---

## 2. Data at rest

### 2.1 Where the data lives

All durable data is stored in a single GRDB/SQLite database. The Swift apps (macOS and
iOS, which share the `WhoopStore` package) open it at (`Strand/Collect/StorePaths.swift`):

```
<Application Support>/OpenWhoop/whoop.sqlite
```

Because the app is sandboxed, `<Application Support>` resolves **inside the app's
sandbox container**, not the user's global `~/Library/Application Support`. Other
apps cannot read it through normal filesystem access.

The schema is defined by a versioned `DatabaseMigrator` in
`Packages/WhoopStore/Sources/WhoopStore/Database.swift` (currently schema version 9).
It holds exactly the kinds of data you would expect from the features:

- **Decoded biometric streams** (durable): `hrSample`, `rrInterval`, `spo2Sample`,
  `skinTempSample`, `respSample`, `gravitySample`, `battery`, `event`.
- **Derived/cached metrics**: `sleepSession`, `dailyMetric`, `workout`, `journal`,
  `appleDaily`, and the generic long-format `metricSeries`.
- **Your own entries and imports**: daily **mood check-ins** (the Mind feature) and imported
  **nutrition** figures (from a Cronometer / MacroFactor CSV) are stored the same way — locally, in
  this database, never transmitted. They are self-tracking notes, not clinical records (see
  `DISCLAIMER.md` §5).
- **A transient raw outbox** (`rawBatch`): compressed raw BLE frames, **prunable**.
- **Device records** (`device`): strap id, MAC, name, first/last-seen timestamps.

The database is opened in WAL journal mode with `synchronous = NORMAL` and a busy
timeout, tuned for bulk import/backfill writes
(`Packages/WhoopStore/Sources/WhoopStore/WhoopStore.swift`). WAL means you will also
see `whoop.sqlite-wal` and `whoop.sqlite-shm` sidecar files alongside the main
database — they live in the same container.

### 2.2 Encryption

The SQLite file is **not encrypted at rest by NOOP itself.** Confidentiality of the
data on disk relies on the platform:

- **FileVault** (full-disk encryption, on by default on modern Macs) protects the
  database whenever the disk is at rest / the machine is powered off. On iOS the
  equivalent is the platform's on-by-default data protection, which guards the file
  while the device is locked.
- The **sandbox container** (the app container on macOS and iOS) keeps other
  user-space apps from reading the file directly.

What this does **not** protect against: an attacker with your unlocked, logged-in
session, or a backup/Time Machine copy of the container made while FileVault is
unlocked. The data is plaintext SQLite once the volume is mounted.

> **Option: SQLCipher.** GRDB supports SQLCipher (an encrypted SQLite build) as a
> drop-in. Wiring NOOP's `DatabaseQueue` to a SQLCipher build with a
> Keychain-derived key would give at-rest encryption independent of FileVault. This
> is not enabled in the current build, but the persistence layer is small and
> centralized (one `WhoopStore.init(path:)`), so it is a contained change.

### 2.3 Data minimization & pruning

The raw-frame outbox (`rawBatch`) is treated as transient, not as the system of
record — the decoded streams are durable, the raw frames are a compressed,
**prunable** buffer. The prune policy in
`Packages/WhoopStore/Sources/WhoopStore/RawOutbox.swift` deletes old batches:

```sql
DELETE FROM rawBatch WHERE syncedAt IS NOT NULL AND syncedAt < ?
```

So raw captures do not accumulate forever. (The `syncedAt`/upload-related columns are
schema scaffolding inherited from the upstream collection library; in NOOP's offline
configuration nothing uploads, and the raw buffer is purely a local replay/recovery
aid.)

### 2.4 Diagnostics: the strap connection log

When a strap won't connect or behaves oddly, the single most useful thing a user can
send is the connection log. NOOP keeps one so it can be shared **without** needing
Xcode or a developer setup (this is what made issues #17/#18 reportable), and the same
log doubles as the primary tool for **debugging and protocol development** (see
[`BLE_REVERSE_ENGINEERING.md`](BLE_REVERSE_ENGINEERING.md)).

**What it is.** The BLE client (`Strand/BLE/BLEManager.swift`, shared by macOS and iOS)
keeps a **bounded, PII-redacted line buffer** (`LiveState.maxLogLines`) of the
connection's control flow: scan results (strap advertised name + RSSI), the
bond/handshake state machine, command names with their outbound payload **hex**, and
offload progress (trim cursors, chunk acks). On macOS the **Live** screen's Strap log
card offers **Copy** and **Save…**; on both platforms the Test Centre **Report** action
bundles a redacted copy into a `.zip` for a bug report. Nothing is uploaded by NOOP.

**What it does *not* contain.** No account credentials (there is no account), no
decoded biometric *values* (heart-rate numbers, R-R intervals, SpO₂, skin-temp are not
written to the log — only control-plane command names and frame-routing), and no
hello-token or serial hex (the handshake lines log *that* a step happened, not its
secret payload). The one mild identifier is the strap's advertised name (e.g.
`WHOOP 5AG…`), which the user chooses to include when they tap Share.

**Per-connect readouts are gated.** Verbose per-connect diagnostics sit behind the
Test Centre domains (Settings → Test Centre), so the default log carries the state
transitions and mismatches that identify a fault without flooding the buffer. The
diagnostic export works the same whether or not a Test Centre profile is on.

---

## 3. Threat model

NOOP parses two classes of **untrusted input**: bytes arriving over Bluetooth, and
files chosen for import. Both are treated as hostile and validated before anything
reaches the database. Apple Health and WHOOP files in particular can be very large
(multi-hundred-MB to multi-GB), so resource exhaustion is part of the model.

What is explicitly **out of scope**: NOOP cannot defend the data against an attacker
who already controls your unlocked user session (see §2.2), and it makes no claim of
cryptographic authentication of the strap — BLE pairing/bonding security is provided
by the OS Bluetooth stack and the device, not by NOOP.

### 3.1 Threat A: a malicious or malfunctioning BLE peer

A device advertising as a strap (or a glitching real strap) could send malformed,
truncated, oversized, or adversarial frames. The protocol core
(`Packages/WhoopProtocol/`) is the reverse-engineering layer and is the first line of
defense.

**Integrity-gated parsing.** Every frame is checked against its envelope before it is
allowed to drive any application state. `Framing.swift` implements two checksums
verbatim from the wire format:

- `crc16Modbus` over the six-byte WHOOP 5.0 / MG header (ported from the `goose` work),
- `crc32` (zlib/reflected) over the inner payload.

`verifyFrame(_:family:)` returns `ok == true` only when the header CRC, the payload
CRC32 **and** the configured size rules all hold. The size half matters as much as the
checksums: a frame must be at least 13 bytes (`FrameLimits.whoop5MinimumFrameBytes`) and
must carry *exactly* the total its length field declares (`declaredLength + 8`), so a
truncated frame and one with trailing bytes past its own end are both rejected. If the
payload CRC32 cannot be computed safely, the earlier size rule is the rejection reason;
every frame reaching the payload-integrity decision has a CRC result. The outcome is one
verdict plus one non-optional reason:

```swift
guard frame.count >= FrameLimits.whoop5MinimumFrameBytes else { /* reject minimum */ }
if total != frame.count { /* reject length; retain any safe CRC diagnostic */ }
let crc32OK = crc32(frame, 8, payloadEnd) == u32le(frame, payloadEnd)
let reason = integrityRejectReason(headerCRCOK: headerCRCOK, payloadCRCOK: crc32OK)
return FrameCheck(ok: reason == .none, /* … */ reason: reason)
```

The live BLE path then refuses anything that fails, in a single condition. In
`Strand/BLE/FrameRouter.swift`:

```swift
let parsed = parseFrame(frame, family: family)
// `ok` is the FULL verdict — never let bad bytes drive state.
guard parsed.ok else { return }
```

The same gate guards clock correlation (`Strand/Collect/ClockCorrelation.swift`),
historical-metadata classification, live and historical stream extraction, and the
data-range reply — so a corrupt frame can neither update the displayed metrics, nor
poison the device-clock model, nor advance the strap's trim cursor. `parsed.rejectReason`
carries the cause, so a rejection is counted and attributable rather than silent.

**What this does not claim.** A CRC is not a signature, so none of the above asserts
**authenticity**: a peer that forms the envelope correctly is not excluded. Nor is the
claim "every frame consumer" — six state-driving consumers require the full verdict.
Evidence-preserving readers deliberately keep the opposite direction: a raw history
frame that fails is *archived* rather than dropped, so the durable copy of a frame the
strap is about to release survives.

**Bounds-checked decoding.** Field reads never index past the end of the buffer, and
never reach into the frame's own CRC32 trailer. The low-level readers in
`Interpreter.swift` take an explicit `limit` and return `nil` instead of trapping:

```swift
@inline(__always) private func readU16(_ f: [UInt8], _ off: Int, _ limit: Int) -> Int? {
    off >= 0 && off + 2 <= limit ? Int(f[off]) | (Int(f[off + 1]) << 8) : nil
}
```

The `limit` is the **minimum** of where the trailer starts and how many bytes the frame
actually has. Both halves are load-bearing: the trailer start is derived from the
*declared* length and points past the buffer on a truncated frame, while the buffer size
alone would let a frame sitting at the family minimum have its own checksum trailer
decoded as a sequence number, a command byte or a metadata type. The argument is
required rather than defaulted, so adding a field read without deciding its bound does
not compile. The one deliberate exception is the 8-byte history-end acknowledgement
block echoed back to the strap verbatim, which reaches into the trailer by construction
and is an opaque echo rather than a decoded field.

Schema-driven field extraction skips any field whose offset is out of range
(`guard let val = readDType(frame, fld.off, dtype, limit) else { continue }`), the same
bound applies to the per-type post-hooks, and the `FieldBuilder` clamps every slice to
the real buffer length (`let end = min(off + length, frame.count)`). The WHOOP 5.0 path
adds explicit minimum-length and `payloadEnd <= frame.count` guards before slicing the
payload or trailer. A short or lying length field therefore yields a partial parse,
never an out-of-bounds read.

**Sane-value gating at the application edge.** Even a CRC-valid frame is range-checked
before it updates the UI/state. The realtime handler discards implausible heart rates
(`hr >= 30, hr <= 220`) and only overwrites R-R intervals when the frame actually
carries them — so a single bad-but-valid packet can't wipe good state.

**Reassembly is bounded by the declared length.** The `Reassembler` resynchronizes on
the `0xAA` start-of-frame byte, discards leading garbage, and only emits a frame once
the declared total is present — it does not unboundedly buffer arbitrary data. A
declared total below the 13-byte minimum or above
the 8192-byte ceiling is not a frame at all: that start byte is dropped and the scan
resyncs on the next one. Sub-minimum drops are counted rather than discarded silently.

### 3.2 Threat B: a malicious import file (zip bombs, XML bombs, huge exports)

Both importers live in `Packages/StrandImport/` and assume the file is hostile.

**Apple Health (`AppleHealthImporter.swift`).** Apple Health exports routinely exceed
1 GB, and a malicious one could be far worse.

- **Streaming SAX parse, never DOM.** The importer parses with `XMLParser` /
  `XMLParserDelegate` over an `InputStream` opened directly on the file. It explicitly
  does **not** use `XMLParser(contentsOf:)`, which would load the whole multi-hundred-
  MB document into memory first. Element handling runs inside a per-element
  `autoreleasepool` so temporaries from tens of millions of elements drain instead of
  accumulating — peak memory stays bounded regardless of file size.
- **Zip-bomb cap on decompression.** When the input is a `.zip`, `export.xml` is
  extracted to a temp file in fixed-size chunks with a running budget; the moment the
  decompressed total crosses the ceiling, extraction aborts:

  ```swift
  var written = 0
  let cap = 8 << 30   // 8 GB decompressed ceiling — zip-bomb guard
  _ = try archive.extract(entry, bufferSize: 1 << 20) { chunk in
      written += chunk.count
      if written > cap { throw ImportError.xmlParseFailed("export.xml too large") }
      try handle.write(contentsOf: chunk)
  }
  ```

  Chunks go straight to disk, so a bomb cannot inflate RAM. This deliberately replaced
  an earlier pipe-fed parser that could deadlock or crash on a malformed export.
- **Robust error handling.** Parse failures are surfaced as typed `ImportError`s; the
  delegate distinguishes a genuinely malformed document from a benign empty/EOF
  condition rather than crashing.
- **Temp files are cleaned up** via `defer { try? FileManager.default.removeItem(at: tmp) }`.

**WHOOP CSV export (`WhoopExportImporter.swift`).** The WHOOP data export is a small
bundle of CSV files, but the same defensive posture applies.

- **Per-entry size ceiling.** Each CSV is capped at 256 MB
  (`maxEntryBytes = 256 << 20`). Folder imports skip any file larger than the cap;
  zip imports reject entries whose *declared* uncompressed size exceeds it **and**
  enforce a running byte budget during extraction, so a ZIP64 header that lies about
  its size is still stopped mid-stream:

  ```swift
  let declared = Int(exactly: entry.uncompressedSize) ?? Int.max
  if declared > Self.maxEntryBytes { continue }
  ...
  if written > Self.maxEntryBytes { throw CancellationError() }
  ```

- **CRC32 verification on extraction.** `archive.extract()` verifies each entry's
  CRC32 (ZIPFoundation's `skipCRC32` defaults to `false`) and throws on a mismatch or
  truncation. A corrupt/truncated/oversized entry is skipped entirely rather than
  partially imported — no half-rows reach the database.
- **Filename allow-list.** Only four known CSV names
  (`physiological_cycles.csv`, `sleeps.csv`, `workouts.csv`, `journal_entries.csv`)
  are ever read; everything else in the archive is ignored. Matching is by filename,
  case-insensitively, so the parser never executes or interprets arbitrary archive
  members.
- **Tolerant, header-name-driven parsing.** Columns are matched by normalized header
  name (not position), every column is optional, BOMs are stripped, and rows with no
  usable timestamp are dropped. Malformed input degrades to fewer rows, not a crash.

**Nutrition CSV (`NutritionCsvImport.swift`).** The nutrition importer (Cronometer /
MacroFactor daily-summary exports) reuses the same shared CSV reader (`CSVParsing.swift`)
and the same tolerant posture: headers are matched case-insensitively by name (date /
calories / protein / carbs / fat / weight), every column is optional, non-`yyyy-MM-dd`
dates and value-less rows are **skipped and counted, never fatal**, and only the
recognised numeric fields are read — no archive member or cell is ever executed or
interpreted. The result is projected into the long-format `metricSeries` store under the
dedicated source id `nutrition-csv`, alongside your other metrics and entirely on-device.

---

## 4. What NOOP does *not* collect or transmit

- **No NOOP account, no NOOP login.** Nothing to sign into with NOOP itself; NOOP
  issues no credentials of its own.
- **No telemetry / analytics / crash reporting.** No third-party SDKs of that kind.
- **No NOOP cloud, account sync, or operated remote backup.** Your data leaves the device
  only when you export it yourself.
- **No advertising identifiers, no tracking.**
- **No WHOOP account or API credentials.** NOOP talks only to the strap over local
  BLE; it does not authenticate against, or pull from, any WHOOP server.

---

## 5. Hardening summary

| Surface | Risk | Mitigation | Where |
|---------|------|------------|-------|
| Process | Data exfiltration / network egress | Two explicit paths: AI Coach (your key, chosen provider, summary only — §1.1a) and the update check (unauthenticated public `GET`, switchable off — §1.1b). No NOOP server, account, or telemetry; ordinary BLE/offline use makes no application network request. | `Strand/AI/AICoach.swift`, `Strand/System/UpdateChecker.swift` |
| Filesystem | Broad disk access | Only `files.user-selected.read-write`; data stays in the sandbox container | `Strand.entitlements`, `Strand/Collect/StorePaths.swift` |
| BLE frames | Malformed / adversarial packets | CRC16-Modbus header + CRC32 payload gating; reject on failure | `WhoopProtocol/Framing.swift`, `Strand/BLE/FrameRouter.swift` |
| BLE frames | Out-of-bounds reads from short/lying length | `nil`-returning bounds-checked readers; slice clamping; min-length guards | `WhoopProtocol/Interpreter.swift` |
| BLE frames | Garbage / partial fragments | SOF-resync reassembler bounded by declared length | `WhoopProtocol/Framing.swift` (`Reassembler`) |
| App state | Implausible-but-valid values | Range gates (e.g. HR 30–220) at the state edge | `Strand/BLE/FrameRouter.swift` |
| Health import | XML bomb / multi-GB DOM blowup | Streaming SAX over `InputStream`; per-element autorelease pool | `StrandImport/AppleHealthImporter.swift` |
| Health import | Zip bomb | 8 GB decompressed ceiling, chunked to disk, hard abort | `StrandImport/AppleHealthImporter.swift` |
| CSV import | Zip bomb / oversized entries | 256 MB per-entry cap (declared + running budget); CRC32 verify | `StrandImport/WhoopExportImporter.swift` |
| CSV import | Arbitrary archive members | Filename allow-list; tolerant optional-column parsing | `StrandImport/WhoopExportImporter.swift` |
| Data at rest | Disk theft / offline access | Relies on FileVault + sandbox container; SQLCipher available as an option | `WhoopStore/WhoopStore.swift` |
| Diagnostics log | Leaking the strap log or secrets | Bounded, PII-redacted in-app buffer; shared only when the user copies, saves, or files a Test Centre report; no biometric values / tokens logged (§2.4) | `Strand/BLE/LiveState.swift` (`maxLogLines`, `redactPii`), `Strand/System/TestCentreReport.swift` |

---

## 6. Reporting a security issue

NOOP is a hobbyist, non-commercial interoperability and research project provided
**as-is, with no warranty**, for personal and educational use only (see
`DISCLAIMER.md`). If you find a security or privacy issue, please open a GitHub issue
describing the problem and a reproduction; sensitive reports can be coordinated
privately via the contact on the project's GitHub profile. Issues will be reviewed in
good faith.

---

## 7. Credits

The protocol and persistence work NOOP builds on is community reverse-engineering of
hardware the user owns, used for interoperability:

- **`johnmiddleton12/my-whoop`** — the original WHOOP BLE framing/command/decode work and
  the collection logic the `WhoopProtocol` / `WhoopStore` packages and the app's
  collection layer are adapted from (its WHOOP 4.0 envelope is no longer implemented
  here; the command and record conventions carried over to the 5.0/MG path).
- **`b-nnett/goose`** — the WHOOP 5.0 protocol (the `fd4b0001-…` service family, the
  CRC16-Modbus header, and the "puffin" packet types) the v5 decode path is ported
  from.
- **`groue/GRDB.swift`** — the SQLite persistence layer.
- **`weichsel/ZIPFoundation`** — the archive reader used by the importers.

See `ATTRIBUTION.md` and `DISCLAIMER.md` for the full attribution and good-faith
notice. NOOP contains no WHOOP proprietary code, firmware, binaries, logos, or
assets, and performs no DRM circumvention.
