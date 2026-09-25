# W8 — Screens and design system

**Phase** 4 · **Decisions** [AD-9](../DECISIONS.md#ad-9), [AD-10](../DECISIONS.md#ad-10) ·
**Status** on the [board](../README.md#status-board) · **Method** [METHOD.md](../METHOD.md)

Every SwiftUI screen, the Liquid Today shell, and the `StrandDesign` system they are built from.
`Strand/Screens` 62.9k lines in 104 files, `Strand/Liquid` 4.6k, `Packages/StrandDesign` 11.1k (1.4k
test lines). The largest and least-tested area by lines.

## Read first

`docs/CONTRIBUTING.md` design-system rules, `docs/FEATURES.md`, and the "two readouts of one fact"
bullet in `AGENTS.md` (the Alarms screen is its worked example).

## Where to start

| File | Why |
|---|---|
| `Strand/Screens/TodayView.swift` (6.0k lines, 27 fix commits) | Main Today shell; 21 `"my-whoop"` literals |
| `Strand/Liquid/LiquidTodayView.swift` (3.0k), `LiquidCore.swift`, `LiquidPrimitives.swift`, `LiquidSky.swift` | Second Today shell (AD-10) |
| `Strand/Screens/SettingsView.swift` (4.0k) | Settings sprawl (AD-9), stager picker |
| `Strand/Screens/SleepView.swift` (3.0k), `StagesCard.swift` | Sleep screen and hypnogram cards |
| `Strand/Screens/SmartAlarmView.swift` | Alarm screen, the known "two readouts" case |
| `Strand/Screens/MetricExplorerView.swift`, `CompareView.swift`, `TrendsView.swift`, `InsightsView.swift` | Cross-metric views over `metricSeries` |
| `Strand/Screens/DevicesView.swift`, `AddDeviceWizard.swift`, `TestCentreView.swift` | Device and diagnostics UI |
| `Packages/StrandDesign/Sources/StrandDesign/Palette.swift`, `Components.swift`, `StrandCard.swift`, `Appearance.swift` | Tokens and shared components |
| `Packages/StrandDesign/Sources/StrandDesign/TrendChart.swift`, `OverviewHRChart.swift`, `Hypnogram.swift` | Shared charts |
| `Strand/Resources/Localizable.xcstrings`, `Packages/StrandDesign/Sources/StrandDesign/Resources/Localizable.xcstrings` | String catalogues |

Tests: `StrandTests` (21 file names match Today, Liquid or Card), `Packages/StrandDesign/Tests`.

## Contracts this area owns

- UI uses design tokens only: `StrandPalette`, `StrandFont`, shared components.
- Every user-visible string is in a catalogue.
- A fact shown in two places resolves through one funnel and one clock.

## Checks

- [ ] For each Today card, name the resolver in each shell; flag any fact resolved twice (AD-10).
- [ ] Triage the 281 raw colour and font sites: move to a token, or record why it is an exception.
- [ ] i18n gate green; no string built by concatenation that a translation cannot reorder.
- [ ] No database read or analytics call inside a view `body`; heavy screens measured.
- [ ] Each settings toggle: key, default, every read site's default, backup status (AD-9).
- [ ] Countdowns and deadlines resolve from one clock and are gated on whether the event will happen.
- [ ] Light and dark screenshots on a device for every changed screen.

## Review passes

- [ ] 1 Map · [ ] 2 Static sweep · [ ] 3 Deep read · [ ] 4 Run · [ ] 5 Adversarial

## Gate

Both app builds; i18n gate; single-resolver test for each shared fact; light and dark screenshots.

## Findings

| ID | Sev | Status | Finding | Location | Evidence | PR |
|---|---|---|---|---|---|---|
| W08-001 | S4 | Reported | 281 raw colour or fixed-size font sites outside `StrandDesign` | Across `Strand/` | Pattern scan in `BASELINE.md`; needs triage | |
| W08-002 | S4 | Reported | Sleep chart band labels show the in-bed span, not the asleep span | `SleepView.swift` (to confirm) | 5/MG sleep audit of 2026-09-24 | |

## Log

- 2026-09-25 — File created from the plan. W08-001 from the baseline scan; W08-002 carried over from
  the 5/MG sleep audit.
