# Review method

How every workstream is reviewed, how every finding is validated, and the commands for each gate.

## The five review passes

Each workstream goes through the same five passes, ticked in its workstream file. The later passes
exist because a read-only review misses what only running the code shows.

1. **Map.** Trace the entry points and data flow. List the area's contracts: what it writes to disk,
   what it shows on screen, what it sends to the strap.
2. **Static sweep.** Build with `-strict-concurrency=complete` as warnings, run the pattern scans in
   [`BASELINE.md`](BASELINE.md), `doc_comment_lint` and the i18n audit. Triage every hit into finding or
   noise.
3. **Deep read.** Read the code against the concern checklist below, one concern at a time rather than
   one file at a time.
4. **Run it.** Tests, oracle twins, the sleep replay harness over the `.noopbak` backups, strap-log
   replay, and Instruments where performance is in question.
5. **Adversarial pass.** An independent reviewer (`/code-review high` on the area, or a fresh
   subagent) tries to refute each finding and to find what the first pass missed.

## Concern checklist

| Concern | What to check | How |
|---|---|---|
| Time and units | Day boundaries (local day key vs UTC), DST days, time-zone changes, ms vs 1/1024 s ticks, strap clock vs phone clock | Tests on DST and zone-change fixtures; oracle runs |
| Numeric edges | Empty input, one sample, gaps, NaN and infinity, integer traps, `?? 0` hiding missing data as a real zero | Oracle over the whole input space or a wide spread |
| Stored-data contracts | Append-only migrations, backup whitelist, stable hashes, natural keys, device partition | Migration tests; backup round-trip; grep for `hashValue` near writes |
| Concurrency | State read before an `await` and used after it, duplicate or leaked `Task`s, cancellation, `@unchecked Sendable` without a lock | Strict-concurrency warnings; stress tests; Thread Sanitizer on the macOS app |
| BLE safety | Curated command list, confirmation gates, `didBond` readers, what each watchdog undoes | Strap run with the log; command-site inventory |
| One fact, one readout | Same value resolved twice, two clocks, a countdown for an event that will not happen | Resolver trace per card; single-resolver assertion test |
| Performance | Main-thread database reads, O(n²) loops over a day of 1 Hz samples (86,400 rows), view bodies that recompute analytics | Instruments; timing tests on a full-day fixture |
| Errors and observability | `try?` swallowing a write, `fatalError` reachable from bad data, log lines that claim more than they saw | Call-site inventory; fault-injection tests |
| Privacy and network | Default-off, user-initiated, exactly what leaves the device | Payload capture with a local proxy |
| Design system and i18n | Tokens only; every string in the catalogue | Token scan; `Tools/i18n_audit.py --ci` |
| Tests | A test fails without the fix; tests assert behaviour, not implementation; `StrandTests` actually run | Revert-the-fix check; `xcodebuild test` |
| Dead code | Removed-device remnants, probes and toggles nobody reads, unreachable branches | Unused-symbol scan; grep for flag readers |

## Validation protocol

A finding is validated four times: once before the fix to prove it is real, and three times after to
prove the fix works, holds up to an independent reviewer, and survives real data. A batch then gets
one more check on the strap before its findings are closed.

```
V0 Reproduce ─▶ Fix ─▶ V1 Author check ─▶ V2 Independent review ─▶ V3 Real data ─▶ Batch check
                 ▲            │                     │                     │
                 └────────────┴───── any failure ───┴─────────────────────┘
```

1. **V0 Reproduce.** Write the failing test, or run the code standalone as an oracle
   (`swiftc -O twin.swift main.swift -o t && ./t`), or quote the log that shows the fault. Mark the
   finding confirmed, confirmed with caveat, or not a bug. Nothing is fixed on the strength of reading.
2. **Fix.** Make the smallest correct change. Correctness fixes land before refactors. A refactor must
   be behaviour-preserving: pin current output with characterisation tests first, then show zero diff.
3. **V1 Author check.** The reproducing test passes. Reverting the fix makes it fail again, which
   proves the test bites. The package suite passes, and both app targets build when app code changed.
4. **V2 Independent review.** A reviewer who did not write the fix tries to refute it, and sweeps for
   the same bug pattern in sibling code. Any hit becomes a new finding row.
5. **V3 Real data.** Run the change over real inputs: the replay harness over the newest `.noopbak`
   with every changed derived row explained; a strap run on the iPhone for BLE; device screenshots for
   UI.
6. **Batch check.** After a batch merges: full package suites, `StrandTests`, both app builds, then one
   full day and night on the strap with the new build (offload, sleep, recovery). The batch's findings
   move to `Verified` only then.

Every pass records its numbers in the finding's record, before and after, so a later regression can be
compared against them.

### Minimum evidence by change type

