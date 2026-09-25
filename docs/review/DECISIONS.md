# Architectural decisions register

Fourteen decisions carry the structure. Each gets a verdict backed by evidence before any refactor
touches it. **Verdicts live only in this file.** An Amend or Replace verdict becomes a `design` finding
in the owning workstream's table, with its own PR in Phase 5.

Verdict values: `Open` → `Keep` | `Amend` | `Replace`.

| ID | Decision as built | Owner WS | Phase | Verdict |
|---|---|---|---|---|
| [AD-1](#ad-1) | Pure packages, thin app shell | W7 | 2 | Open |
| [AD-2](#ad-2) | `WhoopStore` actor opened separately by `BLEManager` and `Repository` on one SQLite file | W2 | 1 | Open |
| [AD-3](#ad-3) | BLE, routing, collection and backfill all `@MainActor`; CoreBluetooth on the main queue | W6 | 3 | Open |
| [AD-4](#ad-4) | Swift 5 language mode, strict concurrency `minimal` | W9 | 3 | Open |
| [AD-5](#ad-5) | Live and historical paths split; live frames dropped during offload | W6 | 1 | Open |
| [AD-6](#ad-6) | Decoded-first durability, resumable safe-trim, prunable raw outbox | W6 | 1 | Open |
| [AD-7](#ad-7) | `"my-whoop"` constant as the device partition key | W7 | 2 | Open |
| [AD-8](#ad-8) | Derived caches with background rescore; no algorithm version on rows | W7 | 2 | Open |
| [AD-9](#ad-9) | Settings in `UserDefaults` / `@AppStorage` plus the `.noopbak` whitelist | W8 | 4 | Open |
| [AD-10](#ad-10) | Two Today shells plus the iOS tab shell | W8 | 4 | Open |
| [AD-11](#ad-11) | Offline by default, with opt-in network clients | W9 | 3 | Open |
| [AD-12](#ad-12) | XcodeGen source of truth; app build CI on every app-path PR | W11 | 0 | Keep |
| [AD-13](#ad-13) | Fork diverges from upstream | W11 | 0 | Amend |
| [AD-14](#ad-14) | Error policy: `fatalError`, silent `try?`, strap-log logging | W9 | 3 | Open |

Each section below holds the question, the evidence to gather, and, once decided, the evidence found
and the verdict's reasoning. Keep the verdict in the table above in step with the section.

---

### AD-1

**Decision.** Core logic in platform-pure packages; the app target is a thin shell over them
(`docs/ARCHITECTURE.md` §11.4).

**Question.** Is the shell still thin? `Strand/` is 116k lines. `Strand/Data/IntelligenceEngine.swift`
(3.5k lines, 46 fix commits in six months), `Strand/Data/Repository.swift` (3.5k) and parts of
`Strand/App/AppModel.swift` hold scoring and resolution logic that only `StrandTests` covers, and `StrandTests` runs only on
the macOS leg of `app-build.yml`, only for PRs that touch app paths.

**Evidence to gather.** Pure-logic types in `Strand/Data` and `Strand/System` with no SwiftUI, AppKit,
UIKit or CoreBluetooth use; which of them already have package twins; how many fix commits touched
each.

**Evidence found.** —

**Verdict.** Open.

### AD-2

**Decision.** `WhoopStore` is an `actor`. `BLEManager` (`Strand/BLE/BLEManager.swift`, the
`WhoopStore(path:)` call) and `Repository` each open their own instance on the same file. Each builds a
`DatabasePool` with WAL (`Packages/WhoopStore/Sources/WhoopStore/WhoopStore.swift`), while
`ARCHITECTURE.md` §4 still describes a `DatabaseQueue`. `NoopLocalAccess` opens its own `DatabaseQueue`.

**Question.** Does one shared store beat two pools on one file? Is there contention, a stale read, or a
double migration race when both open at launch during an offload?

**Evidence to gather.** Every open per process (app, widgets, watch, `NoopLocalAccess`); busy or locked
errors in strap logs; a stress test running offload inserts and a rescore concurrently.

**Evidence found.** —

**Verdict.** Open.

### AD-3

**Decision.** `BLEManager`, `FrameRouter`, `Collector` and `Backfiller` are `@MainActor`; the
CoreBluetooth central runs on the main queue; historical frames drain through one serial `Task`
(`ARCHITECTURE.md` §4).

**Question.** Does ingest or decode block the main thread during a large offload? Is delegate-order
buffering the only ordering guarantee, and does anything bypass the serial drain?

**Evidence to gather.** Time Profiler trace of a full offload on the iPhone; hitches recorded by
`DisplayPerformanceMonitor`; every path into `Backfiller`.

**Evidence found.** —

**Verdict.** Open.

### AD-4

**Decision.** `project.yml` sets `SWIFT_VERSION: "5.0"` and `SWIFT_STRICT_CONCURRENCY: minimal`. The
compiler checks none of the 246 `Task` spawns, 5 `@unchecked Sendable` types or 2 `nonisolated(unsafe)`
sites.

**Question.** Which real races does complete checking surface? Should the pure packages move to Swift 6
mode before the app?

**Evidence to gather.** Warning counts per target under `-strict-concurrency=complete` (Phase 0);
triage of each warning into race or noise; a justification or a lock for every `@unchecked Sendable`.

**Evidence found.** 2026-09-25, Phase 0 counts in [`BASELINE.md`](BASELINE.md#phase-0-measurements):
the packages are nearly clean under complete checking (WhoopStore, StrandAnalytics and
NoopLocalAccess 0; WhoopProtocol 2 plus one `whoop-re` CLI compile error; StrandImport 2; StrandDesign
6). The macOS app does not compile under it: two main-actor-isolated default arguments are errors, and
at least 41 warnings printed before the build stopped. Triage of each warning is still to do (Phase 3).

**Verdict.** Open.

### AD-5

**Decision.** Live and historical paths split in `BLEManager.peripheral(_:didUpdateValueFor:)`. While
backfilling, only offload frame types reach `routeBackfillFrame`; the live flood is dropped
(`ARCHITECTURE.md` §5).

**Question.** Can a live-only fact be lost at the offload boundary: realtime HR, or ECG R17 live frames
that have no historical twin?

**Evidence to gather.** Strap-log replay across offload start and end; the list of live frame types
with no historical copy; what `stopUnexpectedRealtimeImu` stops and when.

**Evidence found.** —

**Verdict.** Open.

### AD-6

**Decision.** Decoded rows commit before raw is queued; the strap trims only after the `strap_trim`
cursor is durable (`Strand/Collect/Backfiller.swift`, `setCursor("strap_trim", …)`); raw is prunable
(`PrunePolicy`).

**Question.** Is every trim ack sent only after a durable commit, on every path? Mapped historical
layouts skip the reject archive, so a newly mapped layout without durable storage would lose its bytes
at trim.

**Evidence to gather.** Every path from frame to trim ack; a kill-mid-offload test on the strap; the
mapped-version list against the layouts that have a storage lane.

**Evidence found.** —

**Verdict.** Open.

### AD-7

**Decision.** `deviceId` partitions every stream and cache table. The strap is the literal
`"my-whoop"`, which appears at 193 sites (43 in `Strand/Data/MetricCatalog.swift`, 21 in
`Strand/Screens/TodayView.swift`, 16 in `Strand/Data/Repository.swift`).

**Question.** Is the partition a constant or an identity? `AGENTS.md` says reads must thread the
registry's active strap id. What happens on a strap swap, or with two straps registered?

**Evidence to gather.** Every literal classified as read or write; a test with two straps in the
registry; how `DeviceFamily.forRegistryDevice(model:brand:)` interacts with the partition.

**Evidence found.** —

**Verdict.** Open.

### AD-8

**Decision.** Screens read derived caches (`dailyMetric`, `sleepSession`, `metricSeries`);
`IntelligenceEngine` and the rescore schedulers rebuild them. No stored row records which algorithm
version produced it.

**Question.** Can rows from the V1, V2 and V3 sleep stagers mix inside one trend? When does a formula
change rescore old rows, and can a rescore race an offload?

**Evidence to gather.** Provenance columns (`ScoreInputProvenanceStore`); cached rows versus a fresh
compute over a backup (replay harness); the rescore trigger list.

**Evidence found.** 2026-09-25, Phase 0 replay ([`BASELINE.md`](BASELINE.md#replay-baseline)): all 6
stored nights in the newest backup reproduce byte for byte on `v11.9.6`, the build that wrote them, and
none reproduce on `main`, under either V2 (the epoch grid moved to the wall-clock 30 s boundary) or the
new default V3. The rows carry no stager version, so nothing can tell a V2-era row from a V3 one. Still
to find: what rescores these rows after an update, and whether a trend can mix them.

**Verdict.** Open.

### AD-9

**Decision.** Settings live in `UserDefaults` and `@AppStorage` at 804 call sites. The keys that survive
a backup are whitelisted in `Packages/WhoopStore/Sources/WhoopStore/BackupSettings.swift`.

**Question.** Should settings sit behind one typed registry? Which user-meaningful keys are missing from
backups, and which keys are read with different defaults at different sites?

**Evidence to gather.** All keys extracted with their defaults and read sites; diff against the
whitelist.

**Evidence found.** —

**Verdict.** Open.

### AD-10

**Decision.** Two Today shells: `Strand/Screens/TodayView.swift` (6.0k lines) and
`Strand/Liquid/LiquidTodayView.swift` (3.0k), plus the iOS `StrandiOS/App/RootTabView.swift`.

**Question.** Does every card resolve its metric through one funnel, or can the shells show different
values for the same fact (the `AGENTS.md` "two readouts" rule)?

**Evidence to gather.** Per card, the resolver used in each shell; every fact resolved more than once.

**Evidence found.** —

**Verdict.** Open.

### AD-11

**Decision.** Offline by default. Opt-in network clients exist: the AI coach
(`Strand/AI/Providers/`: Anthropic, OpenAI, Gemini, custom endpoint), `Strand/System/UpdateChecker.swift`
(GitHub releases API for this fork). `AGENTS.md` also permits a #1314 one-way export, but no client for
it exists in the fork yet. `ARCHITECTURE.md` §11.1 says there is no network client anywhere in the data
path.

**Question.** Is each client default-off and user-initiated? What exactly leaves the device in an AI
prompt, and is any call made in the background?

**Evidence to gather.** Defaults and prompt assembly traced; one prompt payload captured through a
local proxy; background schedulers checked for network use.

**Evidence found.** —

**Verdict.** Open.

### AD-12

**Decision.** `project.yml` is the XcodeGen source of truth. The plan recorded `app-build.yml` as
disabled, as `AGENTS.md` and `docs/CONTRIBUTING.md` still say; in this fork it is active.

**Question.** Should the fork run a compile-only app job on every PR and push to `main`?

**Evidence to gather.** Past app-target breakages that passed CI; macOS runner minutes per build.

**Evidence found.** 2026-09-25: `gh workflow list -R ayiskakov/noop` shows `App build (macOS + iOS)`
active. It triggers on PRs to `main` touching `Strand/**`, `StrandTests/**`, `StrandiOS*/**`,
`NOOPWatch*/**`, `Packages/**`, `project.yml` or the workflow itself, plus `workflow_dispatch`; there
is deliberately no `push: main` leg, since every change reaches `main` through a PR. The `Strand` leg
(macos-15) builds and runs `StrandTests`; the `NOOPiOS` leg (macos-26) is compile-only and does build
the watch app, which a local build on this Mac cannot. The last five runs all passed, taking 9 min 26 s
to 11 min 25 s; the newest ran 1,962 `StrandTests` with 1 skipped and 0 failures. The fork is public,
so these standard runners cost nothing.

**Verdict.** Keep. The question is already settled in favour of CI. Remaining gaps: the iOS leg runs
no tests, and the stale "disabled" claim in `AGENTS.md` and `docs/CONTRIBUTING.md` is a W12 finding.

### AD-13

**Decision.** The fork tracks `ryanbr/noop` as `upstream` and diverges from it (185 commits ahead and
56 behind at start). `Tools/upstream-candidates.py` lists upstream commits not yet taken.

**Question.** Which areas does the fork own outright (refactor freely), and which does it keep close to
upstream so merges stay cheap?

**Evidence to gather.** Per-directory diff size against upstream; `Tools/upstream-candidates.py` output;
how often upstream touches each hot-spot file.

**Evidence found.** 2026-09-25, `Tools/upstream-candidates.py` at upstream `1c3f0f9f` against `01baf82a`:
66 upstream commits not here. 17 touch only code the fork removed, 2 are already here by patch id, and
10 are declined in `Tools/upstream-skip.txt`. That leaves 37 to decide: 26 apply cleanly (some only
once their removed-file edits are dropped) and 11 need hand resolution. Upstream still ships Android,
Oura and WHOOP 4.0 support, so a wholesale merge is off the table; the tool's own header records 84
conflicts, 72 of them in deleted files, from a three-day dry run.

**Verdict.** Amend. The fork owns every area and refactors wherever the review finds cause (owner's
decision, 2026-09-25). Upstream becomes a source of fixes and ideas, taken commit by commit with
`--apply` or ported by hand; no refactor is held back to keep picks cheap. Upstream is frozen at
`1c3f0f9f` for the review and revisited before Phase 5. A finding that upstream already fixed cites the
upstream commit.

### AD-14

**Decision.** Shipping code holds 14 `fatalError` and 7 `precondition` calls. The app layer has 542
`try?` expressions, 248 of them on an awaited store call. Diagnostics go to the strap log and Test
Centre.

**Question.** Can bad data or disk state crash the app? Are write failures visible to the user or at
least to the log?

**Evidence to gather.** Every `fatalError` and `precondition` reachable from data; every `try?` on a
store write; fault-injection tests for a full disk and a corrupt row.

**Evidence found.** —

**Verdict.** Open.
