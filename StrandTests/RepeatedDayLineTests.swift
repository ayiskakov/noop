import XCTest
import Foundation
import WhoopProtocol
import WhoopStore
import StrandAnalytics
@testable import Strand

/// W07-005: a re-score reprinted every scored day's diagnostic lines on every pass, although most of them
/// had not changed since the last pass. These pin that a pass prints a day's line only when it changed (or
/// its last print is old enough to have left the exports), and says how many it withheld.
@MainActor
final class RepeatedDayLineTests: XCTestCase {
    private let canonical = "my-whoop"

    private func withPreferences(_ body: () async throws -> Void) async throws {
        let defaults = UserDefaults.standard
        let keys = [
            "profile.dateOfBirth", "profile.age", "profile.sex", "profile.weightKg",
            "profile.heightCm", "profile.waistCm", "profile.hrMaxOverride",
            "noop.analyzeWatermark", "analyzeRecent.stepsMotionCache.v1",
            "noop.hrvBaselineEpoch", "noop.recoveryBaselineEpoch", UnitPrefs.hrvWindowKey,
            RescoreBackgroundScheduler.owedKey, RescoreBackgroundScheduler.owedTokenKey,
            RescoreBackgroundScheduler.lastPassSecondsKey, DayCycleMode.storageKey,
            PuffinExperiment.experimentalSleepV2Key, PuffinExperiment.sleepStagerKey,
            PuffinExperiment.motionAwareWakeKey,
        ]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        for key in keys { defaults.removeObject(forKey: key) }
        defaults.set(DayCycleMode.midnight.rawValue, forKey: DayCycleMode.storageKey)
        defaults.set(SleepStagerVersion.v2.rawValue, forKey: PuffinExperiment.sleepStagerKey)
        defaults.set(false, forKey: PuffinExperiment.motionAwareWakeKey)
        try await body()
    }