| Change type | Required before `Verified` |
|---|---|
| Pure package logic | `swift test`; oracle output pinned as a literal in a test; Linux build for `WhoopProtocol` |
| Stored data (migration, backup key, hash) | Migration test on a copy of a real backup; `.noopbak` export → import round-trip; row-level diff |
| Analytics formula | Oracle over the input space or a wide spread; replay-harness diff over backups; SleepBench / SleepPSG for any stager change |
| App-target Swift | `xcodebuild` for `Strand` and `NOOPiOS`; `StrandTests` run, not just written |
| BLE path | Strap run on the iPhone with the strap log attached; PR says exactly what was tested on hardware |
| UI | Tokens only; i18n gate passes; light and dark screenshots on a device |
| Refactor | Characterisation tests before; zero behaviour diff after, including an empty replay diff |

## Severity

- **S1 Critical:** corrupts or loses stored data, can harm the strap, or crashes on real data.
- **S2 High:** stores or shows a wrong metric or score, leaks data off the device, or breaks a BLE path.
- **S3 Medium:** wrong only in an edge case, degrades behaviour, or is a design flaw that has already
  produced a bug.
- **S4 Low:** a doc, log or UI claim the code does not back; dead code; low-risk cleanup.

Severity on a `Reported` row is provisional until V0.

## Finding status

```
Reported ──▶ Reproduced ──▶ Fixing ──▶ Fixed ──▶ Verified
   │              │            ▲          │
   ▼              ▼            └── a pass fails
Not a bug      Deferred (owner decision, reason required)
```

## Finding record

The workstream table holds one row per finding. The full record goes in the fix commit message and PR
description (trimmed of health data), in this shape:

```markdown
### W06-003 — <one-sentence claim>
- Severity: S2 · Category: bug | risk | design | truth · Upstream-able: yes | no
- Location: `Strand/BLE/BLEManager.swift` `symbolName`
- Reproduction: <input or state> → <wrong output>; expected <right output>
- V0: <test name or oracle command + output>
- Fix: <commit>
- V1: test passes; reverted fix fails it (<test name>)
- V2: <reviewer, result, sibling sweep result>
- V3: <replay diff / strap run / screenshots — counts only, no health data>
```

## Commands

Run from the repo root unless noted.

```bash
# Pure packages (CI runs these on macos-15)
(cd Packages/WhoopProtocol && swift build && swift test)
# … same for WhoopStore, StrandAnalytics, StrandImport, StrandDesign, NoopLocalAccess

# Tools packages
(cd Tools/SleepBench && swift build && swift test)
(cd Tools/SleepPSG && swift build && swift test)
(cd Tools/Backfill && swift build)          # no test target

# macOS app build + StrandTests (app-build.yml runs these on every app-path PR; run them locally first)
xcodegen generate
xcodebuild -project Strand.xcodeproj -scheme Strand -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
xcodebuild -project Strand.xcodeproj -scheme Strand -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test

# NOOPiOS on a Mac without a watchOS runtime: build a no-watch variant.
# 1. Copy project.yml, delete the `- target: NOOPWatch` dependency under NOOPiOS,
#    rename `name: Strand` to `name: StrandNoWatch`.
# 2. xcodegen generate --spec <copy> --project-root . --project .
# 3. xcodebuild -project StrandNoWatch.xcodeproj -scheme NOOPiOS \
#      -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
# 4. rm -rf StrandNoWatch.xcodeproj   — and say in the PR that the watch app was not built.

# Strict-concurrency sweep (warnings only; count and triage)
(cd Packages/WhoopStore && swift build -Xswiftc -strict-concurrency=complete 2>&1 | grep -c 'warning:')

# Hygiene gates (the ones CI runs)
python3 Tools/doc_comment_lint.py
python3 docs/protocol-examples/validate_examples.py
python3 docs/protocol-examples/check_source_references.py
python3 Tools/i18n_audit.py --ci origin/main      # the base your branch diffs against
(cd Tools && python3 -m unittest -v $(ls test_*.py | sed 's/\.py$//'))
(cd Tools/linux-capture && python3 -m unittest discover -p "test_*.py")

# Sleep stager validation (datasets live outside the repo, in ~/datasets/noop-sleep/)
(cd Tools/SleepPSG && swift run -c release sleeppsg --dataset <sleep-accel root> --section baseline)
```

**Replay harness (analytics and data-layer changes).** Unzip a `.noopbak` into a scratch directory,
open a copy with `WhoopStore(path:)` (it migrates), read each night's streams over
`[dayStart − 30 h, min(dayStart + 24 h, exportedAt)]`, and call `SleepStager.detectSleep(…, stager: .v3)`.
Stored rows reproduce byte for byte only on the code that wrote them (Phase 0 showed 6 of 6 on
`v11.9.6`, 0 of 6 on `main`), so diff a change against the replay of `main` before it, never against the
stored rows. The Phase 0 replay output and harness live in `~/datasets/noop-review/phase0-2026-09-25/`.
Keep the harness and its output outside git; build it with `swift build -c release -Xswiftc -enable-testing`
for `@testable` access, and `rm -rf .build` after adding a source file to a package it depends on.
