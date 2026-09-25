# W12 — Docs and truth

**Phase** 6, plus findings logged from every other workstream as they surface · **Decisions** all
(`ARCHITECTURE.md` is rewritten to match the verdicts) · **Status** on the
[board](../README.md#status-board) · **Method** [METHOD.md](../METHOD.md)

Everything that makes a claim about the code: `docs/`, `AGENTS.md`, `README.md`, in-app copy and
release notes, and log lines. A claim the code does not back is a finding even when the code is fine.

## Read first

The "a diagnostic may only assert what it can attribute" and "two readouts of one fact" bullets in
`AGENTS.md`.

## Where to start

| Path | Why |
|---|---|
| `docs/ARCHITECTURE.md` | Already drifts from the code (W12-001) |
| `docs/DATA_MODEL.md` | Tables and columns vs the 49 migrations |
| `docs/PROTOCOL_*.md` | Authoritative for layouts; `PROTOCOL_IMPLEMENTATION.md` references are CI-checked |
| `docs/SCOPE.md`, `docs/PRIVACY_SECURITY.md`, `README.md` | Offline and privacy claims vs AD-11 |
| `docs/FEATURES.md`, `docs/FAQ.md` | Feature claims vs what ships |
| `Strand/System/AppChangelog.swift`, `CHANGELOG.md` | Release notes shown in the app |
| Strap-log lines in `Strand/BLE/*` | Diagnostics that must only assert what they observed |

## Checks

- [ ] `ARCHITECTURE.md`: store type, schema version, package graph, network clients, concurrency model.
- [ ] `DATA_MODEL.md`: every table and column exists as described.
- [ ] Every file and symbol reference in `docs/` resolves (extend the CI checker beyond
      `PROTOCOL_IMPLEMENTATION.md` if cheap).
- [ ] Offline and privacy claims in docs and UI match what AD-11 finds.
- [ ] Log lines that overclaim, collected from W6 and W9 reviews, are corrected without going silent.
- [ ] `AGENTS.md` still describes the fork's CI and scope accurately.

## Review passes

- [ ] 1 Map · [ ] 2 Static sweep · [ ] 3 Deep read · [ ] 4 Run · [ ] 5 Adversarial

## Gate

`source-hygiene` checks pass; each corrected claim cites the code that backs it.

## Findings

| ID | Sev | Status | Finding | Location | Evidence | PR |
|---|---|---|---|---|---|---|
| W12-001 | S4 | Reported | `ARCHITECTURE.md` says `DatabaseQueue`, schema version 11 and no network client, and omits `NoopLocalAccess` | `docs/ARCHITECTURE.md` §3, §4, §7, §11 | `WhoopStore.swift` opens a `DatabasePool`; 49 migrations; `Strand/AI`; `UpdateChecker` | |
| W12-002 | S4 | Reproduced | `AGENTS.md` (CI table, "the trap", local walls) and `docs/CONTRIBUTING.md` say `app-build.yml` is disabled; it is active in the fork and ran on each of the last five PRs. Upstream `5783c499` fixes the same text (conflicts on pick) | `AGENTS.md:115,125,137`; `docs/CONTRIBUTING.md:267-273` | `gh workflow list -R ayiskakov/noop`; AD-12 | |

## Log

- 2026-09-25 — File created from the plan. W12-001 seeded from the baseline scan.
- 2026-09-25 — Phase 0: W12-002 recorded while settling AD-12.
