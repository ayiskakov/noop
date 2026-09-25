# W9 — App shell and services

**Phase** 3 · **Decisions** [AD-4](../DECISIONS.md#ad-4), [AD-11](../DECISIONS.md#ad-11),
[AD-14](../DECISIONS.md#ad-14) · **Status** on the [board](../README.md#status-board) ·
**Method** [METHOD.md](../METHOD.md)

App state, launch, background jobs, notifications, diagnostics, the AI coach and the update checker.
`Strand/App` 4.7k, `Strand/System` 7.9k, `Strand/AI` 2.3k, `Strand/MenuBar` 0.4k,
`Strand/Onboarding` 1.4k lines.

## Read first

`docs/PRIVACY_SECURITY.md`, `docs/SCOPE.md`, `docs/ARCHITECTURE.md` §4.

## Where to start

| File | Why |
|---|---|
| `Strand/App/AppModel.swift` (2.4k lines, 22 fix commits) | App state, launch order, widget publishing |
| `Strand/App/StrandApp.swift`, `RootView.swift`, `ContentView.swift`, `NavRouter.swift`, `TabRoute.swift` | macOS shell and navigation |
| `Strand/App/AppClock.swift` | The injectable clock; code that reads `Date()` directly bypasses it |
| `Strand/App/GpsWorkoutRecorder.swift`, `LiveSessionRunner.swift`, `ActiveWorkout*.swift` | Live sessions |
| `Strand/System/RescoreBackgroundScheduler.swift`, `CoachBriefScheduler.swift`, `ScheduledDebugExport.swift` | Background jobs |
| `Strand/System/IllnessNotifier.swift`, `BatteryNotifier.swift`, `StrainTargetNotifier.swift`, `WindDownNudge.swift`, `NotificationPresenter.swift` | Notifications |
| `Strand/System/TestCentre.swift`, `TestCentreReport.swift`, `TestBundleAssembler.swift`, `DebugDataDiagnostics.swift` | Diagnostics and debug exports |
| `Strand/System/UpdateChecker.swift`, `UpdateAvailability.swift` | GitHub releases check (AD-11) |
| `Strand/AI/AICoach.swift`, `AIProvider.swift`, `Providers/*.swift` | AI coach: Anthropic, OpenAI, Gemini, custom endpoint (AD-11) |
| `Strand/Onboarding/OnboardingWizard.swift`, `Strand/App/TermsGateView.swift` | First run |
| `project.yml` | Swift version and concurrency settings (AD-4) |

Tests: `StrandTests` (8 file names match AICoach, AIProvider or Update).

## Contracts this area owns

- Nothing is sent over the network unless the user turned that feature on and triggered it.
- Background jobs are idempotent, bounded and single-flight.
- A notification fires once per event.

## Checks

- [ ] AI coach: default off; exact prompt payload captured; keys in the Keychain; no background call.
- [ ] Update checker: when it runs, whether it can be turned off, what the request carries.
- [ ] Each background job: registration, expiry handling, single-flight, safe to rerun after a crash.
- [ ] Each notifier: no duplicate after relaunch or time-zone change.
- [ ] Code that reads the wall clock directly instead of `AppClock` (testability and "one clock").
- [ ] Strict-concurrency warnings triaged into races and noise; each `@unchecked Sendable` justified
      (AD-4).
- [ ] Every `fatalError` and `precondition` reachable from data; every `try?` on a store write
      (AD-14).
- [ ] Launch order: store open and migration never block the first frame.

## Review passes

- [ ] 1 Map · [ ] 2 Static sweep · [ ] 3 Deep read · [ ] 4 Run · [ ] 5 Adversarial

## Gate

`StrandTests`; both app builds; payload capture for any network change.

## Findings

| ID | Sev | Status | Finding | Location | Evidence | PR |
|---|---|---|---|---|---|---|
| W09-001 | S3 | Reported | Concurrency is unchecked by the compiler (Swift 5 mode, strict concurrency `minimal`) | `project.yml` | 5 `@unchecked Sendable`, 2 `nonisolated(unsafe)`, 246 `Task` spawns unchecked | |

## Log

- 2026-09-25 — File created from the plan. W09-001 seeded from the baseline scan.
