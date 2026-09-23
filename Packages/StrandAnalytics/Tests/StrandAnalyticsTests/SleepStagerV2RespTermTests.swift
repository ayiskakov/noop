import XCTest
@testable import StrandAnalytics

/// The RSA respiration-regularity term in `SleepStagerV2` is one-sided and REM-only: regular breathing
/// counts against REM, and irregular breathing is never evidence FOR REM (nor does regularity add deep).
final class SleepStagerV2RespTermTests: XCTestCase {

    /// An 8 h night of epochs with a slow HR / HR-variability wave so every stage is in play, and a
    /// breathing-regularity value that alternates between irregular and regular every 20 epochs.
    private func night(respReg: (Int) -> Double?) -> [SleepStagerV2.Epoch] {
        let n = 960
        return (0..<n).map { i in
            let phase = sin(2.0 * Double.pi * Double(i) / 180.0)
            return SleepStagerV2.Epoch(
                start: 1_700_000_000 + i * 30,
                hr: 56 + 4 * phase, hrVar: 2.0 + 1.2 * phase, hrFlat11: 1.5 + 1.0 * phase,
                moveFrac: 0, jerkMax: 0.001, respReg: respReg(i),
                clock: Double(i) / Double(n), jerkScale: 0.001,
                minutesSinceOnset: Double(i) / 2.0)
        }
    }

    private func count(_ labels: [String], _ stage: String) -> Int { labels.filter { $0 == stage }.count }

    func testIrregularBreathingNeverAddsRemAndRegularNeverAddsDeep() {
        let without = SleepStagerV2.stageEpochs(night { _ in nil })
        let with = SleepStagerV2.stageEpochs(night { ($0 / 20) % 2 == 0 ? 0.15 : 0.60 })
        XCTAssertLessThanOrEqual(count(with, "rem"), count(without, "rem"),
                                 "the term may only take REM away")
        XCTAssertLessThanOrEqual(count(with, "deep"), count(without, "deep"),
                                 "regular breathing is not deep evidence; the HR-flatness gate owns deep")
    }

    func testAllIrregularNightStagesLikeNoRespiration() {
        // Every epoch equally irregular → z = 0 everywhere → the one-sided term is inert.
        XCTAssertEqual(SleepStagerV2.stageEpochs(night { _ in 0.25 }),
                       SleepStagerV2.stageEpochs(night { _ in nil }))
    }
}
