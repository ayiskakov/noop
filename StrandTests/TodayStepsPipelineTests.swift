import XCTest
@testable import Strand

/// The Steps calibration affordance only reaches a profile whose strap was never identified AND which
/// already owns a working coefficient from an earlier calibration. A positively identified strap reports
/// steps natively and has nothing to calibrate. WHOOP 5.0 motion rows can advance the shared fitter's
/// sample-day counter, so that counter cannot stand in for an actual calibration (#1523).
final class TodayStepsPipelineTests: XCTestCase {

    private func active(model: WhoopModel?,
                        hasDayData: Bool,
                        calibrationCoefficient: Double = 0,
                        manualCoefficient: Double = 0,
                        sampleDays: Int = 0) -> Bool {
        TodayView.stepsPipelineActive(
            selectedModelRaw: model?.rawValue ?? "",
            hasDayData: hasDayData,
            calibrationCoefficient: calibrationCoefficient,
            manualCoefficient: manualCoefficient,
            calibrationSampleDays: sampleDays)
    }

    func testWhoop5PartialSampleDaysDoNotActivateFourPointZeroPipeline() {
        XCTAssertFalse(active(model: .whoop5mg, hasDayData: true, sampleDays: 3))
    }

    /// An identified strap never sees the prompt, whatever calibration state the profile carries.
    func testIdentifiedStrapNeverPromptsEvenWithDayData() {
        XCTAssertFalse(active(model: .whoop5mg, hasDayData: true))
    }

    /// #1523 follow-up: these two asserted TRUE when the suite landed, on the grounds that a profile
    /// migrating from a calibrated older strap should keep its estimate behaviour. That reasoning does
    /// not apply to THIS gate — `estSteps` is computed independently in `stepsEstByDay`, and all this
    /// decides is whether a blank tile offers to calibrate. A 5/MG reports steps natively, so it has
    /// nothing to calibrate, and showing it the prompt is the complaint #1523 opened.
    func testFittedCoefficientDoesNotPromptOnAFivePointZero() {
        XCTAssertFalse(active(model: .whoop5mg,
                              hasDayData: true,
                              calibrationCoefficient: 0.42,
                              sampleDays: 5))
    }

    func testManualCoefficientDoesNotPromptOnAFivePointZero() {
        XCTAssertFalse(active(model: .whoop5mg,
                              hasDayData: true,
                              manualCoefficient: 0.35,
                              sampleDays: 1))
    }

    /// …but the coefficient paths must NOT simply be deleted, which is the tempting reading of the two
    /// above. A legacy owner whose `selectedWhoopModel` key was never written has no model to match on,
    /// and only the coefficient says they are mid-estimate. Dropping these would silently take the
    /// calibration gear away from exactly the users #1491 restored it for.
    func testACoefficientStillActivatesWhenNoModelWasEverRecorded() {
        XCTAssertTrue(active(model: nil, hasDayData: true, calibrationCoefficient: 0.42))
        XCTAssertTrue(active(model: nil, hasDayData: true, manualCoefficient: 0.35))
    }

    func testUnsetModelAndPartialSampleDaysStayInactive() {
        XCTAssertFalse(active(model: nil, hasDayData: true, sampleDays: 3))
    }
}
