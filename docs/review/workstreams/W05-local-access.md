# W5 — Local access (MCP and CLI)

**Phase** 4 · **Decisions** [AD-7](../DECISIONS.md#ad-7) · **Status** on the
[board](../README.md#status-board) · **Method** [METHOD.md](../METHOD.md)

`noop-local-access` exposes bounded, read-only health data locally, over MCP on stdio or as one-shot
CLI queries. `Packages/NoopLocalAccess`: 1.5k source lines, 0.4k test lines in 5 files.

## Read first

`Packages/NoopLocalAccess/README.md` (tools, arguments, bounds, exit codes), `docs/PRIVACY_SECURITY.md`.

## Where to start

Paths under `Packages/NoopLocalAccess/Sources/`.

| File | Symbols | Why |
|---|---|---|
| `NoopLocalAccessCore/LocalAccessCore.swift` | `DatabaseQueue` with `readonly = true` | Database open and every query |
| `NoopLocalAccessCore/MCPServer.swift` | MCP loop | JSON-RPC handling over stdio |
| `NoopLocalAccessCore/ToolDispatcher.swift` | dispatcher | Argument defaults and clamps shared by MCP and CLI |
| `NoopLocalAccessCore/CLIQuery.swift` | CLI | Argument parsing, exit codes 64 and 1 |
| `NoopLocalAccessCore/JSONValue.swift` | JSON | Encoding of results |
| `noop-local-access/main.swift` | entry | `mcp` vs `query` modes, `NOOP_DB_PATH` |

Tests: `Packages/NoopLocalAccess/Tests/NoopLocalAccessCoreTests`.

## Contracts this area owns

- No network and no write or control path.
- Every tool's arguments are clamped to the bounds in the README.

## Checks

- [ ] The database is read-only at the SQLite level (`readonly = true`), and a write attempt fails in a
      test.
- [ ] Every SQL statement binds its arguments; none is built from a caller string.
- [ ] Clamps in the README match the dispatcher, for every tool.
- [ ] Malformed JSON-RPC input returns an error, never crashes or hangs.
- [ ] `metric_series --source` defaults to `my-whoop`; check it against the active-strap decision (AD-7).
- [ ] Opening a database mid-migration or locked by the app gives a clear error.

## Review passes

- [ ] 1 Map · [ ] 2 Static sweep · [ ] 3 Deep read · [ ] 4 Run · [ ] 5 Adversarial

## Gate

`swift test`, including a test that every write attempt fails.

## Findings

| ID | Sev | Status | Finding | Location | Evidence | PR |
|---|---|---|---|---|---|---|

## Log

- 2026-09-25 — File created from the plan.
