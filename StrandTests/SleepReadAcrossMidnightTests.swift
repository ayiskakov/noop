import XCTest
import StrandAnalytics
import WhoopProtocol
@testable import Strand

/// W03-024: two day passes must not bank one night twice.
///
/// Each past day's sleep read used to stop at its next local midnight. A night that began with an evening
/// fragment, a short stir, then sleep running across midnight was seen whole by the next day's read, which
/// bridged the stir, but not by the earlier day's, which kept the fragment as its own session ending before
/// midnight. Both reached the store with the same start and different ends, and the earlier day scored the
/// fragment as its sleep.
final class SleepReadAcrossMidnightTests: XCTestCase {
    /// Local midnight (tz 0) the night runs across: the start of day D.
    private let midnight = 1_700_006_400

    private func streams(from: Int, to: Int) -> (grav: [GravitySample], hr: [HRSample]) {
        let m = midnight
        var grav: [GravitySample] = [], hr: [HRSample] = []
        var flip = false
        for ts in stride(from: from, through: to, by: 30) {
            let fragment = ts >= m - 3 * 3600 && ts < m - 110 * 60          // 70 minutes asleep
            let stir = ts >= m - 110 * 60 && ts < m - 90 * 60               // 20 minutes up
            let night = ts >= m - 90 * 60 && ts < m + 7 * 3600              // asleep across midnight
            let gravityGap = ts >= m + 3600 && ts < m + 3600 + 25 * 60      // 25 minutes banked no motion
            if fragment || night {
                if !gravityGap { grav.append(GravitySample(ts: ts, x: 0, y: 0, z: 1)) }
                hr.append(HRSample(ts: ts, bpm: 52))
            } else {
                flip.toggle()
                grav.append(GravitySample(ts: ts, x: flip ? 0.3 : -0.3, y: 0.1, z: 0.9))
                hr.append(HRSample(ts: ts, bpm: stir ? 58 : 80))
            }
        }
        return (grav, hr)
    }

    /// The sessions a day pass banks for `dayStart`: detected over the engine's read, kept when they end
    /// on that day.
    private func banked(dayStart: Int, now: Int) -> [SleepSession] {
        let to = IntelligenceEngine.sleepReadWindowEnd(dayStart: dayStart, nowLocalMidnight: midnight + 86_400,
                                                      now: now)
        let s = streams(from: dayStart - StreamReadCap.lookbackSeconds, to: to)
        return SleepStager.detectSleep(hr: s.hr, gravity: s.grav, tzOffsetSeconds: 0, stager: .v1)
            .filter { $0.end >= dayStart && $0.end < dayStart + 86_400 }
    }

    func testTheEarlierDayDoesNotBankTheEveningPartOfANightThatEndsTheNextDay() {
        let now = midnight + 86_400 + 9 * 3600
        let dayD = banked(dayStart: midnight, now: now)
        let dayBefore = banked(dayStart: midnight - 86_400, now: now)
        XCTAssertFalse(dayD.isEmpty, "the fixture must detect the night on day D")
        XCTAssertTrue(Set(dayBefore.map(\.start)).isDisjoint(with: dayD.map(\.start)),
                      "day D-1 banked \(dayBefore.map { ($0.start, $0.end) }) beside day D's \(dayD.map { ($0.start, $0.end) })")
        XCTAssertTrue(dayBefore.isEmpty, "the evening fragment belongs to day D's night")
    }
}
