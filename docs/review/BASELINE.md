# Baseline

Numbers measured on 2026-09-25 at `01baf82a`, before any review fix. Re-measure with the commands at
the end and compare; never edit a measured row after the fact — add a dated row or section instead.

## Size and test coverage

Two thirds of the code is in the app layer. Its CI is `app-build.yml`, which runs only on PRs that touch
app paths; its `StrandTests` run on the macOS leg only. (Corrected 2026-09-25: this section first said
the app layer had no default CI, copying `AGENTS.md`; the fork's workflow is active. See AD-12.)

| Area | Path | Source lines | Test lines | Default CI |
|---|---|---|---|---|
| Protocol | `Packages/WhoopProtocol` | 12,090 | 11,959 | swift-packages |
| Storage | `Packages/WhoopStore` | 8,246 | 9,127 | swift-packages |
| Analytics | `Packages/StrandAnalytics` | 33,148 | 31,743 | swift-packages |
| Import | `Packages/StrandImport` | 8,269 | 4,384 | swift-packages |
| Design system | `Packages/StrandDesign` | 11,132 | 1,420 | swift-packages |
| Local access | `Packages/NoopLocalAccess` | 1,510 | 359 | swift-packages |
| App: Screens | `Strand/Screens` | 62,866 | in `StrandTests` | app-build (PR) |
| App: Data | `Strand/Data` | 17,389 | in `StrandTests` | app-build (PR) |
| App: BLE + Collect | `Strand/BLE`, `Strand/Collect` | 14,738 | in `StrandTests` | app-build (PR) |
| App: System, App, Liquid, AI, other | `Strand/*` | 21,340 | in `StrandTests` | app-build (PR) |
| iOS, widgets, watch | `StrandiOS*`, `NOOPWatch*` | 9,529 | in `StrandTests` | app-build (PR, compile only) |
| App tests | `StrandTests` | — | 25,972 in 249 files | app-build (PR, macOS leg) |
| Tools | `Tools/` | 4,422 Swift + Python | Python unittest, SleepBench, SleepPSG | tools-python, swift-packages `tools` |

Package test lines include `Tests/` only; app-layer lines are all Swift under the path.

## Bug hot spots

Files most often touched by `fix` commits between 2026-03-25 and 2026-09-25:

| File | Lines | Fix commits | All commits |
|---|---|---|---|
| `Strand/Data/IntelligenceEngine.swift` | 3,507 | 46 | 188 |
| `Strand/Data/Repository.swift` | 3,522 | 32 | 120 |
| `Strand/BLE/BLEManager.swift` | 7,173 | 30 | 207 |
| `Strand/Screens/TodayView.swift` | 5,994 | 27 | 189 |
| `Strand/App/AppModel.swift` | 2,446 | 22 | 121 |
| `Strand/Screens/SleepView.swift` | 2,989 | 18 | 83 |
| `Packages/StrandAnalytics/…/AnalyticsEngine.swift` | 1,528 | 17 | 76 |
| `Packages/StrandAnalytics/…/SleepStager.swift` | 3,310 | 16 | 60 |

`Strand/System/AppChangelog.swift` also has 32 fix commits, but those are release-note text.

## Risk markers

Pattern counts over shipping Swift (tests and `.build/` excluded). They are leads, not findings; each
workstream triages the ones in its area.

| Marker | Count | Triage in |
|---|---|---|
| `UserDefaults` / `@AppStorage` call sites | 804 | W8 (AD-9) |
| `"my-whoop"` literal | 193 | W7 (AD-7) |
| Raw `Color(red:)`, sRGB, hex colour or fixed-size system font outside `StrandDesign` | 281 | W8 |
| `@MainActor` annotations | 272 | W6, W9 (AD-3) |
| `Task {}` / `Task.detached` / `Task(priority:)` | 246 | W9 (AD-4) |
| `DispatchQueue` uses | 56 | W9 (AD-4) |
| Locks (`NSLock`, unfair locks) | 11 | W9 (AD-4) |
| `@unchecked Sendable` | 5 | W9 (AD-4) |
| `nonisolated(unsafe)` | 2 | W9 (AD-4) |
| `try?` in the app layer (all / on an awaited store call) | 542 / 248 | W9 (AD-14) |
| `fatalError(` | 14 | W9 (AD-14) |
| `precondition` | 7 | W9 (AD-14) |
| `try!` / `as!` | 0 / 0 | — |
| `TODO` / `FIXME` / `HACK` | 1 | owning WS |
| `hashValue` (in-process memo key in `ReadinessEngine`, not persisted) | 2 | W3 |
| GRDB migrations (latest `v49-ecg-r16-record`) | 49 | W2 |
| Network client files (6 in `Strand/AI`, plus `UpdateChecker`) | 7 | W9 (AD-11) |

Build settings: `SWIFT_VERSION: "5.0"`, `SWIFT_STRICT_CONCURRENCY: minimal` (`project.yml`); every
package declares `swift-tools-version: 5.9`.

History: 3,121 commits since 2026-06-07; the fork was 185 commits ahead of `upstream/main` and 56
behind.

## Phase 0 measurements

Measured 2026-09-25 at `01baf82a` on an M-series Mac (10 cores), Xcode 26.3, Swift 6.2.4. Package
times are wall-clock `swift test` with warm `.build` caches, so they measure test run time more than
compile time. Test counts are XCTest totals; no package has Swift Testing tests yet.

| Target | Command | Result | Time (s) | Date |
|---|---|---|---|---|
| WhoopProtocol | `swift test` | 737 tests, 0 failures, 4 skipped | 3 | 2026-09-25 |
| WhoopStore | `swift test` | 542 tests, 0 failures, 1 skipped | 17 | 2026-09-25 |
| StrandAnalytics | `swift test` | 2,189 tests, 0 failures, 2 skipped | 170 | 2026-09-25 |
| StrandImport | `swift test` | 277 tests, 0 failures | 10 | 2026-09-25 |
| StrandDesign | `swift test` | 101 tests, 0 failures | 4 | 2026-09-25 |
| NoopLocalAccess | `swift test` | 14 tests, 0 failures | 3 | 2026-09-25 |
| SleepBench / SleepPSG | `swift test` | 13 / 33 tests, 0 failures | 5 / 39 | 2026-09-25 |
| Backfill | `swift build` | builds (no test target) | 5 | 2026-09-25 |
| Strand (macOS) | `xcodebuild … build` | succeeded (incremental) | 24 | 2026-09-25 |
| StrandTests | `xcodebuild … test` | 1,962 tests, 0 failures, 1 skipped; matches the fork's last CI run | 62 | 2026-09-25 |
| NOOPiOS (no-watch) | `xcodebuild … build` | succeeded; watch app not built (no watchOS runtime) | 31 | 2026-09-25 |
| Tools Python | unittest (core + linux-capture) | core: 112 tests, **4 failures** (W11-001, macOS only); linux-capture: 234 tests, 0 failures | 16 / 4 | 2026-09-25 |
| Hygiene gates | `doc_comment_lint`, `validate_examples`, `check_source_references` | all pass | — | 2026-09-25 |

Strict-concurrency counts are unique warnings in the target's own sources under
`-strict-concurrency=complete` (packages via `swift build -Xswiftc`, the app via
`SWIFT_STRICT_CONCURRENCY=complete`), split into concurrency diagnostics and other warnings the same
build prints.

| Target | Concurrency warnings | Other | Notes | Date |
|---|---|---|---|---|
| WhoopProtocol | 2 | 0 | Library clean apart from two globals (`Schema.swift` `_cachedSchema`, `Streams.swift` `empty`). The `whoop-re` CLI fails to compile: a top-level `var` becomes main-actor isolated | 2026-09-25 |
| WhoopStore | 0 | 0 | | 2026-09-25 |
| StrandAnalytics | 0 | 0 | | 2026-09-25 |
| StrandImport | 2 | 4 | Two static `ISO8601DateFormatter`s; four deprecated `Archive(data:)` calls in `XlsxSheet.swift` | 2026-09-25 |
| StrandDesign | 6 | 0 | Two `Animatable` conformances crossing into the main actor; four static settings keys and a store | 2026-09-25 |
| NoopLocalAccess | 0 | 0 | | 2026-09-25 |
| Strand (macOS app) | ≥ 41 (partial) | — | **Does not compile**: 2 errors, a main-actor-isolated default argument in a nonisolated context (`BLEManager.swift:4802`, `Repository.swift:2615`). The count is what printed before the build stopped: Collect 8, App 8, System 7, Screens 7, Data 7, Liquid 3, BLE 1 | 2026-09-25 |

### Replay baseline

The newest backup (exported 2026-09-24 by 11.9.6 build 428, schema v49) holds 6 stored nights under
`my-whoop-noop` and streams under `my-whoop`. Each stored night was re-detected from its streams over
`[dayStart − 30 h, min(dayStart + 24 h, exportedAt)]`.

| Code | Stager | Night found, same bounds | Stored hypnogram reproduced byte for byte |
|---|---|---|---|
| `v11.9.6` (the build that wrote the rows) | V2 | 6 / 6 | 6 / 6 |
| `v11.9.6` | V1 | 6 / 6 | 0 / 6 |
| `01baf82a` (`main`) | V2 | 6 / 6 | 0 / 6 |
| `01baf82a` (`main`) | V3 (default) | 6 / 6 | 0 / 6 |

The harness is sound: it reproduces every row on the code that wrote them. On `main` the epoch grid is
aligned to the wall-clock 30 s boundary, where 11.9.6 anchored it at the session start, and V3 is the
default; so no stored night matches current code. This is the AD-8 case: nothing on a row says which
stager produced it. **From here on, the baseline for replay diffs is `main`'s own output at
`01baf82a`, not the stored rows.** The per-night output and the harness source are kept outside git
(`~/datasets/noop-review/phase0-2026-09-25/`).

## Re-measure

Scan the named directories, never `.`: local `.claude/worktrees/` checkouts and `.build/` dependency
copies would inflate every count.

```bash
# Swift lines per area (shipping code, excluding .build)
for d in Packages/* Strand/* StrandiOS StrandiOSShared StrandiOSWidgets NOOPWatch NOOPWatchComplications; do
  [ -d "$d" ] && printf "%-40s %8s\n" "$d" \
    "$(find "$d" -name '*.swift' -not -path '*/.build/*' -not -path '*/Tests/*' -print0 | xargs -0 cat 2>/dev/null | wc -l)"
done

# Fix-commit hot spots over the last six months
git log --since="6 months ago" --format= --name-only -i --grep='^fix' | grep '\.swift$' | sort | uniq -c | sort -rn | head -25

# Risk markers (run with bash, not zsh: the path list must word-split)
bash -c 'S="Packages Strand StrandiOS StrandiOSShared StrandiOSWidgets NOOPWatch NOOPWatchComplications"
g(){ grep -rnE "$1" --include="*.swift" --exclude-dir=.build $S | grep -v "/Tests/"; }
echo "UserDefaults: $(g "UserDefaults|@AppStorage" | wc -l)"
echo "my-whoop: $(g "\"my-whoop\"" | wc -l)"
echo "raw colours/fonts: $(g "Color\(red:|Color\(\.sRGB|Color\(hex|\.font\(\.system\(size" | grep -v StrandDesign | wc -l)"
echo "Task: $(g "Task \{|Task\.detached|Task\(priority" | wc -l)  DispatchQueue: $(g "DispatchQueue" | wc -l)"
echo "unchecked Sendable: $(g "@unchecked Sendable" | wc -l)  nonisolated(unsafe): $(g "nonisolated\(unsafe\)" | wc -l)"
echo "fatalError: $(g "fatalError\(" | wc -l)  precondition: $(g "precondition" | wc -l)"'
```
