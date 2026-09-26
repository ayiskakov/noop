import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

/// W01-006, v50: every v26 PPG and v16 ECG row keeps the whole intact frame it was decoded from. Both
/// layouts are mapped, so they skip the rolling raw archive, and the strap frees each record at the trim
/// ack; before v50 the bytes no column maps (the v26 record index and footer, v16 bytes 26 and 28–31) had
/// no copy anywhere once the ack went out.
final class HistoricalRawRecordTests: XCTestCase {

    private let frameA: [UInt8] = [0xAA, 0x01, 0x50, 0x00, 0x01, 0x00, 0x12, 0x34, 47, 26, 0xFF, 0x7F]
    private let frameB: [UInt8] = [0xAA, 0x01, 0x50, 0x00, 0x01, 0x00, 0x12, 0x34, 47, 16, 0x00, 0x80]

    func testV50AddsANullableRawRecordAndKeepsExistingRowsAsTheyWere() async throws {
        let dbQueue = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(dbQueue, upTo: "v49-ecg-r16-record")
        let ppg = WhoopStore.packPpgSamples([-12, 40, 7])
        let ecg = WhoopStore.packEcgCandidateSamples([-4592, 1007])
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO ppgWaveformSample (deviceId, ts, samples, burstIndex, baseCode) VALUES (?, ?, ?, ?, ?)
                """, arguments: ["my-whoop", 1_789_990_000, ppg, 3, 378_307])
            try db.execute(sql: """
                INSERT INTO ecgCandidateSample (deviceId, ts, samples, recordIndex, declaredCount) VALUES (?, ?, ?, ?, ?)
                """, arguments: ["my-whoop", 1_789_990_296, ecg, 29_974_484, 2])
        }

        try WhoopStore.makeMigrator().migrate(dbQueue)

        try await dbQueue.read { db in
            for table in ["ppgWaveformSample", "ecgCandidateSample"] {
                let column = try XCTUnwrap(try db.columns(in: table).first { $0.name == "rawRecord" }, table)
                XCTAssertEqual(column.type.uppercased(), "BLOB", table)
                XCTAssertFalse(column.isNotNull, "\(table): a row banked before v50 has no record to keep")
                XCTAssertNil(column.defaultValueSQL, table)
            }
            let p = try XCTUnwrap(try Row.fetchOne(db, sql: "SELECT * FROM ppgWaveformSample"))
            XCTAssertEqual(p["samples"] as Data, ppg)
            XCTAssertEqual(p["burstIndex"] as Int?, 3)
            XCTAssertEqual(p["baseCode"] as Int?, 378_307)
            XCTAssertNil(p["rawRecord"] as Data?, "no bytes are invented for an existing row")
            let e = try XCTUnwrap(try Row.fetchOne(db, sql: "SELECT * FROM ecgCandidateSample"))
            XCTAssertEqual(e["samples"] as Data, ecg)
            XCTAssertEqual(e["recordIndex"] as Int?, 29_974_484)
            XCTAssertNil(e["rawRecord"] as Data?)
        }
    }

    func testTheRawRecordRoundTripsThroughInsert() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.insert(Streams(
            ppgWaveform: [PpgWaveformSample(ts: 100, samples: [1, 2], rawRecord: frameA)],
            ecgCandidate: [EcgCandidateSample(ts: 200, samples: [3, 4], rawRecord: frameB)]), deviceId: "dev")
        let ppg = try await store.rawRecordForTest(table: "ppgWaveformSample", deviceId: "dev", ts: 100)
        let ecg = try await store.rawRecordForTest(table: "ecgCandidateSample", deviceId: "dev", ts: 200)
        XCTAssertEqual(ppg, Data(frameA))
        XCTAssertEqual(ecg, Data(frameB))
    }

    func testARowWithoutARawRecordStoresNull() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.insert(Streams(
            ppgWaveform: [PpgWaveformSample(ts: 100, samples: [1, 2])],
            ecgCandidate: [EcgCandidateSample(ts: 200, samples: [3, 4])]), deviceId: "dev")
        let ppg = try await store.rawRecordForTest(table: "ppgWaveformSample", deviceId: "dev", ts: 100)
        let ecg = try await store.rawRecordForTest(table: "ecgCandidateSample", deviceId: "dev", ts: 200)
        XCTAssertNil(ppg)
        XCTAssertNil(ecg)
    }

    /// The row keeps the FIRST record for a second, like its samples do (ON CONFLICT DO NOTHING), so the raw
    /// bytes always belong to the samples beside them.
    func testADuplicateSecondKeepsTheFirstRecordsBytesWithItsSamples() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.insert(Streams(ppgWaveform: [PpgWaveformSample(ts: 100, samples: [1], rawRecord: frameA)]),
                                   deviceId: "dev")
        _ = try await store.insert(Streams(ppgWaveform: [PpgWaveformSample(ts: 100, samples: [9], rawRecord: frameB)]),
                                   deviceId: "dev")
        let raw = try await store.rawRecordForTest(table: "ppgWaveformSample", deviceId: "dev", ts: 100)
        let read = try await store.ppgWaveformSamples(deviceId: "dev", from: 100, to: 100)
        XCTAssertEqual(raw, Data(frameA))
        XCTAssertEqual(read.map(\.samples), [[1]])
    }
}
