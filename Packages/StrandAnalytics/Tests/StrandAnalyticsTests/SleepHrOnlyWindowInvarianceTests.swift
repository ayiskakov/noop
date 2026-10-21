import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// W03-043: a night found from heart rate alone (a strap that banks no motion, #1801) must depend only on
/// the heart rate around it, not on how far the read reaches.
///
/// The HR-only spine held every epoch to one anchor, the tenth percentile of the whole read. Since W03-024
/// the engine reads each day over 66 h, three nights' worth, so the next night's heart rate, 16 h after the
/// night being scored, moved the band that night was judged against: the gravity path's W03-023, on the
/// path W03-023 did not touch.
///
/// The fixture is the engine's read for the day the night ends on (tz 0): from 30 h before its midnight to
/// 36 h after, heart rate every 30 s, three nights at 23:00 to 07:00 around 56 bpm and the day around 74.
/// Two reads hold the same data except for the third night, which starts 16 h after the scored night ends.
final class SleepHrOnlyWindowInvarianceTests: XCTestCase {
    /// Local midnight (tz 0) the scored night runs across.
    private let midnight = 1_700_006_400

    /// Heart rate every 30 s over [from, to]; `nextNightBpm` is the centre of the night after the scored one.
    private func heartRate(from: Int, to: Int, nextNightBpm: Int) -> [HRSample] {
        var out: [HRSample] = []
        for ts in stride(from: from, through: to, by: 30) {
            let wave = sin(Double(ts) / 500.0)
            let bpm: Int
            switch ts - midnight {
            case (-25 * 3600)..<(-17 * 3600): bpm = 56 + Int(wave * 2)            // the night before
            case (-1 * 3600)..<(7 * 3600): bpm = 56 + Int(wave * 2)               // the scored night
            case (23 * 3600)..<(31 * 3600): bpm = nextNightBpm + Int(wave * 2)    // the next night
            default: bpm = 74 + Int(wave * 11)                                    // awake
            }
            out.append(HRSample(ts: ts, bpm: bpm))
        }
        return out
    }

    /// The sessions the engine keeps for the scored day: those ending on it.
    private func scoredNight(_ hr: [HRSample]) -> [[Int]] {
        SleepStager.hrOnlySessions(hr: hr, rr: [], resp: [])
            .filter { $0.end >= midnight && $0.end < midnight + 86_400 }
            .map { [$0.start, $0.end] }
    }

    func testTheNextNightsHeartRateDoesNotMoveTheScoredNight() {
        let usual = scoredNight(heartRate(from: midnight - 30 * 3600, to: midnight + 36 * 3600, nextNightBpm: 56))
        let lower = scoredNight(heartRate(from: midnight - 30 * 3600, to: midnight + 36 * 3600, nextNightBpm: 46))
        XCTAssertFalse(usual.isEmpty, "the fixture must detect the scored night")
        XCTAssertEqual(lower, usual)
    }

    /// The reach of the read past the night does not move it either: a read ending 12 h after the night
    /// covers every epoch's neighbourhood, so it agrees with the engine's full read.
    func testAReadEndingTwelveHoursAfterTheNightAgreesWithTheFullRead() {
        let full = scoredNight(heartRate(from: midnight - 30 * 3600, to: midnight + 36 * 3600, nextNightBpm: 46))
        let short = scoredNight(heartRate(from: midnight - 30 * 3600, to: midnight + 19 * 3600, nextNightBpm: 46))
        XCTAssertFalse(full.isEmpty, "the fixture must detect the scored night")
        XCTAssertEqual(short, full)
    }

    /// The sliding anchor is `hrOnlyBaseline` of the samples in each time's 24 h window, slid inside the data,
    /// by the brute-force rule, on uneven data with gaps, repeated timestamps and bpm outside the histogram.
    func testLocalAnchorIsTheTenthPercentileOfTheTwentyFourHoursAroundEachTime() {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        var hr: [HRSample] = []
        var ts = 1_000_000
        for _ in 0..<6_000 {
            ts += [0, 1, 30, 60, 600, 7_200][next(6)]
            let bpm: Int
            switch next(100) {
            case 0: bpm = -3
            case 1: bpm = 700
            case 2: bpm = 65_000
            default: bpm = 40 + next(80)
            }
            hr.append(HRSample(ts: ts, bpm: bpm))
        }
        let times = Array(stride(from: hr[0].ts - 13 * 3600, through: ts + 13 * 3600, by: 1_777))
        let anchors = SleepStager.hrOnlyLocalAnchors(hr, at: times)
        let r = SleepStager.localBaselineRadiusS
        let first = hr[0].ts, last = ts
        XCTAssertGreaterThan(last - first, 4 * 2 * r, "the data must span several windows")
        for (t, anchor) in zip(times, anchors) {
            let start = min(max(t - r, first), last - 2 * r)
            let window = hr.filter { $0.ts >= start && $0.ts <= start + 2 * r }
            XCTAssertEqual(window.last!.ts - window.first!.ts <= 2 * r, true)
            XCTAssertEqual(anchor, SleepStager.hrOnlyBaseline(window), "t=\(t)")
        }
    }

    /// Near either end of the data the window slides inward and stays 24 h long; data shorter than 24 h is
    /// one window.
    func testTheWindowSlidesInsideTheDataAtEitherEnd() {
        let r = SleepStager.localBaselineRadiusS
        // 48 h of one sample an hour: bpm 100 for the first 24 h, then 50.
        let hr = (0..<48).map { HRSample(ts: $0 * 3600, bpm: $0 < 24 ? 100 : 50) }
        let anchors = SleepStager.hrOnlyLocalAnchors(hr, at: [0, 6 * 3600, 47 * 3600, 60 * 3600])
        // At 0 and 6 h the window is [0, 24 h]: 24 samples of 100 and one of 50, so p10 is 100.
        XCTAssertEqual(anchors[0], 100)
        XCTAssertEqual(anchors[1], 100)
        // At 47 h and past the end the window is [23 h, 47 h]: one 100 and 24 of 50.
        XCTAssertEqual(anchors[2], 50)
        XCTAssertEqual(anchors[3], 50)
        XCTAssertEqual(2 * r, 24 * 3600)
        let short = Array(hr.prefix(10))
        XCTAssertEqual(SleepStager.hrOnlyLocalAnchors(short, at: [0, 9 * 3600]),
                       [SleepStager.hrOnlyBaseline(short), SleepStager.hrOnlyBaseline(short)])
        XCTAssertEqual(SleepStager.hrOnlyLocalAnchors([], at: [0]), [nil])
    }
}