    /// Synthetic HR and R-R for the day before today, with a sleep block in its last hours.
    private func night() -> (hr: [HRSample], rr: [RRInterval]) {
        let start = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970) - 86_400
        var hr: [HRSample] = []
        var rr: [RRInterval] = []
        for i in 0..<(24 * 3_600) {
            let asleep = i >= 16 * 3_600
            let phase = asleep ? i - 16 * 3_600 : i
            let bpm = asleep ? 64 + Int(sin(Double(phase) / 900) * 5)
                             : 74 + Int(sin(Double(phase) / 500) * 11)
            let ts = start - 16 * 3_600 + i
            hr.append(HRSample(ts: ts, bpm: bpm))
            rr.append(RRInterval(ts: ts, rrMs: 900 + (i.isMultiple(of: 2) ? 16 : -16)))
        }
        return (hr, rr)
    }

    /// The untagged per-day lines a pass printed (the shapes the owner's 2026-09-27 log repeated).
    private func dayLines(_ log: [(String, TestDomain?)]) -> [String] {
        log.filter { $0.1 == nil && $0.0.range(of: #"day=\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil }
            .map(\.0)
    }

    func testAnUnchangedPassWithholdsItsDayLinesAndCountsThem() async throws {
        try await withPreferences {
            let store = try await WhoopStore.inMemory()
            let input = night()
            _ = try await store.insert(Streams(hr: input.hr, rr: input.rr), deviceId: canonical)
            let repo = Repository(deviceId: canonical)
            repo.setStoreForTesting(store)
            let engine = IntelligenceEngine(repo: repo, profile: ProfileStore(), deviceId: canonical)
            var log: [(String, TestDomain?)] = []
            engine.diagnosticSink = { log.append(($0, $1)) }

            await engine.analyzeRecent(maxDays: 2, force: true)
            let first = dayLines(log)
            XCTAssertTrue(first.contains { $0.hasPrefix("sleep day=") }, "the fixture must score a night: \(first)")
            XCTAssertTrue(first.contains { $0.hasPrefix("hrv day=") }, "\(first)")

            log.removeAll()
            await engine.analyzeRecent(maxDays: 2, force: true)
            let second = dayLines(log)
            XCTAssertEqual(second, [], "an unchanged pass must not reprint a day's lines")
            let summaries = log.map(\.0).filter { $0.hasPrefix("re-score: ") && $0.contains("unchanged") }
            XCTAssertEqual(summaries.count, 1, "\(log.map(\.0))")
            XCTAssertTrue(summaries.first?.contains("re-score: \(first.count) per-day line(s) unchanged") == true,
                          "the summary must count every withheld line: \(summaries)")
        }
    }

    func testADayWhoseInputsChangedPrintsAgain() async throws {
        try await withPreferences {
            let store = try await WhoopStore.inMemory()
            let input = night()
            _ = try await store.insert(Streams(hr: input.hr, rr: input.rr), deviceId: canonical)
            let repo = Repository(deviceId: canonical)
            repo.setStoreForTesting(store)
            let engine = IntelligenceEngine(repo: repo, profile: ProfileStore(), deviceId: canonical)
            var log: [(String, TestDomain?)] = []
            engine.diagnosticSink = { log.append(($0, $1)) }

            await engine.analyzeRecent(maxDays: 2, force: true)
            // An hour of new HR at noon on the fixture's own day, which is always in the past (a range ending
            // at `now` would be empty, or inverted, just after midnight). That day's effort line counts its
            // HR samples, so it must change.
            let start = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970) - 86_400
            let yesterday = Repository.localDayKey(Date(timeIntervalSince1970: Double(start)))
            let more = (start + 12 * 3_600 ..< start + 13 * 3_600).map { HRSample(ts: $0, bpm: 80) }
            _ = try await store.insert(Streams(hr: more), deviceId: canonical)

            log.removeAll()
            await engine.analyzeRecent(maxDays: 2, force: true)
            let second = dayLines(log)
            XCTAssertTrue(second.contains { $0.hasPrefix("effort score day=\(yesterday) ") },
                          "a day whose line changed must print it: \(second)")
            let today = Repository.localDayKey(Date())
            XCTAssertFalse(second.contains { $0.hasPrefix("hrv day=\(today) ") || $0.hasPrefix("sleep day=\(today) ") },
                           "today's lines, which the new HR does not move, stay withheld: \(second)")
            XCTAssertTrue(log.contains { $0.0.hasPrefix("re-score: ") && $0.0.contains("unchanged since their last print") },
                          "\(log.map(\.0))")
        }
    }

    // MARK: - The filter on its own

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    /// One pass over `lines` at `now`: the lines it prints, and its summary.
    private func pass(_ filter: inout RepeatedDayLineFilter, _ lines: [String], at now: Date) -> ([String], String?) {
        filter.beginPass(now: now)
        return (lines.filter { filter.admit($0, now: now) }, filter.summaryLine())
    }

    /// Every per-day shape the engine routes through the filter, with synthetic values.
    private let shapes = [
        "rhr day=2026-01-02 floor=50 nightMean=60 inBedSamples=100 (floor = WHOOP-style lowest-sustained)",
        "rhr bins day=2026-01-02 bins=10 thin=0 implausible=0",
        "resp day=2026-01-02 rpm=14.0",
        "sleep day=2026-01-02 totalSleepMin=400 stages=60+90+250=400 eff=0.90 matched=1 source=computed",
        "sleep divergence day=2026-01-02 totalSleepMin=400 matched=0 editFold=1",
        "hrv day=2026-01-02 window=whole avgHrv=40.0",
        "hrv diag day=2026-01-02 rmssd=40ms sdnn=90ms",
        "hrv rrsample day=2026-01-02 900,910",
        "effort score day=2026-01-02 hr=1000 enough=true",
        "sleep-detect day=2026-01-02 NO-NIGHT hr=10 rr=0 resp=0",
        "workout detect day=2026-01-02 hr=1000 kept=0",
        "effort bout day=2026-01-02 durMin=30 effort=10.0",
        "effort bout day=2026-01-02 durMin=45 effort=12.0",
    ]

    func testEveryShapeKeysOnItsTextThroughTheDay() {
        XCTAssertEqual(shapes.map { RepeatedDayLineFilter.dayKey(of: $0) }, [
            "rhr day=2026-01-02", "rhr bins day=2026-01-02", "resp day=2026-01-02", "sleep day=2026-01-02",
            "sleep divergence day=2026-01-02", "hrv day=2026-01-02", "hrv diag day=2026-01-02",
            "hrv rrsample day=2026-01-02", "effort score day=2026-01-02", "sleep-detect day=2026-01-02",
            "workout detect day=2026-01-02", "effort bout day=2026-01-02", "effort bout day=2026-01-02",
        ])
        XCTAssertNil(RepeatedDayLineFilter.dayKey(of: "sleep SKIPPED 3 day(s) — need ≥200 hrSamples"))
        XCTAssertNil(RepeatedDayLineFilter.dayKey(of: "stepsEst day=2026-1-2"))
    }

    func testASecondIdenticalPassPrintsNothingAndCountsEveryLine() {
        var filter = RepeatedDayLineFilter()
        let first = pass(&filter, shapes, at: t0)
        XCTAssertEqual(first.0, shapes)
        XCTAssertNil(first.1, "a pass that withheld nothing prints no summary")
        let second = pass(&filter, shapes, at: t0 + 600)
        XCTAssertEqual(second.0, [])
        let stamp = RepeatedDayLineFilter.timeFormatter.string(from: t0)
        XCTAssertEqual(second.1, "re-score: 13 per-day line(s) unchanged since their last print, not repeated "
                                 + "(oldest print \(stamp))")
    }

    func testAChangedValuePrintsOnlyThatLine() {
        var filter = RepeatedDayLineFilter()
        _ = pass(&filter, shapes, at: t0)
        var changed = shapes
        changed[5] = "hrv day=2026-01-02 window=whole avgHrv=41.0"
        let second = pass(&filter, changed, at: t0 + 600)
        XCTAssertEqual(second.0, ["hrv day=2026-01-02 window=whole avgHrv=41.0"])
        XCTAssertTrue(second.1?.hasPrefix("re-score: 12 per-day line(s)") == true, "\(String(describing: second.1))")
    }

    func testTwoLinesOnOneKeyCompareByTheirPlaceInThePass() {
        var filter = RepeatedDayLineFilter()
        let bouts = Array(shapes.suffix(2))
        _ = pass(&filter, bouts, at: t0)
        // The first bout is gone: the surviving one is now the day's first `effort bout` and differs from it.
        XCTAssertEqual(pass(&filter, [bouts[1]], at: t0 + 600).0, [bouts[1]])
        // The same day on another date is another key.
        let otherDay = "effort bout day=2026-01-03 durMin=30 effort=10.0"
        XCTAssertEqual(pass(&filter, [bouts[1], otherDay], at: t0 + 1_200).0, [otherDay])
    }

    func testAnUnchangedLinePrintsAgainOnceItsLastPrintIsAnHourOld() {
        var filter = RepeatedDayLineFilter()
        _ = pass(&filter, shapes, at: t0)
        XCTAssertEqual(pass(&filter, shapes, at: t0 + RepeatedDayLineFilter.refreshAfter - 1).0, [])
        let refreshed = pass(&filter, shapes, at: t0 + RepeatedDayLineFilter.refreshAfter)
        XCTAssertEqual(refreshed.0, shapes)
        XCTAssertNil(refreshed.1)
        // The refresh restarts the clock: the next pass withholds against the reprint, not the first print.
        let after = pass(&filter, shapes, at: t0 + RepeatedDayLineFilter.refreshAfter + 600)
        XCTAssertEqual(after.0, [])
        let stamp = RepeatedDayLineFilter.timeFormatter.string(from: t0 + RepeatedDayLineFilter.refreshAfter)
        XCTAssertTrue(after.1?.hasSuffix("(oldest print \(stamp))") == true, "\(String(describing: after.1))")
    }

    func testALineWhoseHourEndsDuringAPassPrints() {
        var filter = RepeatedDayLineFilter()
        _ = pass(&filter, [shapes[0]], at: t0)
        filter.beginPass(now: t0 + RepeatedDayLineFilter.refreshAfter - 30)
        XCTAssertTrue(filter.admit(shapes[0], now: t0 + RepeatedDayLineFilter.refreshAfter))
        XCTAssertNil(filter.summaryLine())
    }

    func testTheSummaryNamesTheOldestPrintItReliesOn() {
        var filter = RepeatedDayLineFilter()
        _ = pass(&filter, [shapes[0]], at: t0)
        _ = pass(&filter, [shapes[0], shapes[2]], at: t0 + 600)
        let third = pass(&filter, [shapes[0], shapes[2]], at: t0 + 1_200)
        let stamp = RepeatedDayLineFilter.timeFormatter.string(from: t0)
        XCTAssertEqual(third.1, "re-score: 2 per-day line(s) unchanged since their last print, not repeated "
                                + "(oldest print \(stamp))")
    }

    func testALineWithNoDayAlwaysPrints() {
        var filter = RepeatedDayLineFilter()
        let line = "analyzeRecent cost prep=0ms score=0ms"
        _ = pass(&filter, [line], at: t0)
        let second = pass(&filter, [line], at: t0 + 600)
        XCTAssertEqual(second.0, [line])
        XCTAssertNil(second.1)
    }
}
