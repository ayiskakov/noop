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

- [x] 1 Map · [x] 2 Static sweep · [x] 3 Deep read · [ ] 4 Run · [x] 5 Adversarial

## Gate

Fixture tests including malformed input; import → export round-trip; app build for glue changes.

## Findings

| ID | Sev | Status | Finding | Location | Evidence | PR |
|---|---|---|---|---|---|---|
| W04-001 | S4 | Reported | The raw-sensor CSV's `spo2_red`/`spo2_ir` columns read `spo2Sample`, which a 5/MG never fills, and the 5/MG byte 82 candidate (`v18AuxSample`) is not exported at all | `StreamStore.swift` `exportRawCSV` | V0 (2026-09-27 export): 0 `spo2Sample` rows and 85,007 `v18AuxSample` rows in the CSV's window | |
| W04-002 | S2 | Fixed | The FIT importer takes the uint8 invalid value 0xFF as a heart rate of 255 bpm in record, lap and session fields, and the activity-file path stores those 255s as a per-second HR stream plus avg/max HR, which #137 uses for day Effort on a strap-less day | `FitParser.swift` `consumeRecord`, `consumeLap`, `consumeSession`; `ActivityFileImporter.validHr`; persisted in `DataSourcesView` | Phase 2 workflow `wf_b77f01a5-1aa` (W4-1); P5 confirmed: Garmin writes 0xFF whenever the HR sensor drops out; only `RouteExporter` guards it. Oracle O6 (synthetic) printed bpm [120, 255, 255, 130, 255]. V0 plan: `ActivityFileImporterTests.testFitHeartRateInvalidSentinelIsDropped`. V0: `ActivityFileImporterTests.testFitHeartRateInvalidValueIsDropped` failed (stream [120, 255, 130], avg and max 255). Fix: `FitParser.heartRateField` reads 0xFF as no value for the record, lap and session heart-rate fields; the shared `validHr` is unchanged for GPX and TCX. V1: passes; failed with the 0xFF guard removed; StrandImport 279 pass | |
| W04-003 | S2 | Reported | Every writer of the apple-health daily rows replaces the whole row, so a Shortcut import (and the iOS HealthKit sync) nulls the columns an export.zip import filled for the same days (deep/REM/light, SpO₂, respiration, steps, SDNN, basal kcal, max and walking HR) | `ShortcutHealthImport.swift` `dailyMetricRows`, `ingest`; `MetricsCache.upsertDailyMetrics`; `upsertAppleDaily`; sibling `HealthKitBridge` rows (W10) | Phase 2 workflow `wf_b77f01a5-1aa` (W4-2); P5 confirmed with caveat: needs two Apple writers on one day; values return only by re-importing the zip. Both Shortcut and HealthKitBridge rows also omit `steps`, nulling the zip's #89 steps. V0 plan: `ShortcutHealthImportTests.testShortcutImportKeepsZipImportedColumns` plus a WhoopStore test pinning the upsert contract | |
| W04-004 | S2 | Fixed | The Apple Health importer keys each sleep-stage interval by its own end day, so every night that starts before midnight is split across two daily rows and each stored day mixes two nights | `AppleHealthAggregator.swift` `sleepDaily`; `AppleHealthImport.swift` | Phase 2 workflow `wf_b77f01a5-1aa` (W4-3); P5 confirmed: Apple Watch writes many short intervals; existing tests cover only one interval across midnight. Oracle O2 (synthetic 22:30–06:30 night): 60 and 420 min. V0 plan: `AppleHealthAggregatorTests.testStagedNightStartingBeforeMidnightLandsOnWakeDay`. V0: `AppleHealthAggregatorTests.testStagedNightStartingBeforeMidnightLandsOnWakeDay` failed (bed day 120 = an evening nap plus the night's first hour, wake day 420). Fix: `sleepDaily` joins intervals into nights first (a gap of `nightGapSeconds`, 2 h, or more starts a new one) and keys each night by the local day it ends on, at the offset of the interval that ends it. V1: passes; fails with the gap set to 0 (per-interval keying); StrandImport 280 pass. Sibling not fixed here: `HealthKitBridge` keys iOS HealthKit sleep per interval too (W10) | |
| W04-005 | S2 | Reported | The Apple Health aggregator sums sleep minutes and active/basal energy across sources, the double count #589 fixed for steps only | `AppleHealthAggregator.swift` `AppleDailySampleAccumulator.add`, `sleepDaily` | Phase 2 workflow `wf_b77f01a5-1aa` (W4-4); P5 confirmed with caveat: needs two sources of one type on one day, which NOOP's own iOS write-back produces for sleep and workout energy (see W04-006). Oracle O2/O3: 960 vs 480 min, 980 vs 500 kcal. V0 plan: two `AppleHealthAggregatorTests` cases | |
| W04-006 | S3 | Reported | The export.zip importer ingests the records NOOP itself wrote back to Apple Health, closing the loop the HealthKit read path excludes (`notNoopAuthored`) | `AppleHealthImporter.swift` `handleRecord`, `handleWorkout` | Phase 2 workflow `wf_b77f01a5-1aa` (W4-5); P5 confirmed with caveat (S2→S3): needs iOS write-back on and a later export.zip import of the same Health store. V0 plan: `AppleHealthImporterTests.testSkipsRecordsNoopWroteBack`, keyed on the `noop:` ExternalUUID prefix, not the display name | |
| W04-007 | S3 | Reported | FIT sport codes 13, 14 and 15 map to the wrong sports (alpine skiing → Strength Training, snowboarding → Cardio, rowing → Hiking), so a rowing file's strokes are doubled into steps and RouteExporter writes every hike as rowing | `FitParser.swift` `sportName`, `isFootSport`; `RouteExporter.swift` `fitSport` | Phase 2 workflow `wf_b77f01a5-1aa` (W4-6); P5 confirmed against Garmin's FIT SDK profile (13 alpine_skiing, 14 snowboarding, 15 rowing, 17 hiking); a NOOP round trip hides it. Introduced in 4b69da6fa; only sport 1 tested. V0 plan: `testFitSportEnumMatchesProfile`, `RouteExporterTests.testHikeExportsFitSport17` | |
| W04-008 | S4 | Reported | Partial or empty imports are shown as a plain success ("Imported N records") although the importer comment says a dropped span is surfaced, never hidden: `skippedSpans` reaches only the Test Centre trace, a WHOOP CSV entry failing CRC is skipped uncounted, and `ImportError.emptyExport` is never thrown | `AppleHealthImporter.runParser`; `AppModel.importAppleHealth`; `WhoopExportImporter.swift`; `ImportModels.swift` | Phase 2 workflow `wf_b77f01a5-1aa` (W4-7); P5 confirmed with caveat (S3→S4): a UI/comment claim; the data effect needs a bare truncated export.xml and is W04-003's. V0 plan: `WhoopExportImporterTests` corrupt-entry and no-CSV cases | |
| W04-009 | S3 | Reported | The CSV export's `journal_entries.csv` reads journal entries only from the imported ids, so every in-app answer (`noop-journal`) is dropped although Settings says the export carries the journal; it also drops numeric values and prefixes notes beginning with = + - @ with an apostrophe that survives re-import | `CsvExport.swift` journal read; `WhoopCsvExporter.swift` `field`, `journalCSV` | Phase 2 workflow `wf_b77f01a5-1aa` (W4-8); P5 confirmed with caveat: the in-app-journal gap is the strong part (a strap-only install exports an empty journal); the apostrophe affects only imported WHOOP notes. V0 plan: `WhoopCsvExporterTests` round trip plus a StrandTests CsvExport case | |
| W04-010 | S3 | Reported | The CSV export writes the skin-temperature deviation into WHOOP's absolute `Skin temp (celsius)` column for every computed day and never exports the absolute value NOOP stores | `WhoopCsvExporter.swift` `cyclesCSV` | Phase 2 workflow `wf_b77f01a5-1aa` (W4-9); P5 confirmed: the line predates `skinTempC` (v40); the only test uses an absolute value. V0 plan: `WhoopCsvExporterTests.testComputedDaySkinTempExportsAbsolute` | |
| W04-011 | S3 | Reported | The same Apple workout is stored twice under apple-health when it arrives through both export.zip and the iOS HealthKit sync, because the two paths spell multi-word sports differently and sport is part of the workout key | `AppleHealthImport.swift`; `AppleHealthImporter.swift`; `HealthKitBridge.sportName` (W10) | Phase 2 workflow `wf_b77f01a5-1aa` (W4-10); P5 confirmed with caveat: single-word types match; needs a HealthKit-sync user who also imports export.zip. V0 plan: a package assertion that both mappings agree, plus a StrandTests two-path case | |
| W04-012 | S3 | Reported | The shared CSV number parser strips every comma, so a nutrition file with decimal commas inflates values tenfold or more (the lab path has the decimal-comma rule this one lacks) | `CSVParsing.swift` `Dictionary.double`; `NutritionCsvImport.swift` | Phase 2 workflow `wf_b77f01a5-1aa` (W4-11); P5 confirmed with caveat: needs ISO dates with decimal commas (a dd.MM.yyyy file is rejected whole); the parser is shared with the WHOOP cycles path, untested for localized exports. V0 plan: `NutritionCsvImportTests.testSemicolonFileWithDecimalComma` | |
| W04-013 | S3 | Reported | The lab CSV reads dotted dates month-first whenever the first number is 12 or less, so one day-first file resolves its dates inconsistently | `LabMarkerCsvImport.swift` `canonicalDay` | Phase 2 workflow `wf_b77f01a5-1aa` (W4-12); P5 confirmed (oracle O5: 05.01.2026 → May, 15.01.2026 → January). V0 plan: `LabMarkerCsvImportTests.testDottedDatesAreDayFirst` | |
| W04-014 | S3 | Reported | A WHOOP cycle with no wake onset whose end (the next sleep onset) falls after local midnight keys to the same day as the next cycle, and the later upsert replaces the earlier row | `WhoopDayKeying.swift` `wakeDayKey`; `WhoopImporter.swift` | Phase 2 workflow `wf_b77f01a5-1aa` (W4-13); P5 uncertain: the code path is proven (oracle O1), the input is not; needs a real WHOOP export with a blank-wake cycle (none in the repo root). V0 plan: `WhoopDayKeyingTests` collision fixture | |
| W04-015 | S3 | Reported | The Apple Health importer de-duplicates every numeric record but not `SleepAnalysis` intervals, so an export carrying the same sleep record twice doubles that night's minutes | `AppleHealthImporter.swift` `handleRecord` (sleep branch) | Phase 2 workflow `wf_b77f01a5-1aa` (P5 missed finding). V0 plan: `AppleHealthImporterTests.testDuplicateSleepRecordCountedOnce` (expect 480, gets 960) | |
| W04-016 | S3 | Reported | Apple Health energy records ignore their unit, so an export in kilojoules is summed as kilocalories (×4.184), while the same importer converts pounds | `AppleHealthAggregator.swift` energy accumulators; `AppleHealthImporter.swift` workout energy | Phase 2 workflow `wf_b77f01a5-1aa` (P5 missed finding), medium confidence: the kJ unit spelling is unverified without a real kJ export. V0 plan: `AppleHealthImporterTests.testKilojouleEnergyConvertedToKcal` | |
| W04-017 | S3 | Reported | Re-importing the same Hevy CSV after a time-zone change duplicates every lifting session: the zoneless start is resolved in the device's current zone and `startTs` is part of the workout key | `LiftingImporter.swift` `parse(data:zone:)`, `parseDate`; `DataSourcesView` upsert | Phase 2 workflow `wf_b77f01a5-1aa` (P5 missed finding). V0 plan: `LiftingImporterTests.testHevyStartIsStableAcrossZones` (characterise, then pin the chosen fix) | |
| W04-018 | S4 | Reported | The FIT parser's header says compressed-timestamp records honour their 5-bit offset, but the code never reads it: those records carry no time and their heart rate is dropped | `FitParser.swift` header comment and compressed-header branch | Phase 2 workflow `wf_b77f01a5-1aa` (P5 missed finding). V0 plan: `ActivityFileImporterTests.testCompressedTimestampRecordGetsTime` | |

## Log

- 2026-09-25 — File created from the plan.
- 2026-09-27 — The owner's 24-hour raw CSV matches the backup taken at the same moment row for row on every stream (a full multiset compare, 0 mismatches); the one event missing from the CSV arrived after it was written. W04-001 recorded.
- 2026-09-28 — The owner's morning raw CSV (24 h, 11.9.13) matches the backup taken 38 s before it on every stream (full multiset compare, 0 mismatches on the shared window); the CSV's only extra rows are 32 HR and 26 RR rows newer than the backup's newest. W04-001 stands (no `spo2Sample` rows, the byte 82 candidate still not exported).
- 2026-10-03 — Phase 2 started; W4 claimed for the Phase 2 review workflow (passes 1, 2, 3 and 5).
- 2026-10-03 — Passes 1, 2, 3 and 5 done in workflow run `wf_b77f01a5-1aa` (one reviewer, one adversary; oracle twins O1 … O8 over synthetic inputs). W04-002 … W04-018 recorded; P5 refuted none and left W04-014 uncertain (needs a real WHOOP export with a blank-wake cycle). W04-001 still stands. Checks: malformed input, day keying, re-import idempotence, round trip, memory bound and write-back all partial; units and epochs fail (W04-002, W04-007, W04-016, W04-018); XlsxSheet passes. A 14.4 MB FIT parses in 0.19 s release, so the main-thread parse is not a finding. AD-4 note: `WhoopTime.plainFormatter` and `LiftingImporter.hevyFormatter` mutate a shared DateFormatter per call, which complete checking cannot see. Not covered: no real WHOOP CSV or Apple export.xml in the repo root, so Apple's write-back source spelling and kJ unit spelling are unverified. Next: V0, S2s first: W04-002 … W04-005.
- 2026-10-03 — W04-002 fixed on `review/w04-fixes` (off `review/phase-2`).
- 2026-10-03 — W04-004 fixed on `review/w04-fixes`.
