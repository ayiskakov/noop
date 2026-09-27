import XCTest
@testable import WhoopProtocol

/// W06-005, W06-129 … W06-131: the reject screen names its reason for each record, so the sync status reports
/// only records NOOP could not decode. Intact records of a mapped layout that bank no row (v20 and v21 with no
/// storage lane, a v16 whose FIFO holds no sample, a record the timestamp gate refuses) are archived but are not
/// undecodable.
final class HistoricalRecordRejectionTests: XCTestCase {

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

    private func reasons(_ frames: [[UInt8]], wallNow: Int? = nil) -> [HistoricalRecordRejection] {
        classifyRejectedHistoricalRecords(frames, family: .whoop5, wallNow: wallNow ?? Int(unix)).map(\.rejection)
    }

    func testIntactV20AndV21HaveNoStorageLaneAndAreNotUndecodable() {
        XCTAssertEqual(reasons([frame(version: 20), frame(version: 21)]), [.noStorageLane, .noStorageLane])
        XCTAssertFalse(HistoricalRecordRejection.noStorageLane.isUndecodable)
    }

    func testACorruptedV20OrV21IsNotIntact() {
        for version: UInt8 in [20, 21] {
            var f = frame(version: version)
            f[f.count - 1] ^= 0xff
            XCTAssertEqual(reasons([f]), [.notIntact], "v\(version) with a bad CRC-32")
        }
        XCTAssertTrue(HistoricalRecordRejection.notIntact.isUndecodable)
    }

    func testAnUnmappedLayoutIsUndecodableAndOtherTypesAreNotRejected() {
        XCTAssertEqual(reasons([frame(version: 25), frame(version: 99)]), [.unmappedLayout, .unmappedLayout])
        XCTAssertTrue(HistoricalRecordRejection.unmappedLayout.isUndecodable)
        XCTAssertEqual(reasons([frame(version: 20, type: 50), [0xAA, 0x01]]), [], "a console frame, a runt")
    }

    /// W06-131: an intact record the #547 gate refuses is the strap clock's, not an unrecognised layout.
    func testAnIntactRecordTheTimestampGateRefusesIsTheClocks() {
        let wayBefore = Int(unix) - 400 * 86_400
        XCTAssertEqual(reasons([frame(version: 21)], wallNow: wayBefore), [.timestampRefused])
        XCTAssertFalse(HistoricalRecordRejection.timestampRefused.isUndecodable)
    }

    /// The classifier returns exactly the frames `rejectedHistoricalRecords` returns, in order.
    func testTheFramesAreTheRejectedRecords() {
        var bad = frame(version: 20); bad[bad.count - 1] ^= 0xff
        let frames = [frame(version: 20), frame(version: 18), bad, frame(version: 20, type: 50),
                      frame(version: 25), frame(version: 21)]
        XCTAssertEqual(classifyRejectedHistoricalRecords(frames, family: .whoop5, wallNow: Int(unix)).map(\.frame),
                       rejectedHistoricalRecords(frames, family: .whoop5, wallNow: Int(unix)))
    }

    /// Every mapped layout whose intact record banks no row is archived with a reason that is not undecodable,
    /// so a layout that gains or loses a lane cannot bring the false "couldn't be decoded" status back. Only
    /// layouts this synthetic zero-body frame parses as intact are covered (v20 and v21 today); v16's empty-FIFO
    /// case uses the hardware fixture in `Whoop5HistoricalV16Tests`.
    func testAMappedLayoutThatBanksNoRowIsNeverUndecodable() {
        for version in mappedWhoop5HistoricalVersions.sorted() {
            let f = frame(version: UInt8(version))
            let parsed = parseFrame(f, family: .whoop5)
            guard parsed.ok, parsed.crcOK != false else { continue }
            let streams = extractHistoricalStreams([parsed], deviceClockRef: Int(unix), wallClockRef: Int(unix),
                                                   wallNow: Int(unix))
            guard streams.isEmpty else { continue }
            let got = reasons([f])
            XCTAssertEqual(got.count, 1, "v\(version) banks no row, so it must reach the archive")
            XCTAssertFalse(got.first?.isUndecodable ?? true, "v\(version) is intact and mapped: \(got)")
        }
    }
}
