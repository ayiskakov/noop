import XCTest
@testable import StrandAnalytics

/// The Sleep Regularity Index measures TIMING. The exact values on synthetic schedules are pinned by
/// `HealthspanOracleTests`; these name the properties.
final class SleepRegularityTests: XCTestCase {

    private let tz = 0

    /// A night on local day `day` starting at `bedHour` (24 = midnight, 27 = 03:00 next morning).
    private func night(_ day: Int, _ bedHour: Double, _ hours: Double = 8) -> SleepRegularity.Session {
        let start = Double(day * 86_400) + bedHour * 3600
        return SleepRegularity.Session(start: start, end: start + hours * 3600)
    }

    func testIdenticalTimingIsOneHundred() {
        let sessions = (0..<10).map { night(20_000 + $0, 23) }
        XCTAssertEqual(SleepRegularity.index(sessions: sessions, tzOffsetSec: tz)!, 100, accuracy: 1e-9)
    }

    /// Equal durations at different times are NOT regular — the reason the 1 − CV proxy was replaced.
    func testSameDurationDifferentTimingIsIrregular() {
        let sessions = (0..<10).map { night(20_000 + $0, $0 % 2 == 0 ? 23 : 27) }
        let sri = SleepRegularity.index(sessions: sessions, tzOffsetSec: tz)!
        XCTAssertEqual(sri, 200 * (16.0 / 24) - 100, accuracy: 1e-9)
        XCTAssertEqual(VitalityEngine.sleepConsistency(nightlyHours: Array(repeating: 8, count: 10))!, 1)
    }

    /// An unworn night drops out rather than reading as the most irregular night of the month.
    func testUnwornNightsAreExcluded() {
        let sessions = (0..<12).filter { $0 != 5 }.map { night(20_000 + $0, 23) }
        let agreement = SleepRegularity.dailyAgreement(sessions: sessions, tzOffsetSec: tz)
        XCTAssertEqual(agreement.count, 9, "the two pairs touching the unworn night are skipped")
        XCTAssertEqual(SleepRegularity.index(sessions: sessions, tzOffsetSec: tz)!, 100, accuracy: 1e-9)
    }

    /// Wake inside a session is wake, not sleep.
    func testWakeBoutsCount() {
        let sessions = (0..<10).map { i -> SleepRegularity.Session in
            let n = night(20_000 + i, 23)
            return i % 2 == 0
                ? SleepRegularity.Session(start: n.span.start, end: n.span.end,
                                          wake: [.init(start: n.span.start + 3600, end: n.span.start + 7200)])
                : n
        }
        XCTAssertEqual(SleepRegularity.index(sessions: sessions, tzOffsetSec: tz)!,
                       200 * (23.0 / 24) - 100, accuracy: 1e-9)
    }

    /// The index over a window is the mean of that window's pairs, so a pipeline can compute agreement
    /// once and re-window it freely.
    func testWindowingAgreement() {
        let sessions = (0..<20).map { night(20_000 + $0, $0 < 10 ? 23 : 27) }
        let a = SleepRegularity.dailyAgreement(sessions: sessions, tzOffsetSec: tz)
        XCTAssertEqual(SleepRegularity.index(agreement: a, fromDay: 20_000, toDay: 20_008)!, 100, accuracy: 1e-9)
        XCTAssertEqual(SleepRegularity.index(agreement: a, fromDay: 20_010, toDay: 20_018)!, 100, accuracy: 1e-9)
        XCTAssertLessThan(SleepRegularity.index(agreement: a, fromDay: 20_000, toDay: 20_018)!, 100)
        XCTAssertNil(SleepRegularity.index(agreement: a, fromDay: 20_000, toDay: 20_003), "4 pairs < minPairs")
    }

    /// The local offset moves the noon boundary with the person, not with UTC.
    func testTimeZoneShiftsTheDayBoundary() {
        let offset = 5 * 3600
        let sessions = (0..<8).map { i -> SleepRegularity.Session in
            let s = Double((20_000 + i) * 86_400) + 23 * 3600 - Double(offset)   // 23:00 local
            return SleepRegularity.Session(start: s, end: s + 8 * 3600)
        }
        XCTAssertEqual(SleepRegularity.index(sessions: sessions, tzOffsetSec: offset)!, 100, accuracy: 1e-9)
        XCTAssertEqual(SleepRegularity.dailyAgreement(sessions: sessions, tzOffsetSec: offset).keys.min(), 20_000)
    }

    func testEmpty() {
        XCTAssertNil(SleepRegularity.index(sessions: [], tzOffsetSec: tz))
        XCTAssertTrue(SleepRegularity.dailyAgreement(sessions: [], tzOffsetSec: tz).isEmpty)
    }
}
