import XCTest
@testable import WhoopProtocol

/// W06-005: v20 and v21 are mapped layouts with no storage lane, so every one of their records reaches the
/// reject archive intact, and each sync reported them as records that "couldn't be decoded". These pin the
/// classifier that tells them apart from records that really are undecodable.
final class IntactRecordWithoutStorageLaneTests: XCTestCase {

    private let unix: UInt32 = 1_781_556_371

    /// A valid WHOOP 5/MG type-47 frame at its layout's real length (v20 2,140 B, v21 1,244 B): the envelope,
    /// header CRC-16 and payload CRC-32 made the way the strap makes them, with a plausible timestamp and an
    /// otherwise zero body.
    private func frame(version: UInt8, type: UInt8 = 0x2f) -> [UInt8] {
        let total = version == 20 ? 2_140 : version == 21 ? 1_244 : 96
        var f = [UInt8](repeating: 0, count: total)
        f[0] = 0xAA; f[1] = 0x01
        let declared = total - 8
        f[2] = UInt8(declared & 0xff); f[3] = UInt8((declared >> 8) & 0xff)
        f[4] = 0x01; f[5] = 0x00
        f[8] = type
        f[9] = version
        f[10] = 0x80
        for i in 0..<4 { f[15 + i] = UInt8((unix >> (8 * UInt32(i))) & 0xff) }
        let h = crc16Modbus(Array(f[0..<6]))
        f[6] = UInt8(h & 0xff); f[7] = UInt8((h >> 8) & 0xff)
        let end = total - 4
        let c = crc32(Array(f[8..<end]))
        for i in 0..<4 { f[end + i] = UInt8((c >> (8 * UInt32(i))) & 0xff) }
        return f
    }

    func testIntactV20AndV21AreRecordsWithoutALane() {
        XCTAssertTrue(isIntactRecordWithoutStorageLane(frame(version: 20)))
        XCTAssertTrue(isIntactRecordWithoutStorageLane(frame(version: 21)))
    }

    func testACorruptedV20OrV21IsAGenuineReject() {
        for version: UInt8 in [20, 21] {
            var f = frame(version: version)
            f[f.count - 1] ^= 0xff
            XCTAssertFalse(isIntactRecordWithoutStorageLane(f), "v\(version) with a bad CRC-32 is undecodable")
        }
    }

    func testLayoutsWithALaneUnmappedLayoutsAndOtherTypesAreNot() {
        for version: UInt8 in [16, 18, 26, 25, 99] {
            XCTAssertFalse(isIntactRecordWithoutStorageLane(frame(version: version)), "v\(version)")
        }
        XCTAssertFalse(isIntactRecordWithoutStorageLane(frame(version: 20, type: 50)), "a console frame")
        XCTAssertFalse(isIntactRecordWithoutStorageLane([0xAA, 0x01]), "too short")
    }

    /// The lane set is a claim about `extractHistoricalStreams`: a mapped layout outside it banks no row, so its
    /// records reach the archive. If one of them gains a lane, this fails until the set says so.
    func testTheLaneSetMatchesWhatExtractionBanks() {
        XCTAssertTrue(whoop5HistoricalVersionsWithStorageLane.isSubset(of: mappedWhoop5HistoricalVersions))
        for version in mappedWhoop5HistoricalVersions.subtracting(whoop5HistoricalVersionsWithStorageLane).sorted() {
            let f = frame(version: UInt8(version))
            let parsed = parseFrame(f, family: .whoop5)
            XCTAssertEqual(parsed.parsed["unix"]?.intValue, Int(unix), "v\(version) must decode for this to mean anything")
            let streams = extractHistoricalStreams([parsed], deviceClockRef: Int(unix), wallClockRef: Int(unix),
                                                   wallNow: Int(unix))
            XCTAssertTrue(streams.isEmpty, "v\(version) banked rows, so it has a lane")
            XCTAssertEqual(rejectedHistoricalRecords([f], family: .whoop5, wallNow: Int(unix)), [f],
                           "v\(version) must reach the archive")
        }
    }
}
