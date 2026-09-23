import XCTest
@testable import WhoopProtocol

/// The WHOOP 5/MG **R17 filtered ECG record** decoder (`Whoop5EcgFilteredRecord`), pinned against the
/// fixed geometry in `docs/PROTOCOL_ECG.md` §"R17 filtered waveform".
///
/// The frames are CONSTRUCTED, not captured: no live R17 frame had been dumped when this decoder landed.
/// Every expected value is therefore a literal chosen by the test, so a test can only fail on the decode.
final class Whoop5EcgFilteredRecordTests: XCTestCase {

    /// A 240-byte R17 frame: `samples` i16-LE from @34, `count` at @32, status bytes at @21–31.
    private func frame(samples: [Int], count: Int? = nil, type: UInt8 = 43, layout: UInt8 = 17,
                       status: [UInt8] = [3, 0x0A, 1, 2, 100, 0, 73, 71, 0x34, 0x12, 0],
                       alignment: [UInt8] = [0, 0]) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: Whoop5EcgFilteredRecord.frameLength)
        f[0] = 0xAA
        f[8] = type
        f[9] = layout
        f[11] = 0x04; f[12] = 0x03; f[13] = 0x02; f[14] = 0x01            // recordIndex 0x01020304
        f[15] = 0x78; f[16] = 0x56; f[17] = 0x34; f[18] = 0x12            // unix 0x12345678
        for (k, b) in status.enumerated() { f[21 + k] = b }
        let n = count ?? samples.count
        f[32] = UInt8(n & 0xFF); f[33] = UInt8((n >> 8) & 0xFF)
        for (k, v) in samples.enumerated() where 34 + k * 2 + 1 < 234 {
            let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
            f[34 + k * 2] = UInt8(u & 0xFF); f[35 + k * 2] = UInt8(u >> 8)
        }
        f[234] = alignment[0]; f[235] = alignment[1]
        return f
    }

    func testShapeNeedsExactLengthLayout17AndAnEcgTransport() {
        XCTAssertTrue(Whoop5EcgFilteredRecord.isFilteredRecord(frame(samples: [])))
        XCTAssertTrue(Whoop5EcgFilteredRecord.isFilteredRecord(frame(samples: [], type: 47)))
        // Type 43 alone is not enough: live R16 shares it.
        XCTAssertFalse(Whoop5EcgFilteredRecord.isFilteredRecord(frame(samples: [], layout: 16)))
        XCTAssertFalse(Whoop5EcgFilteredRecord.isFilteredRecord(frame(samples: [], type: 36)))
        XCTAssertFalse(Whoop5EcgFilteredRecord.isFilteredRecord(Array(frame(samples: []).prefix(239))))
        XCTAssertNil(Whoop5EcgFilteredRecord.decode(frame(samples: [], layout: 16)))
    }

    func testOnlyTypeFortyThreeIsALiveRecord() {
        // A historical R17 is a finished session's record: a live trace must never take it.
        XCTAssertTrue(Whoop5EcgFilteredRecord.isLiveRecord(frame(samples: [])))
        XCTAssertFalse(Whoop5EcgFilteredRecord.isLiveRecord(frame(samples: [], type: 47)))
        XCTAssertFalse(Whoop5EcgFilteredRecord.isLiveRecord(frame(samples: [], layout: 16)))
    }

    func testSamplesAreSignedLittleEndianAndExactlyTheDeclaredCount() {
        let d = Whoop5EcgFilteredRecord.decode(frame(samples: [0, 1, -1, 32767, -32768, -9798]))!
        XCTAssertEqual(d.samples, [0, 1, -1, 32767, -32768, -9798])
        XCTAssertEqual(d.recordIndex, 0x0102_0304)
        XCTAssertEqual(d.unix, 0x1234_5678)
        XCTAssertEqual(d.anomalies, [])
    }

    func testAFullRecordIsOneHundredSamplesAndNeverReadsTheAlignmentBytes() {
        // Non-zero alignment bytes would surface as a 101st sample under the old slice reading.
        let full = (0..<100).map { $0 * 3 - 150 }
        let d = Whoop5EcgFilteredRecord.decode(frame(samples: full, alignment: [0x39, 0x05]))!
        XCTAssertEqual(d.samples.count, 100)
        XCTAssertEqual(d.samples, full)
        XCTAssertFalse(d.samples.contains(0x0539))
    }

    func testCountedZerosAreKept() {
        let d = Whoop5EcgFilteredRecord.decode(frame(samples: [0, 0, 0, 5], count: 4))!
        XCTAssertEqual(d.samples, [0, 0, 0, 5])
    }

    func testOverCapacityCountIsQuarantinedNotTruncated() {
        let d = Whoop5EcgFilteredRecord.decode(frame(samples: [1, 2, 3], count: 101))!
        XCTAssertEqual(d.samples, [])
        XCTAssertEqual(d.anomalies, [.waveformCountOverCapacity(declared: 101)])
    }

    func testStatusIsTheSharedPackedRegionIncludingTheR17Byte() {
        let s = Whoop5EcgFilteredRecord.decode(frame(samples: [7]))!.status
        XCTAssertEqual(s.quality, 3)
        XCTAssertEqual(s.stateBits, 0x0A)
        XCTAssertEqual(s.classifierResult, 1)
        XCTAssertEqual(s.classifierState, 2)
        XCTAssertEqual(s.progress, 100)
        XCTAssertEqual(s.hrRelated, 73)
        XCTAssertEqual(s.hrRelatedR17, 71)
        XCTAssertEqual(s.hrvRelated, 0x1234)
        XCTAssertEqual(s.declaredSampleCount, 1)
    }

    func testPresenceIsBit3OfTheStateByteOnly() {
        func presence(_ bits: UInt8) -> Bool {
            Whoop5EcgFilteredRecord.decode(frame(samples: [], status: [0, bits]))!.status.presence
        }
        XCTAssertTrue(presence(0x08))
        XCTAssertTrue(presence(0x0A))
        XCTAssertFalse(presence(0x03))   // "entered state 1" with no presence, seen on hardware
        XCTAssertFalse(presence(0x07))
    }
}
