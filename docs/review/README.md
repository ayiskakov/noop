# Whole-project code review — tracker

This directory tracks the fork's whole-project review: every bug, risk and architectural decision
found, fixed and validated. **It is the source of truth for review status.** Agents read it before
starting review work and update it in the same commit as the work it records.

Started 2026-09-25 against `main` at `01baf82a`. The human-facing plan that seeded this tracker is a
Claude Doc (NOOP — Whole-Project Code Review Plan); where the two disagree, this directory wins.

## How to navigate

| File | Read it when | Holds |
|---|---|---|
| [`README.md`](README.md) | Always, first | This index, the status board, the agent protocol |
| [`PLAN.md`](PLAN.md) | Starting a phase | Goals, scope, ground rules, phases, exit criteria, open questions |
| [`METHOD.md`](METHOD.md) | Before reviewing or fixing anything | The five review passes, concern checklist, validation protocol, severity, finding template, commands |
| [`DECISIONS.md`](DECISIONS.md) | Touching structure, or proposing a refactor | The architectural decisions register (AD-1 … AD-14) and their verdicts |
| [`BASELINE.md`](BASELINE.md) | Comparing before and after | Sizes, bug hot spots, risk-marker counts, and the Phase 0 measurements |
| [`workstreams/`](workstreams/) | Working in one area | One file per area: where to start, contracts, checks, findings, log |

## Status board

Each fact on this board lives here only. Findings live only in their workstream file; verdicts live
only in `DECISIONS.md`. Do not copy counts from those files onto this board — link instead.

**Current phase:** 1 — Data integrity (not started). Phase 0 closed 2026-09-25; its numbers are in
[`BASELINE.md`](BASELINE.md#phase-0-measurements). See [`PLAN.md`](PLAN.md#phases).

| WS | Area | File | Phase | Status |
|---|---|---|---|---|
| W1 | Protocol | [W01-protocol.md](workstreams/W01-protocol.md) | 1 | Not started |
| W2 | Storage | [W02-storage.md](workstreams/W02-storage.md) | 1 | Not started |
| W3 | Analytics | [W03-analytics.md](workstreams/W03-analytics.md) | 2 | Not started |
| W4 | Import and export | [W04-import.md](workstreams/W04-import.md) | 2 | Not started |
| W5 | Local access (MCP / CLI) | [W05-local-access.md](workstreams/W05-local-access.md) | 4 | Not started |
| W6 | BLE and collection | [W06-ble-collect.md](workstreams/W06-ble-collect.md) | 1 (safe-trim), 3 (rest) | Not started |
| W7 | App data layer | [W07-app-data.md](workstreams/W07-app-data.md) | 2 | Not started |
| W8 | Screens and design system | [W08-screens-design.md](workstreams/W08-screens-design.md) | 4 | Not started |
| W9 | App shell and services | [W09-app-shell.md](workstreams/W09-app-shell.md) | 3 | Not started |
| W10 | iOS, widgets, watch | [W10-ios-widgets-watch.md](workstreams/W10-ios-widgets-watch.md) | 3 | Not started |
| W11 | Tools, CI, build | [W11-tools-ci.md](workstreams/W11-tools-ci.md) | 0 (AD-12, AD-13), 6 | In review (Phase 0 part done) |
| W12 | Docs and truth | [W12-docs-truth.md](workstreams/W12-docs-truth.md) | 6 | Not started |

Status values: `Not started` → `In review` → `Fixing` → `Verifying` → `Done`. A workstream is `Done`
only when every finding in its file is `Verified`, `Not a bug` or `Deferred` with a reason, and its
five review passes are ticked.

## Next up

Phase 1 — Data integrity: W2 Storage, W1 Protocol, and the safe-trim and backfill part of W6. Tick each
item as it lands.

- [ ] Run the Phase 1 review workflow (owner's choice: one multi-agent workflow per phase, under ten
      agents): passes 1 Map, 2 Static sweep, 3 Deep read and 5 Adversarial for each of the three areas.
      Agents return findings; one writer records them as `Reported` rows, so the files never collide.
- [ ] Settle AD-2, AD-5 and AD-6 in [`DECISIONS.md`](DECISIONS.md).
- [ ] V0 every finding (pass 4); fix S1 and S2 first; one PR per workstream batch.
- [ ] Exit gate: a migration test and a `.noopbak` export → import round trip on a copy of the newest
      backup, and no open S1 or S2 in the three areas.
- [ ] Still open from Phase 0: AD-4's target (warning-clean vs Swift 6 mode), now that the counts are
      in. Needed by Phase 3.

Phase 0 — Baseline, closed 2026-09-25:

- [x] Open questions answered in [`PLAN.md`](PLAN.md#open-questions), except AD-4's target.
- [x] Upstream frozen at `1c3f0f9f` instead of merged (the fork cherry-picks; a merge would pull back
      Android, Oura and WHOOP 4.0). The candidate count is in AD-13.
- [x] `swift test` in every package and in `Tools/SleepBench`, `Tools/SleepPSG`: all pass.
- [x] `Strand` and `NOOPiOS` (no-watch) build; `StrandTests` pass (1,962 tests).
- [x] Strict-concurrency counts taken; the app does not compile under complete checking (AD-4).
- [x] Replay baseline taken on `main`; the stored rows reproduce only on `v11.9.6` (AD-8).

## Agent protocol

1. **Orient.** Read this file, then [`METHOD.md`](METHOD.md), then the workstream file for your area.
   Check `git log -- docs/review/` for what changed since you last looked.
2. **Claim.** Set your workstream to `In review` on the board and add a dated line to its log saying
   what you are about to do. One agent per workstream at a time.
3. **Record as you go.** Every finding gets a row in its workstream's findings table the moment it is
   suspected, with status `Reported`. Never hold findings only in a chat transcript.
4. **Validate before fixing.** Follow the V0 → V1 → V2 → V3 protocol in [`METHOD.md`](METHOD.md).
   Update the row's status at each step, with the evidence link or test name.
5. **Hand off.** Before stopping, append a log line: what was done, what is next, and anything
   half-finished. The next agent starts from that line.
6. **Commit the tracker with the work.** A fix commit updates its finding row in the same commit.
   Tracker-only changes use `docs(review): …` commit messages.

**Finding IDs** are per workstream, `Wnn-###` (for example `W06-003`), so parallel agents never collide.
Numbers are never reused, even for `Not a bug` rows.

## Rules that bind every entry here

- **No personal health data in this directory.** The fork is public. Record agreement figures, counts
  and bug behaviour; never per-night or per-session rates, times, dates tied to readings, or strap
  classifier codes tied to sessions. The raw data (backups, strap logs, ECG exports in the repo root) is
  gitignored and must stay that way.
- **No bare `@` before a number** in anything that reaches GitHub; write `byte 82`, not an at-sign form,
  because GitHub turns it into a user mention.
- **Commits and PRs carry no AI attribution lines.** One PR per workstream batch, one commit per fix;
  refactors never share a PR with bug fixes.
- The engineering rules in [`AGENTS.md`](../../AGENTS.md) apply (oracle-verify formulas, build both app
  targets, design tokens, i18n gate, append-only migrations). Its ECG display limits are upstream policy
  and are not review findings in this fork.
