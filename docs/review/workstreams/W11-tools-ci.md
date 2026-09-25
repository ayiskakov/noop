# W11 — Tools, CI, build

**Phase** 0 (AD-12, AD-13), 6 (the rest) · **Decisions** [AD-12](../DECISIONS.md#ad-12),
[AD-13](../DECISIONS.md#ad-13) · **Status** on the [board](../README.md#status-board) ·
**Method** [METHOD.md](../METHOD.md)

Workflows, the XcodeGen spec, release and distribution scripts, validation tools, and the Python
capture and audit tooling. `Tools/` has 4.4k Swift lines plus Python.

## Read first

`docs/BUILD.md`, the CI table and "a gate must be able to fail" bullet in `AGENTS.md`, `docs/HOMEBREW.md`.

## Where to start

| Path | Why |
|---|---|
| `.github/workflows/swift-packages.yml` | Package tests and the `tools` job |
| `.github/workflows/app-build.yml` | App builds and `StrandTests`; active on app-path PRs in this fork (AD-12) |
| `.github/workflows/source-hygiene.yml`, `i18n-coverage.yml`, `tools-python.yml` | Hygiene gates and their test-count floors |
| `.github/workflows/fork-release.yml`, `fork-testing-build.yml`, `Tools/release.sh`, `Tools/update-altstore-source.sh`, `altstore-source.json` | Fork release and AltStore distribution |
| `project.yml` | XcodeGen spec: targets, build settings, deployment targets |
| `Tools/upstream-candidates.py`, `Tools/upstream-skip.txt` | Upstream tracking (AD-13) |
| `Tools/doc_comment_lint.py` + baseline, `Tools/i18n_audit.py` + baselines | Ratcheting lint baselines |
| `Tools/SleepBench`, `Tools/SleepPSG`, `Tools/SleepTrain`, `Tools/oracle-twins` | Validation tooling used by W3 |
| `Tools/Backfill` | Build-only package (no tests) |
| `Tools/linux-capture` | Python capture and decode tools with their own test floor |
| `Tools/anonymize-*.sh`, `Tools/prepare-ios-sideload-app.sh` | Build post-processing |

## Contracts this area owns

- No gate passes on zero results: floors on test counts, non-success checks rather than failure counts.
- Release artefacts point at this fork, not upstream.
- Baselines only ratchet down.

## Checks

- [ ] Every workflow gate can fail on the change that breaks it; floors are below the current count.
- [ ] Decide AD-12: a compile-only app job on PRs, with its runner cost.
- [ ] Fork release path (AltStore source, bundle identifiers, git identity in workflows) points at the
      fork end to end.
- [ ] `project.yml` settings reviewed with AD-4 (Swift version, strict concurrency) and entitlements.
- [ ] Scripts that publish or rewrite files have tests or a dry-run mode.
- [ ] `Tools/Backfill` still builds; decide whether it needs a test target or can go.
- [ ] Run `Tools/upstream-candidates.py` at Phase 0 and before Phase 5; record the result in AD-13.

## Review passes

- [ ] 1 Map · [ ] 2 Static sweep · [ ] 3 Deep read · [ ] 4 Run · [ ] 5 Adversarial

## Gate

`tools-python` locally; workflow changes exercised on a branch in the fork before merge.

## Findings

| ID | Sev | Status | Finding | Location | Evidence | PR |
|---|---|---|---|---|---|---|
| W11-001 | S4 | Reproduced | Four `check_source_references` tests fail on macOS: the checker resolves the doc path (`/var` → `/private/var`), the test expects the unresolved temp path. CI runs Linux, so it never sees this. Test-only; upstream-able | `Tools/test_check_source_references.py` `setUp` (`Path(self.temp.name)`), `docs/protocol-examples/check_source_references.py:111` | Phase 0 run: 112 tests, 4 failures, all `/var/folders/…` vs `/private/var/folders/…` | |
| W11-002 | S4 | Reported | `UnescalatedWorkTests.testAwaitingADetachedTaskEscalatesItInstead` is timing-dependent: the detached task can read its own priority before the main-actor `await` escalates it, so the control fails now and then under load | `StrandTests/UnescalatedWorkTests.swift` | Seen once in a full `StrandTests` run on 2026-09-25 while the NOOPiOS build ran alongside (the body saw `.utility`, which prints as `.low`: not escalated); the rerun passed all 2,010. The test is unchanged since upstream #2202. A control that asserts a scheduling outcome needs the task held until the await is registered, or a note that it may flake |  |

## Log

- 2026-09-25 — File created from the plan.
- 2026-09-25 — Phase 0: AD-12 settled as Keep (`app-build.yml` is active in the fork). AD-13 amended:
  the fork owns every area, upstream frozen at `1c3f0f9f` (37 commits to decide: 26 clean, 11
  conflicting). Tools suites run: W11-001 reproduced. `Tools/Backfill` still builds. Next: the rest of
  this file in Phase 6.
- 2026-09-25 — W11-002 recorded: a timing-dependent control test failed once in a full `StrandTests`
  run during the fifth W6 batch and passed on the rerun. Not fixed yet.
