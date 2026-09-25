# W4 — Import and export

**Phase** 2 · **Decisions** — · **Status** on the [board](../README.md#status-board) ·
**Method** [METHOD.md](../METHOD.md)

Parses data the user already owns (WHOOP CSV, Apple Health, FIT/GPX/TCX, lab and nutrition CSV, lift
logs) and exports CSV and routes. `Packages/StrandImport`: 8.3k source lines, 4.4k test lines in 21
files — the lowest test ratio of the data packages.

## Read first

`docs/ARCHITECTURE.md` §8, `docs/LIFT_LOG_PROGRAM_IMPORT.md`, `docs/PRIVACY_SECURITY.md`.

## Where to start

Paths under `Packages/StrandImport/Sources/StrandImport/` unless noted.

| File | Symbols | Why |
|---|---|---|
| `ImportCoordinator.swift` | `detectAndImport` | Format detection and dispatch |
| `AppleHealthImporter.swift`, `AppleHealthAggregator.swift` | streaming XML | Largest importer; memory on multi-GB exports |
| `WhoopExportImporter.swift`, `WhoopDayKeying.swift`, `WhoopBiomarkerExportParser.swift` | WHOOP CSV | Day keys must match the app's local day |
| `WhoopCsvExporter.swift` | export | Round-trip partner of the WHOOP importer |
| `CSVParsing.swift` | parser | Quoting, encodings, line endings |
| `FitParser.swift`, `GpxParser.swift`, `TcxParser.swift`, `ActivityFileImporter.swift`, `RouteExporter.swift` | activity files | Units, epochs, time zones |
| `LabMarkerCsvImport.swift`, `NutritionCsvImport.swift`, `MarkerCatalog.swift` | lab and nutrition | Unit conversion and marker matching |
| `LiftingImporter.swift`, `LiftProgramSheetImporter.swift`, `XlsxSheet.swift` | lift logs | XLSX parsing |
| `HealthWriteback.swift` | write-back | What NOOP writes back to Apple Health |
| `Strand/Data/WhoopImporter.swift`, `AppleHealthImport.swift`, `ShortcutHealthImport.swift` | app glue | How parsed rows reach the store |

Tests: `Packages/StrandImport/Tests/StrandImportTests`.

## Contracts this area owns

- Parsing only: the package returns normalised models; the app writes them.
- Import never partially writes on failure, and re-import is idempotent.

## Checks

- [ ] Malformed, truncated, huge and wrongly encoded files fail cleanly with no partial write.
- [ ] `WhoopDayKeying` agrees with `LocalDayWindows` on every boundary case.
- [ ] Re-importing the same file adds no duplicate rows.
- [ ] Units and epochs per format are right (FIT semicircles and its 1989 epoch, GPX and TCX zones).
- [ ] WHOOP CSV export → import round-trips.
- [ ] Apple Health streaming keeps memory bounded on a multi-GB export.
- [ ] Health write-back is deduplicated and never writes back data NOOP imported from Health.

## Review passes

- [ ] 1 Map · [ ] 2 Static sweep · [ ] 3 Deep read · [ ] 4 Run · [ ] 5 Adversarial

## Gate

Fixture tests including malformed input; import → export round-trip; app build for glue changes.

## Findings

| ID | Sev | Status | Finding | Location | Evidence | PR |
|---|---|---|---|---|---|---|

## Log

- 2026-09-25 — File created from the plan.
