# AGENTS.md — working on NOOP

Guidance for anyone (human or AI agent) submitting a pull request. This is the high-signal map;
[`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md) is the full guide (BLE safety contract, design-system
rules, add-a-metric/screen/command recipes), [`docs/BUILD.md`](docs/BUILD.md) covers signing/pairing,
and [`docs/IOS.md`](docs/IOS.md) covers the iOS target. Read this first; follow the links for depth.

## What NOOP is (and the hard scope limits)

NOOP is an **offline-by-default, on-device** companion app for the **WHOOP 5.0 and WHOOP MG** straps,
for **macOS and iOS**. It pairs over Bluetooth, stores everything in on-device SQLite, and computes
recovery / strain / HRV / sleep locally. There is **no NOOP-operated server, no account, no cloud
dependency, no telemetry**, and the project stays **anonymous** (iOS ships build-from-source / sideload,
not via the App Store). Issue #1314 permits one narrow exception: a default-off Experimental client may
export data one way to an HTTP(S) endpoint the user owns and configures. It must remain outside strap
sync, never read data back, and ship no receiver or hosted service in this repository.

The hardware scope is deliberately narrow. `DeviceFamily` has exactly one case, `.whoop5`. A WHOOP 4.0
strap is still *recognised* on the air (`WhoopGattServiceFamily.whoop4`) so it can be reported as
**detected but unsupported**; NOOP does not connect to it or send it commands. There is no Android app
and no support for other wearable brands. A PR that re-adds either is a scope change and is issue-first.

These are hard constraints, not preferences. A PR is out of scope if it:
- adds a server, account, cloud dependency, or sends data off-device without the explicit user export
  boundary in [`docs/SCOPE.md`](docs/SCOPE.md) (including #1314's one-way self-hosted push);
- adds analytics/telemetry/crash-reporting that phones home;
- adds WHOOP firmware, decompiled app code, logos/assets, or any DRM circumvention. NOOP is
  **clean-room interoperability** with hardware the user owns — keep it that way. (That bars
  *implementations* and literals, not every fact learned from one: a protocol offset may be
  re-derived with attribution as an unvalidated candidate — see the "facts vs code" bullet in
  [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md) before telling a contributor no.)

Licensing: by opening a PR you agree your contribution is under the repo's
[PolyForm Noncommercial 1.0.0](LICENSE) license.

## Architecture at a glance

Core logic lives in **platform-pure Swift packages**; each app target is a thin layer over them. The
**macOS app is the reference implementation**; **iOS is a build-from-source target** folded into the
same repo and sharing most of the app-layer code.

| Layer | Path | What lives here |
|---|---|---|
| Protocol (pure) | `Packages/WhoopProtocol` | BLE frame parse, CRC, command/event/packet decode. **No CoreBluetooth.** Builds on Linux; also builds the `whoop-decode` CLI. |
| Storage | `Packages/WhoopStore` | GRDB/SQLite persistence: migrations, streams, caches. |
| Analytics (pure) | `Packages/StrandAnalytics` | HRV / recovery / strain / sleep / correlation math. Database-free. |
| Import | `Packages/StrandImport` | WHOOP CSV + Apple Health importers, FIT/GPX/TCX, nutrition and lab CSVs. |
| Design system | `Packages/StrandDesign` | SwiftUI palette / components / charts. |
| Local access | `Packages/NoopLocalAccess` | Read-only on-device data access (no network). |
| macOS + shared app | `Strand/` (scheme **Strand**, product `NOOP`, macOS 13+) | `BLE/` (CoreBluetooth), `Collect/`, `Data/` (Repository), `Screens/`, `App/` (`RootView`/`ContentView` = sidebar shell). Shared with iOS where a file isn't macOS-only. |
| iOS-only app | `StrandiOS/` (scheme **NOOPiOS**, iOS 17+), `StrandiOSShared/`, `StrandiOSWidgets/`, `NOOPWatch*` | `StrandiOSApp` (@main), `RootTabView` (the iOS tab shell — no macOS analogue), iOS widgets, watch app. |

`project.yml` is the **XcodeGen source of truth**; `Strand.xcodeproj/` is generated — never hand-edit
or commit it. Re-run `xcodegen generate` after adding/removing files or editing `project.yml`.

**Where new code goes:** the more "wire-level" (bytes) or "math-level" a change is, the deeper into
`Packages/` it belongs — and the more it must be covered by a `swift test` that runs with no app, no
strap, no CoreBluetooth. Never add `import AppKit` / `import UIKit` / `import CoreBluetooth` under
`Packages/`; guard framework code with `#if canImport(AppKit)` / `#elseif canImport(UIKit)`.

## Stored-data contracts (the #1 rule)

Everything on disk outlives the code that wrote it, so a few things are byte-level contracts:

- **Verify a changed decoder or formula by oracle, not by eye.** When a pure helper's output feeds
  stored rows or a score, extract it, run the Swift helper standalone (`swiftc -O twin.swift main.swift
  -o t && ./t`) over the whole input space or a spread of cases, and pin that stdout verbatim as the
  expected literal in a test (see the `oracles/` JSON under `Packages/*/Tests`). Reading an
  implementation is not the same as having run it: this is what caught a helper trimming its input
  where its caller only checked blank-ness.
- **Hashes and dedup keys that reach disk must use a stable, platform-neutral algorithm** (e.g. FNV-1a
  over UTF-16 code units) — never `hashValue`, which Swift randomizes per process. Anything that
  crosses the `.noopbak` boundary or is compared against a stored value is in this class.
- **The `.noopbak` backup whitelist is a versioned contract.** `BackupSettings.swift`
  (`Packages/WhoopStore`) carries the canonical keys + JSON kinds. Only Int/Double/String cross the
  wire — no dates/objects. Adding a key is additive; renaming or retyping one breaks every existing
  backup.
- **GRDB migrations are append-only and pinned by tests.** Add a versioned migration + a test; never
  mutate an existing migration.

## Build, test & CI — and what actually validates your change

**This is the part people get wrong.** Know exactly what covers your change before you claim it works.

### Prerequisites (toolchain & packages)
- **Xcode on macOS** — required for the app targets (`Strand`, `NOOPiOS`) and `StrandTests`. Deployment
  targets are macOS 13.0 / iOS 17.0 (see `project.yml`); the iOS 26 SDK is needed for `glassEffect`.
- **Swift toolchain ≥ 5.9** — the pure packages declare `swift-tools-version: 5.9`; a 6.x toolchain builds
  them. On **macOS** this ships with Xcode; on **Linux** use a swift.org toolchain.
- **Linux system packages** (a swift.org toolchain tarball does not bundle its build/runtime deps):
  `build-essential libc6-dev` — the C runtime / crt objects the linker needs; without them `swift build`
  fails at link with `cannot find Scrt1.o … -lc`. Plus `libncurses-dev libxml2 libcurl4 zlib1g-dev
  libedit2 pkg-config unzip`.

### Fast local loops
```bash
# Swift packages (fastest; no Xcode, no strap):
cd Packages/WhoopProtocol && swift build && swift test
# macOS app (needs Xcode on macOS):
xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme Strand \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

### What each CI job covers — and the gaps
| Workflow | Covers | Runner | Default state |
|---|---|---|---|
| `swift-packages.yml` | TWO jobs. `test`: `swift test` over **`Packages/**`** (WhoopProtocol, WhoopStore, StrandAnalytics, StrandImport, StrandDesign, NoopLocalAccess). `tools`: `swift build` + `swift test` over **`Tools/SleepBench`, `Tools/SleepPSG`, `Tools/Backfill`** — Backfill has no test target, so it is build-only. Path-filtered to those directories. | macos-15 | **active** |
| `app-build.yml` | Builds the **app targets** (`Strand` macOS + `NOOPiOS` iOS) **and runs `StrandTests`** on the macOS/`Strand` leg only — the iOS leg is compile-only. iOS leg needs **macos-26** (iOS 26 SDK / `glassEffect`). | macos-15 / macos-26 | **disabled** (on-demand) |
| `source-hygiene.yml` | Doc comments that bind to nothing (`Tools/doc_comment_lint.py`), the protocol-doc arithmetic examples, and the `docs/PROTOCOL_IMPLEMENTATION.md` source-reference existence check | ubuntu | **active** |
| `i18n-coverage.yml` | Diff-scoped translation gate (`Tools/i18n_audit.py --ci`) | ubuntu | **active** |
| `tools-python.yml` | `unittest discover` over `Tools/` and `Tools/linux-capture` | ubuntu | **active**, path-filtered |
| `prune-stale-branches.yml` | Deletes branches whose PR merged or closed unmerged | ubuntu | **active**, weekly + dispatch |
| `fork-testing-build.yml` / `fork-release.yml` | Staging / release builds (mac + ios) | — | on dispatch |

**The trap:** `swift-packages` does **NOT** compile the app targets. So if you touch **app-target
Swift** — anything under `Strand/`, `StrandiOS/`, `StrandiOSShared/`, `StrandiOSWidgets/` (Views,
`AppModel`, `BLEManager`, `Repository`, `RootTabView`, widget publish, …) — **no default CI validates
it**, because `app-build.yml` is disabled. A compile error there (e.g. `'self' used before all stored
properties are initialized`) will pass every green check and still be broken. If you change app-target
Swift, you MUST build the app yourself: `xcodebuild … build` locally, or run `app-build.yml` on demand.

### Local walls (things that will *not* build where you expect)
- **On Linux:** `WhoopProtocol` (pure) builds & tests with a bare toolchain. The GRDB-linked packages
  (`StrandAnalytics`, `WhoopStore`, `StrandImport`, `NoopLocalAccess`) need the snapshot-enabled SQLite
  build in [`docs/BUILD.md`](docs/BUILD.md); without those flags they fail with `sqlite3.h not found`
  (GRDB's CSQLite). `StrandDesign` needs SwiftUI and is macOS-only. **None of this is CI-enforced** —
  `swift-packages.yml` is macOS-only, so Linux support is honour-system and a change can break it
  silently.
- **App targets** (`Strand`, `NOOPiOS`) need **Xcode on macOS**; `StrandTests` runs only under
  `xcodebuild … test` on macOS — locally, or via `app-build.yml`, which does run it on the `Strand` leg.
  Since that workflow is **disabled by default**, app-target tests are only as validated as your last
  on-demand dispatch: writing them is not the same as having run them.
- **BLE behavior cannot be CI- or Linux-tested.** Anything on the CoreBluetooth / offload / live-HR
  path (`Strand/BLE`, `Strand/Collect`) must be **validated on a real strap**; compile-success proves
  nothing about connection behavior. Say what you tested on hardware.

## Hard rules before you touch these areas

- **BLE (read [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md) §BLE safety contract first):** never add
  **destructive** commands — firmware/DFU, ship-mode, power-cycle, force-trim, fuel-gauge reset, or
  anything else that can brick, wipe, or permanently alter the device. The ban is on *destructive*, not
  on writing: most of the curated set writes (toggle realtime HR, arm/cancel the alarm, start/stop raw
  data), and reversibility is the test. A new non-trivial command is **issue-first** — justify why it is
  reversible, confirmation-gate it, never send it automatically, and document its payload and its
  on-device verification before any code. That is the bar `rebootStrap` (#166) was held to. A write
  whose effect cannot be shown to reverse is treated as destructive until proven otherwise. CRC-gate
  every inbound frame; keep the connection path stable; no hardcoded hex frame bytes in app code —
  protocol facts live in the decoders/schema.
- **`didBond` is load-bearing well beyond the handshake — check every reader before you make a strap
  deliberately not bond.** At least three independent mechanisms treat "connected but never bonded" as a
  fault to be corrected: the bond watchdog bounces the link once its window expires, the #982 never-bonded
  detector counts self-drops toward pausing auto-reconnect, and the bond-refusal give-up latches on it.
  A change that legitimately leaves a strap unbonded — suppressing an unanswerable handshake, deferring
  one while an OS pairing is in flight — silently re-arms all of them, and each will undo the change a few
  seconds or a few drops later while reporting a cause that never happened (#1635). Not-bonding is only
  evidence of a fault when we were actually *trying* to bond.
- **A diagnostic may only assert what it can attribute.** Repeatedly in the #1635 investigation a line
  claimed more than it observed and sent the diagnosis backwards: a transport status rendered through
  the wrong enumeration's table (colliding small integers), a bond declared from a completion nobody
  checked the characteristic of, "we write WITH RESPONSE" printed before the code that decides whether
  to write at all, "the strap refused" for a local permission error, and a *persisted* refusal blaming
  a strap for a read that our own in-flight pairing broke. Prefer silence, or name the gap. Conversely,
  do not let a path go quiet: replacing a wrong line with no line removed the evidence that identified
  the bug. Gate per-connect readouts behind the Test Centre domain; leave rare-event evidence (a state
  transition, a mismatch) always-on, since it costs nothing when nothing happens and is what is missing
  when someone reports a problem without Test Centre enabled.
- **Two readouts of one fact must not be able to disagree.** The same rule as the bullet above, one
  layer up: it applies to what a SCREEN states, not only to what a log line claims. The Alarms screen is
  the worked example. It carried two pickers both labelled "Wake time", holding different values, only
  one of which woke anybody (#2353), and the per-day list under the wind-down card silently re-timed the
  strap alarm while its copy said it moved the reminder (#1864). The repair work then introduced the
  same shape five more times: a line naming the base alarm time where an override day fires at another,
  a card that hid where its own time came from, a countdown for an alarm that would never arm, a
  countdown and its date stamp resolved from two clocks a tick apart, and a deadline printed three times
  in one card.
  Three defences, in order of preference: do not show the fact twice (the second copy is usually noise,
  as a date stamp beside figures that already carry the time); when it must appear twice, resolve both
  from ONE gated funnel and ONE clock, passed in rather than read separately; and gate that funnel on
  whether the thing will actually happen, since a countdown is a promise and an unarmed alarm has none
  to make. Counting gated call sites is the weak version of that last test and it passes while a fourth
  reader resolves the fact by itself: assert the single resolver instead.
- **A gate must be able to fail on the change that caused it.** The same rule again, moved out to CI:
  when a check cannot see what invalidates it, the failure lands on whoever pushes next and reads as
  their fault. Two live instances. A discovery floor written as an exact count means a legitimate
  future removal of one test prints "discovery is broken, not the suite" on main against a change that
  removed nothing. And GitHub's fork-PR approval gate re-arms on every force-push, parking workflows at
  `action_required`, which the check-runs API reports as a total of zero rather than as a failure.
  Two defences. Never gate a CI poll on `failures == 0`: an approval-parked or not-yet-registered roster
  has no failures and is not green. Require `non-success == 0` plus a stable total plus a roster floor
  for the paths touched, which is the only thing that stopped a PR merging with its compile legs unrun
  (#2343). And where a gate's trigger structurally cannot include what invalidates it, say so in the
  error text, so the person holding the failure can tell whose it is.
- **Device / strap model resolution:** map a registry row to a family through the ONE canonical
  resolver (`DeviceFamily.forRegistryDevice(model:brand:)`, or `confirmedRegistryFamily(model:brand:)`
  where an unconfirmed row must stay `nil`), never a scattered string compare — the wizard stores
  `"5.0"`, other paths `"WHOOP 5.0"` or `"MG"`, and single-spelling checks silently miss straps. Reads
  must thread the registry's **active** strap id, not a raw BLE address.
- **`doc_comment_lint` reports at the wrong line on purpose — do not chase it.** The baseline is a
  *per-file count* of grandfathered sites, not a set of line numbers (deliberately: a line-keyed baseline
  goes stale constantly). So adding one new detached doc comment makes the file overflow its budget and
  the failures print against **other, pre-existing** sites — often nowhere near your edit. Look at what
  you just inserted, not at the lines it names. The usual cause is inserting a declaration directly above
  an existing one, which lands your code between that neighbour's doc block and the thing it documents:
  insert **above the neighbour's doc block**, or after the previous declaration's closing brace.
- **Design system is law:** UI uses only design tokens — `StrandPalette` / `StrandFont` / shared
  components from `StrandDesign`. No hardcoded colors, fonts, or spacing.
- **Migrations:** add a versioned migration + a test; never mutate an existing migration. Watch for
  data-loss traps (window-wide deletes, backfill rewrites) — prefer additive/transactional changes.
- **Deriving a physiological signal from raw sensor data — validate against the artifact, not one
  match:** the WHOOP optical/motion buffers are fixed-N-samples-per-record, so autocorrelation/spectral
  methods can manufacture a peak at the record period that *looks* physiological and coincidentally
  matches the WHOOP app on a stable night — that's why the PPG→HR estimate (#194) was withdrawn. A
  single "matched WHOOP" night is **not** validation. Prove the method **tracks a varying input**
  (different subjects, or nights where the true value moves; for synthetic tests, recover *multiple*
  injected values, not one). Until it does, land it as **instrumentation** (decode + store + log the
  estimate beside the incumbent) or behind a **default-off Experimental toggle** — never make it the
  default or feed it a downstream gate (recovery, illness) on thin evidence.

## iOS specifics worth knowing

- **iOS is `NOOPiOS`**, not `Strand`. `ContentView`/`RootView` (the macOS sidebar) are excluded from
  iOS; the iOS shell is `RootTabView`. A file shared with macOS (`TodayView`, `Repository`, analytics)
  must keep compiling for **both** — check the `Strand` (macOS) build too when you edit shared files.
- iOS/macOS deployment targets: macOS 13.0, iOS 17.0 (see `project.yml`).

## PR & commit conventions

- **One concern per PR.** Keep a protocol change, a schema migration, and a UI change separate.
- **Use English for all repository-facing text:** PR titles and descriptions, commit messages,
  issues, review comments, documentation, and code comments. App translations remain in their
  intended target languages.
- **Leave issue closure to maintainers.** Reference related issues neutrally with `Refs #N`.
  Avoid GitHub auto-closing keyword + issue references in commit messages, PR descriptions, and
  comments, including quoted text; maintainers decide when a report is resolved and its issue can
  be closed.
- **Show your verification.** BLE → what you tested on hardware. Analytics → the method + a test.
  UI → confirms design tokens only. App-target Swift → that you compiled the app (CI won't).
- **Keep generated artifacts out of git** (`Strand.xcodeproj/`, `build/`, `.build/`, `*.app`,
  DerivedData). Commit `project.yml`, not the generated project. `Package.resolved` is fine.
- **Versioning (SemVer):** bump `MARKETING_VERSION` in `project.yml`; the build number increments
  independently. The parts are counters, not decimals (`2.0.10` follows `2.0.9`).
- **Voice:** docs/comments are neutral, third-person, project-voice. Keep upstream credits intact.
- **Release-note credits use GitHub handles (#736).** In a release's contributor section, credit
  **third-party** work by `@handle`, not by display name — a plain name is invisible to GitHub, so it
  neither notifies the contributor nor links to their profile. A display name may accompany the handle,
  but the handle is what makes the credit real: `Thanks to @tigercraft4 (Sleep/Health refactors),
  @digitalerdude (workout backfill), …`.
  - Credit both **merged PR authors** and the **issue reporters** whose reports drove a fix — a good bug
    report with a strap log is often the harder half.
  - **Only third-party contributors.** The maintainer's own handles (`@ryanbr` / `@Fanboynz`) are left
    out: self-credit adds noise and self-mentions notify nobody.
  - Collect the handles with **`Tools/release-contributors.sh <since-date|since-tag>`**, which lists every
    third-party merged PR and every issue *closed as completed* in the range, plus a ready credit line,
    with the maintainer's own handles and bot accounts filtered out. A tag argument is bounded at that
    tag's exact instant, so the previous release's work is not re-credited. Writing *what* each person
    contributed is still by hand — that's the judgement part; hunting logins is not. Its output is a work
    list to prune, not a finished line: a reporter whose issue is not worth calling out in the notes can
    be left to the closing "everyone who filed the reports behind these fixes". `Tools/release.sh` warns
    when the notes it is about to publish credit no `@handle`.

When in doubt, open an issue to coordinate first, and prefer the smallest change that's correct and
covered by a test that runs without a strap.
