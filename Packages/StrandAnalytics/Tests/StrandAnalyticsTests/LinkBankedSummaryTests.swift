import XCTest
@testable import StrandAnalytics

/// #1635: the per-link banked line, split by PATH. Byte-identical twin of the Kotlin
/// `LinkBankedSummaryTest`, including the exact sentences.
///
/// The split is by path rather than by stream because the realtime decoder yields only
/// hr/rr/events/battery — gravity, respiratory, skin temperature, SpO2 and steps arrive solely through
/// the offload. An earlier live-only version named those five as empty on EVERY link, bonded or not.
final class LinkBankedSummaryTests: XCTestCase {

    private func line(liveHr: Int = 0, liveRr: Int = 0, chunks: Int = 0, oHr: Int = 0, oRr: Int = 0,
                      oGrav: Int = 0, oResp: Int? = 0, oSkin: Int = 0, oSpo2: Int? = 0,
                      oSteps: Int? = 0, oAux: Int? = nil) -> String {
        ConnectionReadout.linkBankedSummary(
            liveHr: liveHr, liveRr: liveRr, offloadChunks: chunks,
            offloadHr: oHr, offloadRr: oRr, offloadGravity: oGrav,
            offloadResp: oResp, offloadSkinTemp: oSkin, offloadSpo2: oSpo2, offloadSteps: oSteps,
            offloadV18Aux: oAux)
    }

    func testAnUnbondedStrapReadsLiveTrafficWithAnOffloadThatNeverRan() {
        XCTAssertEqual(
            line(liveHr: 12, liveRr: 7, chunks: 0),
            "banked this link: live hr=12 rr=7 | offload none")
    }

    func testAHealthySyncReadsCompletelyDifferently() {
        let healthy = line(liveHr: 3, liveRr: 2, chunks: 9, oHr: 1200, oRr: 2400, oGrav: 8000,
                           oResp: 8000, oSkin: 8000, oSpo2: 8000, oSteps: 40)
        XCTAssertEqual(healthy,
            "banked this link: live hr=3 rr=2 | offload hr=1200 rr=2400 gravity=8000 resp=8000"
                + " skinTemp=8000 spo2=8000 steps=40")
        XCTAssertFalse(healthy.contains("nothing banked"))
    }

    func testAPartialOffloadNamesOnlyTheStreamsThatStayedEmpty() {
        let l = line(liveHr: 1, chunks: 4, oHr: 500, oRr: 900, oGrav: 0, oResp: 0, oSkin: 700, oSpo2: 700)
        XCTAssertTrue(l.contains("nothing banked from the offload for: gravity, resp, steps"))
    }

    func testAStreamThisPlatformCannotMeasureIsOmittedNotZero() {
        XCTAssertFalse(line(liveHr: 5, chunks: 1, oHr: 10, oSteps: nil).contains("steps"))
    }

    func testBatteryNeverAppearsOnEitherPath() {
        XCTAssertFalse(line(liveHr: 9, chunks: 1, oHr: 9).contains("battery"))
    }

    func testNegativeCountsCannotLeakIntoADiagnostic() {
        let l = line(liveHr: -5, liveRr: 1, chunks: 2, oHr: -3, oGrav: 4)
        XCTAssertTrue(l.contains("live hr=0 rr=1"))
        XCTAssertFalse(l.contains("-3"))
    }

    /// Twin of the Kotlin case: "never ran" and "ran with nothing new" are different findings.
    func testAnOffloadThatRanWithNothingNewIsADifferentFinding() {
        XCTAssertEqual(line(liveHr: 1, liveRr: 1, chunks: 6),
                       "banked this link: live hr=1 rr=1 | offload ran 6 chunk(s), no new rows")
        XCTAssertTrue(line(liveHr: 1, liveRr: 1, chunks: 0).contains("offload none"))
    }

    // MARK: - #103: the channels a family cannot fill

    /// The bug this line had for every WHOOP 5/MG: `resp` and `spo2` count 4.0-only tables (the v18
    /// layout emits no `resp_rate_raw`, and the red/IR ADC pair is a v24 field), so passing 0 made EVERY
    /// 5/MG link accuse the offload of banking nothing for two channels it is structurally incapable of
    /// banking — while that same offload wrote hundreds of thousands of v18 aux rows. The line now omits
    /// what it cannot measure, exactly as it already did for steps.
    func testTheFourZeroOnlyChannelsAreOmittedOnAFiveMG() {
        let l = line(liveHr: 4, chunks: 3, oHr: 1200, oRr: 2400, oGrav: 8000,
                     oResp: nil, oSkin: 8000, oSpo2: nil, oSteps: nil, oAux: 8000)
        XCTAssertEqual(l,
            "banked this link: live hr=4 rr=0 | offload hr=1200 rr=2400 gravity=8000"
                + " skinTemp=8000 v18aux=8000")
        XCTAssertFalse(l.contains("resp"), "a channel this family cannot fill must not be named")
        XCTAssertFalse(l.contains("spo2"))
        XCTAssertFalse(l.contains("nothing banked"))
    }

    /// The mirror: a WHOOP 4.0 cannot produce the v18 aux stream, so it is omitted there rather than
    /// reported as a zero — otherwise the fix would just move the false accusation to the other family.
    func testTheAuxChannelIsOmittedOnAFourZero() {
        let l = line(liveHr: 1, chunks: 2, oHr: 500, oRr: 900, oGrav: 700, oResp: 700, oSkin: 700,
                     oSpo2: 700, oSteps: nil, oAux: nil)
        XCTAssertFalse(l.contains("v18aux"))
        XCTAssertTrue(l.contains("spo2=700"))
    }

    /// A 5/MG whose offload banked NO aux rows is a real finding and must still be reported — the point
    /// is to stop printing a constant, not to go quiet on the one channel that carries the evidence.
    func testAnEmptyAuxStreamOnAFiveMGIsStillNamed() {
        let l = line(liveHr: 2, chunks: 5, oHr: 100, oResp: nil, oSpo2: nil, oSteps: nil, oAux: 0)
        XCTAssertTrue(l.contains("v18aux=0"))
        XCTAssertTrue(l.contains("nothing banked from the offload for: rr, gravity, skinTemp, v18aux"))
    }
}