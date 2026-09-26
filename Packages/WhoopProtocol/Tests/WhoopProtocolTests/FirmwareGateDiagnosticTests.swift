import XCTest
@testable import WhoopProtocol

/// Pins the 5/MG firmware-gate diagnostic. Kotlin twin: `FirmwareGateDiagnosticTest`.
///
/// The decoder reads the version at pay[93] behind a `pay[93] == 50` guard, both anchored to a single
/// 50.38.1.0 capture. The guards fail closed, so a strap that does not match reports nothing — and a
/// different generation byte is indistinguishable from a MOVED offset unless the line says which.
final class FirmwareGateDiagnosticTests: XCTestCase {

    private func payload(count: Int, at93: UInt8) -> [UInt8] {
        var p = (0..<count).map { UInt8($0 % 256) }
        if count > 93 { p[93] = at93 }
        return p
    }

    func testReportsTheByteItActuallySawAndTheExpectedOne() {
        let line = firmwareGateDiagnostic(payload: payload(count: 128, at93: 51), nameEndIndex: 27)
        XCTAssertTrue(line.contains("at93=51 expected=50"), line)
        XCTAssertTrue(line.contains("len=128"), line)
    }

    func testCarriesTheNameEndBecauseThatIsWhatMovesTheOffset() {
        // The version sits after the name+token region, so where the printable-ASCII name run ended is
        // the number that lets a reader re-derive a shifted offset.
        let line = firmwareGateDiagnostic(payload: payload(count: 128, at93: 51), nameEndIndex: 31)
        XCTAssertTrue(line.contains("nameEnd=31"), line)
    }

    func testTheHexWindowSpansTheRegionTheVersionShouldOccupy() {
        let line = firmwareGateDiagnostic(payload: payload(count: 128, at93: 51), nameEndIndex: 27)
        XCTAssertTrue(line.contains("hex[88..<101]="), line)
        // 13 bytes, two hex chars each.
        let hex = line.components(separatedBy: "hex[88..<101]=").last ?? ""
        XCTAssertEqual(hex.count, 26, hex)
    }

    func testAShortPayloadCannotTrapAndSaysSo() {
        // A malformed/truncated hello must not crash the decoder; the window clamps and at93 reports n/a.
        let line = firmwareGateDiagnostic(payload: [1, 2, 3], nameEndIndex: 2)
        XCTAssertTrue(line.contains("at93=n/a"), line)
        XCTAssertTrue(line.contains("len=3"), line)
    }

    func testAPayloadEndingExactlyAtTheWindowStartYieldsAnEmptyWindow() {
        let line = firmwareGateDiagnostic(payload: Array(repeating: 0, count: 88), nameEndIndex: 20)
        XCTAssertTrue(line.hasSuffix("hex[88..<88]="), line)
    }
    /// W06-087: the strap answers GET_HELLO first with PENDING and a zeroed body (`docs/PROTOCOL_TRANSPORT.md`
    /// §Hello), which carries no block. Decoding it reported a firmware-gate failure on every connect.
    func testThePendingHelloAcknowledgementDecodesNoBlock() {
        let pending = puffinCommandFrame(cmd: 145, seq: 0x6d, payload: [0x01, 0x02] + [UInt8](repeating: 0, count: 107),
                                         type: 36, header: [0x01, 0x00])
        let parsed = parseFrame(pending, family: .whoop5).parsed
        XCTAssertNil(parsed["fw_gate"])
        XCTAssertNil(parsed["fw_version"])
        XCTAssertNil(parsed["device_name"])
    }

    /// The control: a SUCCESS reply whose version byte fails the guard still reports the gate, the #1634 evidence.
    func testASuccessHelloThatFailsTheVersionGuardStillReportsTheGate() {
        let success = puffinCommandFrame(cmd: 145, seq: 0x6d, payload: [0x01, 0x01] + [UInt8](repeating: 0, count: 107),
                                         type: 36, header: [0x01, 0x00])
        XCTAssertNotNil(parseFrame(success, family: .whoop5).parsed["fw_gate"])
    }
}
