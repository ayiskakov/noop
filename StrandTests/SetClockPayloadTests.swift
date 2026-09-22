import XCTest
@testable import Strand

/// Pins the SET_CLOCK payload form NOOP sends. An un-clocked strap banks no sensor history to flash, so
/// the byte layout and length are load-bearing (#120). The legacy 9-byte form is a protocol fact from the
/// WHOOP 4 fw-41.17.x era that nothing sends any more; only the 8-byte form reaches a 5/MG.
@MainActor
final class SetClockPayloadTests: XCTestCase {

    // 8-byte form: [seconds u32 LE][4 zero subseconds]. Length must be exactly 8.
    func testEightByteFormLayout() {
        let now: UInt32 = 0x11223344
        let p = BLEManager.setClockPayload(now: now)
        XCTAssertEqual(p.count, 8)
        XCTAssertEqual(Array(p[0..<4]), [0x44, 0x33, 0x22, 0x11], "u32 LE seconds")
        XCTAssertEqual(Array(p[4..<8]), [0, 0, 0, 0], "subseconds zeroed")
    }

}
