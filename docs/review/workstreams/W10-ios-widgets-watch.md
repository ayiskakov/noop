# W10 — iOS, widgets, watch

**Phase** 3 · **Decisions** [AD-10](../DECISIONS.md#ad-10) · **Status** on the
[board](../README.md#status-board) · **Method** [METHOD.md](../METHOD.md)

The iOS app shell, HealthKit, widgets, Live Activities and the watch app. `StrandiOS` 4.6k,
`StrandiOSShared` 1.0k, `StrandiOSWidgets` 1.6k, `NOOPWatch` 1.8k, `NOOPWatchComplications` 0.5k
lines. The iPhone is the only bench that can bond the 5/MG, so this is where hardware checks run.

## Read first

`docs/IOS.md`, `docs/BUILD.md`, and the iOS section of `AGENTS.md`.

## Where to start

| File | Why |
|---|---|
| `StrandiOS/App/StrandiOSApp.swift` | `@main`, launch, scene phases (58 commits in six months) |
| `StrandiOS/App/RootTabView.swift`, `AppModel+iOS.swift` | iOS tab shell and iOS-only app state |
| `StrandiOS/Health/HealthKitBridge.swift` (1.7k lines) | HealthKit reads and writes |
| `StrandiOS/Health/HealthWritebackBackgroundScheduler.swift` | Background write-back |
| `StrandiOS/System/NOOPAppIntents.swift`, `HomeScreenQuickActions.swift`, `SyncKeepAwake.swift` | Intents, quick actions, keep-awake during sync |
| `StrandiOSShared/WidgetSnapshot.swift`, `WidgetTelemetry.swift`, `HrTrace.swift`, `StressTrace.swift` | Data handed from the app to widgets |
| `StrandiOSWidgets/*.swift` | Widgets and Live Activities |
| `Strand/Data/WatchSessionBridge.swift`, `NOOPWatch/WatchScoreStore.swift`, `WatchLiveHR.swift` | Phone ↔ watch data |
| `NOOPWatchComplications/NOOPWatchComplication.swift` | Complications |

Tests: `StrandTests` (7 file names match Widget, Watch, HealthKit or iOS); the iOS target itself has no
test target.

## Contracts this area owns

- Files shared with macOS compile for both platforms.
- Widgets and the watch show the same number the app shows for the same fact.
- HealthKit write-back never re-imports what it wrote, and never writes a value twice.

## Checks

- [ ] Shared files build for `Strand` and `NOOPiOS` after every change.
- [ ] HealthKit: permissions, dedup of writes, background delivery, no write-back loop.
- [ ] Widget snapshot built from the app's resolver, not a second computation (AD-10).
- [ ] Background tasks registered, with expiry handlers, inside their time budget.
- [ ] CoreBluetooth state restoration and background BLE behaviour (upstream #613).
- [ ] Watch bridge: ordering, stale scores after a gap, reachability changes.
- [ ] Live Activities end when their session ends, including after a crash.

## Review passes

- [ ] 1 Map · [ ] 2 Static sweep · [ ] 3 Deep read · [ ] 4 Run · [ ] 5 Adversarial

## Gate

`NOOPiOS` no-watch build (see [`METHOD.md`](../METHOD.md#commands)); `Strand` build for shared files;
an on-device run for behaviour changes. Say in the PR when the watch app was not built.

## Findings

| ID | Sev | Status | Finding | Location | Evidence | PR |
|---|---|---|---|---|---|---|

## Log

- 2026-09-25 — File created from the plan.
