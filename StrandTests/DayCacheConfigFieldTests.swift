import XCTest
@testable import Strand

/// Which config field dropped the day cache.
///
/// #2073 made a wholesale drop visible (`configDropped`), and a field log on build 487 showed it firing
/// for real: `reused=0/21 missBy=absent:21,configDropped:1`, against a healthy pass that reuses 20 of 21
/// and misses only today. The expensive passes cost up to 35 s of prep and 22 s of scoring, so which
/// field moved is the difference between a config the user actually changed and a value that drifts on
/// its own.
///
/// The signature is a plain "|"-joined value list. `analyzeRecent` builds it from (name, value) pairs and
/// hands the names to the reader. The names used to live in a separate list, which fell one behind when
/// the Healthspan zone set joined the signature, and every drop since read "unknown". A reader that guessed
/// an index would name the wrong field, which is worse than saying nothing, so a count mismatch is refused.
final class DayCacheConfigFieldTests: XCTestCase {

    /// The names `analyzeRecent` passes, in its order.
    private let fields = [
        "hrvBaseline", "rhrBaseline", "age", "sex", "stepTicksPerStep", "maxHROverride",
        "tzOffset", "sleepNeedHours", "sleepConsistency", "habitualMidsleep",
        "sleepStager", "motionAwareWake", "deepHrvWindow", "spo2CandidateDisplay",
        "effortMethod", "dayCycleMode", "healthspanZones",
    ]

    /// A signature with one value per field, so a changed index has a name to resolve to.
    private func fullSig(_ mutate: (inout [String]) -> Void = { _ in }) -> String {
        var v = fields.indices.map { "v\($0)" }
        mutate(&v)
        return v.joined(separator: "|")
    }

    private func moved(_ previous: String, _ current: String) -> String {
        IntelligenceEngine.changedConfigField(previous: previous, current: current, fields: fields)
    }

    func testTheMovedFieldIsNamed() {
        XCTAssertEqual(moved(fullSig(), fullSig { $0[0] = "moved" }), "hrvBaseline")
    }

    /// The field log's leading suspicion was a rolling baseline, which is index 0 and 1. Naming them
    /// apart is the whole point: one is HRV drifting, the other resting heart rate.
    func testTheTwoBaselinesAreToldApart() {
        XCTAssertEqual(moved(fullSig(), fullSig { $0[1] = "moved" }), "rhrBaseline")
        XCTAssertEqual(moved(fullSig(), fullSig { $0[15] = "moved" }), "dayCycleMode")
    }

    /// Several at once happens on a settings change that touches more than one knob.
    func testSeveralMoversAreAllNamed() {
        let after = fullSig { $0[0] = "a"; $0[14] = "b" }
        XCTAssertEqual(moved(fullSig(), after), "hrvBaseline+effortMethod")
    }

    /// The signature starts EMPTY rather than nil, so the first drop of a process has nothing to diff
    /// against. Reporting that as "unknown" would describe a shape mismatch that never happened.
    func testTheFirstDropOfAProcessSaysFirst() {
        XCTAssertEqual(moved("", fullSig()), "first")
    }

    /// A signature whose value count differs from the names is refused rather than resolved against a list
    /// that no longer describes it. A wrong field name is worse than none: a diagnostic asserting what it
    /// cannot attribute.
    func testAShapeMismatchIsRefusedRatherThanGuessed() {
        XCTAssertEqual(moved("a|b", "a|c"), "unknown")
        XCTAssertEqual(moved(fullSig(), "a"), "unknown")
    }

    /// The Healthspan zone set, the field the old separate name list was missing: moving it is named.
    func testTheHealthspanZoneSetIsNamed() {
        XCTAssertEqual(moved(fullSig(), fullSig { $0[16] = "moved" }), "healthspanZones")
    }

    /// Equal signatures never reach the caller, but the helper still answers honestly if they do.
    func testAnUnchangedSignatureNamesNothing() {
        XCTAssertEqual(moved(fullSig(), fullSig()), "none")
    }
}
