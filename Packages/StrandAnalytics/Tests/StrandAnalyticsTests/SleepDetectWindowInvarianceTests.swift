import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// W03-023: a night's bounds must depend only on the data around it, not on how far the read reaches.
///
/// The engine reads each day's night over about 54 h. The sparse-gravity flag, the fragmentation rescue
/// and the HR baseline were each taken over that whole read, so a gravity gap or the heart rate half a day
/// after a night decided whether a pre-sleep fragment was bridged into it. The same night, read once by a
/// window that reached that gap and once by one that did not, came out with two different starts.
///
/// The fixture is a dense night: a still pre-sleep fragment, a 20-minute stir, then the night. Two reads
/// hold the same data except for one 25-minute gravity gap about 21 hours after the night.
final class SleepDetectWindowInvarianceTests: XCTestCase {
    /// Local midnight (tz 0) the night runs across.
    private let midnight = 1_700_006_400

    private enum Span { case moving(hr: Int), still(hr: Int) }

    /// Gravity and HR every 30 s from `from` to `to`, shaped by `span(at:)`, skipping `gap`.
    private func streams(from: Int, to: Int, gap: Range<Int>?) -> (grav: [GravitySample], hr: [HRSample]) {
        var grav: [GravitySample] = [], hr: [HRSample] = []
        var flip = false
        for ts in stride(from: from, through: to, by: 30) {
            if let gap, gap.contains(ts) { continue }
            switch span(at: ts) {
            case .still(let bpm):
                grav.append(GravitySample(ts: ts, x: 0, y: 0, z: 1))
                hr.append(HRSample(ts: ts, bpm: bpm))
            case .moving(let bpm):
                flip.toggle()
                grav.append(GravitySample(ts: ts, x: flip ? 0.3 : -0.3, y: 0.1, z: 0.9))
                hr.append(HRSample(ts: ts, bpm: bpm))
            }
        }
        return (grav, hr)
    }

    private func span(at ts: Int) -> Span {
        let m = midnight
        if ts >= m - 3 * 3600, ts < m - 3 * 3600 + 50 * 60 { return .still(hr: 52) }   // pre-sleep fragment
        if ts >= m - 3 * 3600 + 50 * 60, ts < m - 3 * 3600 + 70 * 60 { return .moving(hr: 58) } // a stir
        if ts >= m - 3 * 3600 + 70 * 60, ts < m + 7 * 3600 { return .still(hr: 52) }   // the night
        return .moving(hr: 80)
    }

    private func detect(gap: Range<Int>?) -> [SleepSession] {
        let s = streams(from: midnight - 30 * 3600, to: midnight + 24 * 3600, gap: gap)
        return SleepStager.detectSleep(hr: s.hr, gravity: s.grav, tzOffsetSeconds: 0, stager: .v1)
    }

    func testAGravityGapHalfADayAwayDoesNotMoveTheNight() {
        let farGap = (midnight + 21 * 3600)..<(midnight + 21 * 3600 + 25 * 60)
        let withGap = detect(gap: farGap)
        let without = detect(gap: nil)
        XCTAssertFalse(without.isEmpty, "the fixture must detect a night")
        XCTAssertEqual(withGap.map(\.start), without.map(\.start))
        XCTAssertEqual(withGap.map(\.end), without.map(\.end))
    }

    /// The reach of the read past the night does not move it either: a read ending 12 h after the night
    /// covers every decision's neighbourhood, so it agrees with the full read.
    func testAReadEndingTwelveHoursAfterTheNightAgreesWithTheFullRead() {
        let full = detect(gap: (midnight + 21 * 3600)..<(midnight + 21 * 3600 + 25 * 60))
        let s = streams(from: midnight - 30 * 3600, to: midnight + 19 * 3600, gap: nil)
        let short = SleepStager.detectSleep(hr: s.hr, gravity: s.grav, tzOffsetSeconds: 0, stager: .v1)
        XCTAssertEqual(short.map(\.start), full.map(\.start))
        XCTAssertEqual(short.map(\.end), full.map(\.end))
    }

    /// W03-044: the "may be incomplete" verdict stored on a night is about that night's motion, not the read's.
    /// A dense night read with a gravity gap 21 h away must not be stamped as staged on sparse motion.
    func testADenseNightIsNotStampedSparseByAGapFarAway() {
        let gap = (midnight + 21 * 3600)..<(midnight + 21 * 3600 + 25 * 60)
        let s = streams(from: midnight - 30 * 3600, to: midnight + 24 * 3600, gap: gap)
        let day = AnalyticsEngine.dayString(midnight + 3600, offsetSec: 0)
        let res = AnalyticsEngine.analyzeDay(day: day, hr: s.hr, gravity: s.grav, profile: UserProfile(),
                                             tzOffsetSeconds: 0)
        XCTAssertFalse(res.cachedSleep.isEmpty, "the fixture must score a night")
        XCTAssertEqual(res.cachedSleep.map(\.stagingSparse), res.cachedSleep.map { _ in false })
    }

    /// The baseline a run is held to is the median of the 24 h around `t`, as `hrBaseline` computes a
    /// median, and it ignores samples further away.
    func testLocalBaselineIsTheMedianOfTheTwentyFourHoursAroundT() {
        let t = 1_000_000
        let near = [HRSample(ts: t - 100, bpm: 50), HRSample(ts: t, bpm: 60),
                    HRSample(ts: t + 100, bpm: 70), HRSample(ts: t + 200, bpm: 81)]
        let far = [HRSample(ts: t + 13 * 3600, bpm: 200)]
        let ctx = SleepStager.LocalContext(grav: [], hr: near + far)
        XCTAssertEqual(ctx.baseline(at: t), SleepStager.hrBaseline(near))
        XCTAssertEqual(ctx.baseline(at: t), 65)
        XCTAssertNil(SleepStager.LocalContext(grav: [], hr: far).baseline(at: t))
    }

    /// W03-051: a corrupt bpm far outside the physiological range must neither change the median rule nor
    /// size the histogram every call allocates.
    func testAnOutOfRangeBpmIsCountedWithoutSizingTheHistogram() {
        let t = 1_000_000
        let hr = [HRSample(ts: t - 10, bpm: 50), HRSample(ts: t, bpm: 60), HRSample(ts: t + 10, bpm: 65_000)]
        let ctx = SleepStager.LocalContext(grav: [], hr: hr)
        XCTAssertEqual(ctx.baseline(at: t), SleepStager.hrBaseline(hr))
        XCTAssertLessThanOrEqual(ctx.histogramSize, SleepStager.LocalContext.maxHistogramBpm + 1)
    }
}
