# Review plan

The review covers the whole fork: about 285k lines of Swift across 6 packages, 6 app targets, Tools
and CI, plus the architecture that ties them together. Every finding is reproduced before it is fixed
and checked again after the fix, in three separate passes. Status lives in [`README.md`](README.md).

## Goals

1. Find and fix correctness bugs. Rank them by blast radius: anything that reaches disk or a score
   first, then anything the 5.0/MG strap exercises daily.
2. Evaluate each load-bearing architectural decision in [`DECISIONS.md`](DECISIONS.md) and record a
   verdict: Keep, Amend or Replace.
3. Refactor only where the structure breeds bugs (god objects, duplicated resolvers, two readouts of
   one fact), not for taste.
4. Leave a test or oracle pinned behind every fix, so the result survives future upstream merges.

## Scope

**In:** `Packages/*`, `Strand/`, `StrandiOS*`, `NOOPWatch*`, `StrandTests/`, `Tools/` (Swift and
Python), `.github/workflows/`, `project.yml`, and the docs the code cites (`PROTOCOL_*.md`,
`DATA_MODEL.md`, `ARCHITECTURE.md`).

**Out:** the generated `Strand.xcodeproj/`, `build/`, `marketing/`, and the owner's data files in the
repo root. Those files are test inputs only and are never committed.

## What counts as a finding

- **Bug:** reproducible wrong behaviour.
- **Risk:** a contract that can break silently (migration, backup key, hash, dedup key, CRC gate).
- **Design:** a structure that has already produced a bug class, or clearly will.
- **Truth:** a doc, UI string or log line that claims more than the code backs.
- Style nits are not findings.

## Ground rules

- Correctness first; dedupe and refactor second.
- Reproduce before fixing: an oracle run or a failing test, never a re-read. Each finding is marked
  confirmed, confirmed with caveat, or not a bug, with the evidence attached.
- Stored data is a byte-level contract. Migrations are append-only, the `.noopbak` whitelist is
  versioned, and hashes that reach disk are platform-stable.
- BLE changes never add a destructive command. They are validated on the MG strap via the iPhone
  bench, since macOS cannot bond a 5/MG.
- App-target Swift is compiled locally for both `Strand` and `NOOPiOS` before pushing. The fork's
  `app-build.yml` is active and gates every PR that touches app paths (see AD-12), but a local build
  saves a ten-minute round trip per mistake.
- One PR per workstream batch with one commit per fix. No AI attribution lines, no bare at-sign-number
  text on GitHub, and no health data in commits.
- This fork is a personal research build. The `AGENTS.md` ECG display limits are not review findings.
- Each fix is tagged upstream-able or fork-only, so candidates for `ryanbr/noop` are easy to pick later.

## Phases

The review runs in seven phases, ordered by how hard a bug is to undo. Stored data comes first
because a wrong row outlives the code that wrote it; screens come last because a wrong pixel is fixed
by the next build. Architecture refactors wait until the correctness fixes in their area have landed.

| Phase | Workstreams | Decisions settled | Exit gate |
|---|---|---|---|
| 0. Baseline | All (measure only) | AD-12, AD-13 | Upstream freeze point recorded; every suite and both app builds run once, with failures recorded; strict-concurrency warning count taken; replay harness runs on the newest backup |
| 1. Data integrity | W2, W1, safe-trim and backfill part of W6 | AD-2, AD-5, AD-6 | No open S1 or S2 in these areas; migration and backup round-trip tests green on a real backup |
| 2. Computation | W3, W4, W7 | AD-7, AD-8 | Replay diff explained row by row; every changed formula pinned by an oracle |
| 3. Device and runtime | Rest of W6, W9, W10 | AD-3, AD-4, AD-11, AD-14 | Overnight strap run clean on the new build; no new strict-concurrency warnings |
| 4. Presentation | W8, W5 | AD-9, AD-10 | Single-resolver tests for each shared fact; token scan clean; i18n gate green |
| 5. Architecture refactors | Per Amend or Replace verdict | Act on the verdicts | Each refactor shows zero behaviour diff |
| 6. Close | W11, W12 | Rewrite `ARCHITECTURE.md` | Full regression: all suites, both builds, one day and night on the strap |

**How work is batched**

- Review is read-only, so workstreams within a phase can be reviewed in parallel. Fixes are serialised
  per file to avoid conflicts.
- One PR per workstream batch, one commit per fix. A refactor never shares a PR with a bug fix.
- Upstream is frozen for the review (answered 2026-09-25): the fork is reviewed as it stands, and
  upstream commits are taken only before Phase 5, through `Tools/upstream-candidates.py`. A finding
  that upstream has already fixed cites the upstream commit, which may be ported as its fix.
- Each PR lists its finding IDs; findings marked upstream-able are collected for `ryanbr/noop` at
  Phase 6.
- A phase closes only when its exit gate passes. An S1 found in a later phase pauses that phase until
  it is fixed.

## Exit criteria

- All twelve workstreams went through the five review passes, each ticked in its workstream file.
- All fourteen decisions carry a Keep, Amend or Replace verdict with the evidence linked.
- Zero open S1 or S2 findings. Every S3 is fixed or `Deferred` with a stated reason. Every S4 is triaged.
- Every `Verified` finding has a test that fails when its fix is reverted.
- `StrandTests` and both app builds pass locally on the final commit.
- `ARCHITECTURE.md` and `DATA_MODEL.md` match the code.
- One full day and night on the strap with the final build shows no regressions against the Phase 0
  baseline.

## Open questions

Answers go here, dated, and then into the affected file.

- [x] Should the fork's CI run a compile-only app build on every PR (macOS runner minutes), or do local
      builds stay the gate? (AD-12) — 2026-09-25: already answered by the fork's own settings.
      `app-build.yml` is active here and runs on every PR touching app paths, `StrandTests` included.
      See AD-12.
- [x] Should each phase's review passes fan out as a multi-agent workflow (faster, uses far more
      tokens), or run one workstream at a time? — 2026-09-25: one multi-agent workflow per phase for
      the map, deep-read and adversarial passes (under ten agents). Fixes stay serial, one agent.
- [x] Which areas does the fork own and refactor freely, and which should stay close to upstream to
      keep merges cheap? (AD-13) — 2026-09-25: the fork owns everything. Upstream is a source of fixes
      and ideas, not a merge target; no refactor is held back to keep picks cheap. See AD-13.
- [x] Take upstream in Phase 0, or freeze it? — 2026-09-25: freeze. Review the fork as it stands;
      take upstream only before Phase 5.
- [ ] For concurrency, is the target warning-clean under complete checking, or full Swift 6 mode for
      the packages? (AD-4) — deferred until the Phase 0 warning counts are in.
- [x] Is the iPhone the only hardware bench, or is the Mac used for unbonded checks too? —
      2026-09-25: the iPhone only.
