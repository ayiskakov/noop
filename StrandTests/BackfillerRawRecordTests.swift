import XCTest
import WhoopProtocol
import WhoopStore
@testable import Strand

/// W01-006: the offload's default extractor hands the chunk's frames to the extraction, so a v26 PPG row
/// reaches the store with the whole intact frame the strap frees at the trim ack. The frame is the real
/// v26 record `Whoop5PpgWaveformTests` pins.
@MainActor
final class BackfillerRawRecordTests: XCTestCase {

    /// Keeps the Streams each insert receives.
    final class CapturingStore: BackfillStoreWriting {
        var inserted: [Streams] = []
        @discardableResult
        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int,
                spo2: Int, skinTemp: Int, resp: Int, gravity: Int, v18Aux: Int) {
            inserted.append(streams)
            return (0, 0, 0, 0, 0, 0, 0, 0, 0)
        }
        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {}
        func setCursor(_ name: String, _ value: Int) async throws {}
        func cursor(_ name: String) async throws -> Int? { nil }
    }

    private func bytes(_ s: String) -> [UInt8] {
        stride(from: 0, to: s.count, by: 2).map { i in
            let a = s.index(s.startIndex, offsetBy: i)
            return UInt8(s[a...s.index(a, offsetBy: 1)], radix: 16)!
        }
    }

    private let v26Hex =
        "aa015000010035412f1a80ad418401f0a3266aae470100c3c5050068faccfa8dfb46fc8bfd4c" +
        "febafedafe6dff56ffd5fffbff37ff6afce5f9d7f8dffa5efc98fddbfe5afe84fe15ff5cff40" +
        "5fb33c50080101006cb67c17"

    private func historyEnd(trim: UInt32) -> [UInt8] {
        func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * UInt32($0))) } }
        return w5Frame(le32(1_700_000_000) + [0, 0] + le32(0) + le32(trim), type: 49, cmd: 2)
    }

    func testAnOffloadedPpgRowCarriesItsWholeFrame() async {
        let store = CapturingStore()
        let backfiller = Backfiller(store: store, deviceId: "raw-record", ackTrim: { _, _ in },
                                    enableRawCapture: false, rejectedSink: { _, _, _ in true })
        backfiller.begin(family: .whoop5)
        let record = bytes(v26Hex)
        XCTAssertTrue(verifyFrame(record, family: .whoop5).ok)
        await backfiller.ingest(record)
        await backfiller.ingest(historyEnd(trim: 100))
        let rows = store.inserted.flatMap(\.ppgWaveform)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.rawRecord, record)
    }
}
