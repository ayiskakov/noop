import XCTest
import WhoopProtocol
@testable import Strand

/// W03-014 — the SpO₂ card's night chart merges byte-82 rows from every strap id it reads. A second
/// belongs to the first id that reported a value there, never to a row that reported nothing.
final class Spo2CandidateTraceMergeTests: XCTestCase {

    private func aux(_ ts: Int, _ v: Int?) -> V18AuxSample { V18AuxSample(ts: ts, auxByte82: v) }

    /// A first strap's row with no byte-82 value (nil, or 0 for "not measuring") must not hide a second
    /// strap's reading at the same second.
    func testARowWithoutAValueDoesNotClaimItsSecond() {
        let merged = Repository.mergeSpo2CandidateAux([[aux(10, nil), aux(11, 0)], [aux(10, 95), aux(11, 96)]])
        XCTAssertEqual(merged.map(\.ts), [10, 11])
        XCTAssertEqual(merged.map(\.auxByte82), [95, 96])
    }

    /// The first id to report a value keeps its second, and a code claims it too: the resolver needs a
    /// reading's codes to judge it.
    func testTheFirstIdWithAValueOrACodeKeepsTheSecond() {
        let merged = Repository.mergeSpo2CandidateAux([[aux(10, 94), aux(11, 128)], [aux(10, 99), aux(11, 97)]])
        XCTAssertEqual(merged.map(\.auxByte82), [94, 128])
    }
}
