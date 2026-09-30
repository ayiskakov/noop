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

**Current phase:** 1 — Data integrity (in review since 2026-09-25). Phase 0 closed 2026-09-25; its numbers are in
[`BASELINE.md`](BASELINE.md#phase-0-measurements). See [`PLAN.md`](PLAN.md#phases).

| WS | Area | File | Phase | Status |
|---|---|---|---|---|
| W1 | Protocol | [W01-protocol.md](workstreams/W01-protocol.md) | 1 | In review |
| W2 | Storage | [W02-storage.md](workstreams/W02-storage.md) | 1 | In review |
| W3 | Analytics | [W03-analytics.md](workstreams/W03-analytics.md) | 2 | Not started |
| W4 | Import and export | [W04-import.md](workstreams/W04-import.md) | 2 | Not started |
| W5 | Local access (MCP / CLI) | [W05-local-access.md](workstreams/W05-local-access.md) | 4 | Not started |
| W6 | BLE and collection | [W06-ble-collect.md](workstreams/W06-ble-collect.md) | 1 (safe-trim), 3 (rest) | In review |
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

- [x] Run the Phase 1 review workflow (owner's choice: one multi-agent workflow per phase, under ten
      agents): passes 1 Map, 2 Static sweep, 3 Deep read and 5 Adversarial for each of the three areas.
      Agents return findings; one writer records them as `Reported` rows, so the files never collide.
      Done 2026-09-25, run `wf_f9451f0b-2c7`: 5 reviewers and 3 adversaries; findings in W1, W2 and W6.
- [x] Settle AD-2, AD-5 and AD-6 in [`DECISIONS.md`](DECISIONS.md): all three Amend.
- [ ] V0 every finding (pass 4); fix S1 and S2 first; one PR per workstream batch. No S1 reported; the
      S2 rows are W02-002, W02-003, W02-005 and W06-002. First batches, one PR each, stacked on this
      branch: `review/w02-fixes`, `review/w01-fixes`, `review/w06-fixes`. W2's three S2s pass V1, V2 and V3;
      W06-002 waits on the strap run.
- [x] Strap run agreed with the owner (2026-09-25): one sync and one short Raw Data Collector session on a
      build with the W1 and W6 batches, strap log attached. Done on 11.9.8 with a backup and the reject
      archive as well: W06-002 banks, W01-003 and W01-004 hold on real traffic, and the run found W06-025.
      Evidence in the W1 and W6 rows and logs.
- [x] V2 of the W1 and W6 batches by independent reviewers (2026-09-25): all four hold; they added W01-010 …
      W01-015 and W06-026 … W06-035, all S3 or S4.
- [ ] Second W6 batch, `review/w06-fixes-2` (stacked on this branch): W06-025, W06-026, W06-027, W06-029,
      W06-031, W06-032, W06-033. W06-027 completes W06-002's V1. Then a strap run of it: a Raw Data Collector
      session that reads ready, and a reconnect. A code review of the batch added W06-036 … W06-049; W06-036,
      W06-037, W06-039 and W06-044 are fixed on the same branch, and W06-043 reopens W06-027's V1. Merged as PR #28 and
      shipped in 11.9.9; its strap run passed the tail and the R21 gate and found W06-050 … W06-052.
- [x] Third W6 batch, `review/w06-fixes-3`: W06-038, W06-041 (step 1), W06-042, W06-043, W06-046, W06-047,
      W06-049. Merged as PR #29 and shipped in 11.9.10. Its strap run passed W06-025's V3 (a session read ready),
      gave W06-041 its layout evidence, and found W06-053.
- [ ] Fourth W6 batch, `review/w06-fixes-4`: W06-053 (S1, closing the marker sheet ends the app; it accounts for
      the marker-linked deaths in W06-051). Merged as PR #30. Then a strap run: markers added, edited, cancelled
      and deleted during a session.
- [ ] Fifth W6 batch, `review/w06-fixes-5`: W06-041 step 2 (live buffers need layout 21), W06-018 with W06-052
      (the raw IMU fail-safe becomes a note that sends nothing, one line per stream naming its owner), W06-007
      (tests pin every hold-ack path). A code review of the batch added W06-054 … W06-064: W06-054 (W06-052's fix
      missed the relaunch's first frames) and the rest are fixed on the same branch, except W06-057 (not a bug). Owner decisions 2026-09-25: W06-050 reads the clock before setting it, in its own PR with W06-001;
      W06-052 keeps an honest line rather than none. Then a strap run: a relaunch mid-session logs no Raw IMU line,
      and an MG ECG session that brings a type-43 stream logs one line naming it. On the owner's 2026-09-28
      export an ECG session that produced only ECG records logged no note, which is correct; the positive
      case (a non-ECG type-43 stream) and the relaunch are still due.
- [ ] W06-050 with W06-001, `review/w06-clock-read-first`: the 5/MG handshake reads the strap clock and sets it only
      when the reading is refused, invalid or more than 2 s off (the owner's 2026-09-25 decision); W06-022 and
      W06-065 ride along. A code review of the batch added W06-069 … W06-083: ten are fixed on the same branch, two
      are not bugs, W06-077 and W06-078 are proposed for Phase 5, and W06-083 is Phase 3. A second code review added
      W06-084 … W06-107: all are fixed on the same branch except W06-088, W06-094 and W06-102 (deferred with
      reasons) and W06-104 … W06-106 (proposed for Phase 5). Then a strap run: a plain connect sends no SET_CLOCK, a
      relaunch during a Raw Data Collector session skips no IMU label, a Test Centre connect logs the #1303 line, a
      relaunch with Test Centre on logs the second read and an in-sync verdict, and Bluetooth off and on inside a
      connect's first 10 s leaves the next link with a clock verdict of its own. Merged as PR #33 and shipped in
      11.9.12. First strap check done on the owner's 2026-09-27 export: a plain connect sent no SET_CLOCK and moved
      the strap clock 0 s (the strap's own `SET_RTC` events; W06-050's row). The log ring had evicted that
      connect's handshake (W06-108). Second strap check on the owner's 2026-09-27 evening export (11.9.13): checks
      3 (the #1303 line) and 4 (a relaunch's second read and in-sync verdict) pass; checks 2 and 5 are still due.
      The same export showed W06-083 on hardware: a Bluetooth power-off later in a link leaves the next link with
      no handshake and no clock check, so check 5 covers only the first 10 s until W06-083 is fixed. The
      owner's 2026-09-28 morning export (11.9.13) showed W06-083 twice more (toggles 140 s and 22 s into their
      links) and one SET_CLOCK last evening that stepped the strap 2 s; four app launches soon after evicted its
      process from the three-generation log ring, so its reason is not attributable. Checks 2 and 5 are still due.
- [ ] Sixth W6 batch, `review/w06-fixes-6` (stacked on `review/strap-run-2026-09-27`), from the 2026-09-27 export:
      W06-108 (the strap log keeps hours, and a clipped session says so), W06-113, W06-109; W06-114 and W06-115
      recorded. V2 (independent subagent) held all three with caveats and added W06-116 … W06-122 and W07-005:
      W06-116 … W06-120 are fixed on the same branch, W06-121, W06-122 and W07-005 are recorded. Then a strap run: a
      current session spanning about 2 h or more with Test Centre → Connection on, and an off-wrist offload that logs
      `Wrist: WRIST_OFF on this link` and no clock/charge line. Once this batch ships, the clock batch's
      remaining checks no longer need the log exported within an hour. Merged as PR #34 and shipped in 11.9.13. Its
      strap run, on the owner's 2026-09-27 evening export, is partial: an 82-minute session with Connection on came
      out whole (about 2.2 h of ring at its density, and W06-118's per-reading flood is gone), and the off-wrist
      offload logged the wrist line and no clock or charge line but stalled before the no-cursor branch (W06-110).
      Still due: the 2 h session, and an off-wrist offload that ends on trim=0xFFFFFFFF. The off-wrist offload
      passed on the owner's 2026-09-28 export (W06-109 and W06-113 Verified); the 2 h session is still due and
      needs an export taken without relaunching the app first (W06-142).
- [ ] W07-005 on `review/w07-day-line-repeats` (stacked on `review/w06-fixes-6`): a re-score prints a day's line
      only when it changed or its last print is an hour old, and counts what it withheld. On the 2026-09-27 log's 12
      passes, 840 per-day lines become 171 and 11 summaries. V2 (independent subagent) held with caveats and added
      W07-006 … W07-009: W07-006 … W07-008 are fixed on the same branch, W07-009 (the `analyzeRecent` lock is not
      single-flight, S3, predates the fix) is recorded. Merged as PR #35 and shipped in 11.9.13; V3 passes on the
      owner's 2026-09-27 evening export (18 passes: 1,422 per-day lines become 366 and 16 summaries), and
      again on the 2026-09-28 export; W07-005 Verified.
- [ ] Seventh W6 batch, `review/w06-fixes-7` (rebased onto `main` after #35 and #36 merged), strap-free: W06-014 (a
      relaunch can bootstrap the store twice), W07-009 (two re-scores can hold the lock at once), W06-008 (a
      drain can outlive its link and interleave with the next one's), W06-005 (every sync reports intact v20
      and v21 records as undecodable). V2 (independent subagent) held W06-014 and W07-009 and held W06-008 and
      W06-005 with caveats; it added W06-123 … W06-128: W06-123, W06-125 and W06-126 are fixed on the same branch,
      W06-124, W06-127 and W06-128 are recorded. StrandTests 2,084, WhoopProtocol 788, both builds. An xhigh code
      review of the batch added W06-129 … W06-139 and W07-010 … W07-013: all are fixed on the same branch, with
      W06-124, except W07-013 (deferred: the fix would rewrite PR #35's pushed history); W07-014 recorded. On `main` with
      #36: StrandTests 2,097, WhoopProtocol 794, WhoopStore 554, both builds (NOOPiOS without the watch app). Then a strap
      run: an iPhone relaunch by state restoration, a reconnect in the middle of an offload, and a sync whose
      status no longer names v20/v21 records as undecodable. Shipped in 11.9.14; the 2026-09-28 export ran on
      11.9.13, so only a replay was possible: `main` classifies the 24 dumped rejects of that export's sync as
      0 undecodable.
- [ ] Eighth W6 batch, `review/w06-fixes-8` (stacked on `review/strap-run-2026-09-27b`, which is stacked on the
      seventh batch), from the owner's 2026-09-27 evening export: W06-140 (the owner-name redaction rule was
      quadratic on a long hex run) and W06-110 (the reject hex dump is logged after the ack, since the strap drops a
      transfer acked 7 s or more after its chunk). StrandTests 2,100, both builds. Then a strap run: a sync with
      undecodable records whose ack follows its chunk within about 2 s. Shipped in 11.9.14; not yet on the
      phone at the 2026-09-28 export. W06-083 (a Bluetooth power-off skips the
      next link's handshake) is proposed to the owner for the next batch.
- [ ] Ninth W6 batch, `review/w06-fixes-9` (stacked on `review/strap-run-2026-09-28`): W06-083 (a Bluetooth
      power-off or reset ends the held link through the same teardown as a disconnect), W06-141 (the launch reconnect
      line names the app state it saw), W06-121 with W06-115 (wrist events ordered by strap time). W06-142 deferred to
      Phase 3 (a file-backed strap log). AD-15 recorded with the owner (split `BLEManager` into transport, link session
      and WHOOP policy; Phase 5, W06-143). V2 (independent subagent) held W06-083, W06-141 and W06-121/115 with caveats
      and refuted W06-144: its park would resume the #844 bond loop, so it is backed out and waits on the owner's call.
      Its other findings, W06-145 … W06-153, are fixed on the same branch except W06-153 (recorded). A code review
      (`/code-review xhigh`) then found W06-154 … W06-166; all are fixed on the same branch except W06-156, W06-163 and
      W06-164 (recorded; W06-163 is the owner's call and W06-164 goes to Phase 5 with W06-143). StrandTests 2,125, both
      builds (NOOPiOS without the watch app). Then a strap run: Bluetooth off and on mid-link from Settings and from
      Control Center (a `Link ended` line, then GET_CLOCK and a clock verdict on the next link), and the strap put back
      on while unlinked (`WRIST_ON reached through a sync`), then on and off again while unlinked
      (`WRIST_OFF reached through a sync`).
- [x] Batch check (METHOD step 6) for the first three batches: suites and both builds pass on 11.9.8. The day
      and night on the strap ran on 11.9.11 and 11.9.12, which carry all three batches (owner's 2026-09-27
      export): W01-003, W01-004, W02-002, W02-003 and W06-002 move to `Verified`; the batch rows without a
      recorded V2 or V3 stay `Fixed`.
- [x] Owner decisions, 2026-09-25: W02-004 deferred to Phase 5, W02-007 to Phase 4, W02-009 to Phase 3;
      W01-006 delegated and decided (a `rawRecord` storage lane). Recorded in the workstream rows. W01-006 fixed on
      `review/w01-raw-record` (migration v50); a strap sync then shows new v26 rows carrying their record.
      Merged as PR #36 and shipped in 11.9.13: on the owner's 2026-09-27 evening export all 154 new v26 rows carry
      their record; the v16 half passed on the owner's 2026-09-28 export (38 of 38 new v16 rows after an ECG
      session). The row stays Fixed until an independent V2 runs.
- [ ] Exit gate: a migration test and a `.noopbak` export → import round trip on a copy of the newest
      backup, and no open S1 or S2 in the three areas. The first half passes: `StrandTests/RealBackupGateTests`
      (run with `TEST_RUNNER_NOOP_GATE_BACKUPS`) on three real backups, and on both 2026-09-25 exports (one
      from 11.9.7, one from 11.9.8): 37 tables and about 4.28 M rows each come back identical after export,
      import and a restore over an open store. Re-run on the 2026-09-27 export from 11.9.12: 49 → 49
      migrations, 37 tables and about 5.33 M rows, identical. Re-run on the 2026-09-27 evening export from 11.9.13: 50 →
      50 migrations, 37 tables and about 5.53 M rows, identical. Re-run on the 2026-09-28 export from 11.9.13: 50 →
      50 migrations, 37 tables and about 5.85 M rows, identical.
- [ ] W3 out of phase, `review/w03-spo2-quality` (off `main`), from the owner's 2026-09-30 export: W03-007
      (the SpO₂ candidate leaves low-quality byte-82 readings out of the night and states a night with no
      reliable reading as such, the owner's choice). V2 (independent subagent) found one S2, four S3 and
      eight S4; all fixed on the branch except W03-008 (recorded). A code review (`/code-review xhigh`) then
      found W03-009 … W03-022; all are fixed on the same branch except W03-022 (deferred to the merge).
      Package suite, `StrandTests`, both builds (NOOPiOS without the watch app), i18n and hygiene gates pass. Then a strap run: a night on the build
      whose card reads "N of M" with the readings left out named, and its strap-log line; ideally one night
      with the strap deliberately loose, to see "no reliable reading".
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
