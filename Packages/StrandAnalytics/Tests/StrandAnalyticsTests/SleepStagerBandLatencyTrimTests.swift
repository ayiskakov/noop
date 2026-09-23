import XCTest
@testable import StrandAnalytics

/// Band sleep_state latency trim: the lying-still-awake lead-in and tail outside the strap's own
/// persistent "asleep" run are relabelled wake; the interior hypnogram is never touched.
final class SleepStagerBandLatencyTrimTests: XCTestCase {

    /// 1 Hz band samples, one state per 30 s epoch starting at `start`.
    private func band(start: Int, _ perEpoch: [Int]) -> [(ts: Int, state: Int)] {
        perEpoch.enumerated().flatMap { i, s in (0..<30).map { (ts: start + i * 30 + $0, state: s) } }
    }

    /// 120 epochs: still(1) × 40, asleep(2) × 60, up(3) × 20.
    private func bandStillAsleepUp() -> [Int] {
        [Int](repeating: 1, count: 40) + [Int](repeating: 2, count: 60) + [Int](repeating: 3, count: 20)
    }

    func testTrimsLeadInAndTailOutsideBandAsleepRunWithGrace() {
        let stages = [StageSegment(start: 0, end: 3600, stage: "light")]
        let out = SleepStager.applyBandStateLatencyTrim(stages, start: 0, end: 3600,
                                                        bandSleepState: band(start: 0, bandStillAsleepUp()),
                                                        enabled: true)
        // Band onset epoch 40 − 10 grace → 30 (900 s); final epoch 99 + 10 grace → 109 (ends 3300 s).
        XCTAssertEqual(out, [
            StageSegment(start: 0, end: 900, stage: "wake"),
            StageSegment(start: 900, end: 3300, stage: "light"),
            StageSegment(start: 3300, end: 3600, stage: "wake"),
        ])
    }

    func testBriefBandFlickerDoesNotAnchorOnset() {
        var states = bandStillAsleepUp()
        for i in 5..<10 { states[i] = 2 }   // 2.5 min flicker, shorter than the 5 min persistence
        let stages = [StageSegment(start: 0, end: 3600, stage: "deep")]
        let out = SleepStager.applyBandStateLatencyTrim(stages, start: 0, end: 3600,
                                                        bandSleepState: band(start: 0, states), enabled: true)
        XCTAssertEqual(out.first, StageSegment(start: 0, end: 900, stage: "wake"))
    }

    func testInteriorIsNeverTouchedAndWakeNeverBecomesSleep() {
        // Interior wake block + an interior band excursion to wake(0): both stay exactly as staged.
        var states = bandStillAsleepUp()
        for i in 60..<70 { states[i] = 0 }
        let stages = [
            StageSegment(start: 0, end: 1800, stage: "rem"),
            StageSegment(start: 1800, end: 2100, stage: "wake"),
            StageSegment(start: 2100, end: 3600, stage: "deep"),
        ]
        let out = SleepStager.applyBandStateLatencyTrim(stages, start: 0, end: 3600,
                                                        bandSleepState: band(start: 0, states), enabled: true)
        XCTAssertEqual(out, [
            StageSegment(start: 0, end: 900, stage: "wake"),
            StageSegment(start: 900, end: 1800, stage: "rem"),
            StageSegment(start: 1800, end: 2100, stage: "wake"),
            StageSegment(start: 2100, end: 3300, stage: "deep"),
            StageSegment(start: 3300, end: 3600, stage: "wake"),
        ])
        let asleepBefore = stages.filter { $0.stage != "wake" }.reduce(0) { $0 + $1.end - $1.start }
        let asleepAfter = out.filter { $0.stage != "wake" }.reduce(0) { $0 + $1.end - $1.start }
        XCTAssertLessThanOrEqual(asleepAfter, asleepBefore, "the trim only ever removes sleep")
    }

    func testNoOpWithoutUsableBand() {
        let stages = [StageSegment(start: 0, end: 3600, stage: "light")]
        // Absent band (WHOOP 4.0).
        XCTAssertEqual(SleepStager.applyBandStateLatencyTrim(stages, start: 0, end: 3600, bandSleepState: [],
                                                             enabled: true), stages)
        // Sparse band: one sample a minute is below the 0.5/s coverage floor.
        let sparse = band(start: 0, bandStillAsleepUp()).filter { $0.ts % 60 == 0 }
        XCTAssertEqual(SleepStager.applyBandStateLatencyTrim(stages, start: 0, end: 3600, bandSleepState: sparse,
                                                             enabled: true), stages)
        // Band never holds a persistent asleep run → no anchor, nothing invented.
        XCTAssertEqual(SleepStager.applyBandStateLatencyTrim(
            stages, start: 0, end: 3600,
            bandSleepState: band(start: 0, [Int](repeating: 1, count: 120)), enabled: true), stages)
        // Flag off.
        XCTAssertEqual(SleepStager.applyBandStateLatencyTrim(
            stages, start: 0, end: 3600, bandSleepState: band(start: 0, bandStillAsleepUp()),
            enabled: false), stages)
    }

    func testAsleepAcrossWholeSessionIsByteIdentical() {
        let stages = [StageSegment(start: 0, end: 1000, stage: "wake"),
                      StageSegment(start: 1000, end: 3600, stage: "light")]
        XCTAssertEqual(SleepStager.applyBandStateLatencyTrim(
            stages, start: 0, end: 3600, bandSleepState: band(start: 0, [Int](repeating: 2, count: 120)),
            enabled: true), stages)
    }

    func testShipsDefaultOn() {
        XCTAssertTrue(SleepStager.bandStateLatencyTrimEnabled,
                      "the trim only adds wake at the edges, toward the PSG truth set's wake%")
    }
}
