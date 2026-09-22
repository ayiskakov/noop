import XCTest
@testable import WhoopProtocol

final class FramingTests: XCTestCase {
    // Synthetic, CRC-valid frames built by scripts/gen_synthetic_fixtures.py (no real capture).
    static func hex(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            out.append(UInt8(s[idx..<next], radix: 16)!)
            idx = next
        }
        return out
    }

    /// A real captured 5/MG COMMAND_RESPONSE, fully valid.
    static let realtimeLike = "aa010c000001e74124070211223344557481f36e"

    func testVerifyFrameValidCapture() {
        let frame = Self.hex(Self.realtimeLike)
        let check = verifyFrame(frame, family: .whoop5)
        XCTAssertTrue(check.ok)
        XCTAssertEqual(check.length, 12)        // declared = payload + CRC32 trailer
        XCTAssertEqual(check.crc8OK, true)      // the CRC16-Modbus header outcome
        XCTAssertEqual(check.crc32OK, true)
    }

    func testFlippingAPayloadByteBreaksCRC32() {
        var frame = Self.hex(Self.realtimeLike)
        frame[w5InnerStart + 2] ^= 0xFF          // corrupt an inner byte -> crc32 must fail
        let check = verifyFrame(frame, family: .whoop5)
        XCTAssertFalse(check.ok)
        XCTAssertEqual(check.crc8OK, true)       // header CRC untouched
        XCTAssertEqual(check.crc32OK, false)     // body CRC now wrong
    }

    func testFlippingTheHeaderCRCWordBreaksTheHeaderCheck() {
        var frame = Self.hex(Self.realtimeLike)
        frame[6] ^= 0xFF
        XCTAssertEqual(verifyFrame(frame, family: .whoop5).crc8OK, false)
    }

    func testShortFrameRejected() {
        XCTAssertFalse(verifyFrame([0xAA, 0x01, 0x02], family: .whoop5).ok)
        XCTAssertEqual(verifyFrame([0xAA, 0x01, 0x02], family: .whoop5).length, nil)
    }

    func testNonSOFRejected() {
        let bad: [UInt8] = [0x00, 0x18, 0x00, 0xff, 0x28, 0x02, 0x0f, 0x00]
        XCTAssertFalse(verifyFrame(bad, family: .whoop5).ok)
    }

    func testCrc32EmptyIsZero() {
        XCTAssertEqual(crc32([]), 0)
    }


    func testFrameFromPayloadRoundTrip() {
        // Bare payload of 4 bytes; type=43, seq=0, cmd=0.
        let data: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        let frame = w5Frame(data, type: 43, seq: 0, cmd: 0)
        // inner = [43,0,0] + data (7 bytes); declared length = 7 + 4 = 11.
        XCTAssertEqual(frame[0], 0xAA)
        XCTAssertEqual(frame[1], 0x01)
        XCTAssertEqual(Int(frame[2]) | (Int(frame[3]) << 8), 11)
        // The header checksum is computed for real, so a rebuilt frame is one a strap could have
        // sent rather than one every gate now rejects.
        let wantHeaderCRC = crc16Modbus(Array(frame[0..<6]))
        XCTAssertEqual(UInt16(frame[6]) | (UInt16(frame[7]) << 8), wantHeaderCRC)
        XCTAssertEqual(frame[w5InnerStart], 43)
        XCTAssertEqual(frame[w5InnerStart + 1], 0)
        XCTAssertEqual(frame[w5InnerStart + 2], 0)
        XCTAssertEqual(Array(frame[(w5InnerStart + 3)..<(w5InnerStart + 7)]), data)
        // crc32 is over the inner bytes (type+seq+cmd+data).
        let inner: [UInt8] = [43, 0, 0] + data
        let want = crc32(inner)
        let trailer = w5InnerStart + inner.count
        let got = UInt32(frame[trailer]) | (UInt32(frame[trailer + 1]) << 8)
            | (UInt32(frame[trailer + 2]) << 16) | (UInt32(frame[trailer + 3]) << 24)
        XCTAssertEqual(got, want)
        // The reconstructed frame verifies end to end: both checksums AND the exact length.
        let check = verifyFrame(frame, family: .whoop5)
        XCTAssertEqual(check.crc32OK, true)
        XCTAssertEqual(check.crc8OK, true)
        XCTAssertTrue(check.ok)
        XCTAssertEqual(check.reason, .none)
    }

    func testFrameFromPayloadDefaults() {
        let frame = w5Frame([0x01], type: 40)
        XCTAssertEqual(frame[w5InnerStart + 1], 0) // seq default
        XCTAssertEqual(frame[w5InnerStart + 2], 0) // cmd default
    }
}
