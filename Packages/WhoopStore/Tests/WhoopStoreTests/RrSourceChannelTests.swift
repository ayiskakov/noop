import XCTest
import WhoopProtocol
@testable import WhoopStore

/// `rrInterval.srcChannel` (#1071, v32) labels the TRANSPORT a beat arrived on, so a strap that reports
/// the same heartbeats on more than one transport cannot have both copies scored as separate beats —
/// which leaves the MEAN correct (resting HR was never wrong) while destroying everything built on
/// successive differences: a ~200 ms nocturnal SDNN where a healthy adult asleep is 40-100 ms.
///
/// The fix is deliberately NOT a de-duplication: both rows are real measurements, so the transport is
/// LABELLED at decode, both rows are STORED, and the scoring read takes one. These tests pin the column
/// shape plus the two things a transport filter can most easily break — an unlabelled WHOOP row (NULL
/// forever when nothing distinguishes a transport) and a pre-v32 row (NULL, never labelled).
final class RrSourceChannelTests: XCTestCase {
    private let ts = 1_750_000_000

    // MARK: - The migration

    func testV32AddsSrcChannelAndKeepsItOutOfThePrimaryKey() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "rrInterval")
        XCTAssertTrue(cols.contains("srcChannel"), "rrInterval missing v32 srcChannel column")
        let pk = try await store.primaryKeyColumns("rrInterval")
        XCTAssertEqual(pk, ["deviceId", "ts", "rrMs", "seq"],
                       "srcChannel must not enter the key — keying on the label would store the SAME " +
                       "beat twice under two labels, which is the double-count this fixes")
    }

    // MARK: - The durable storage codes

    /// The stored codes are a wire format, so they are pinned, and 1-4 stay RETIRED. They labelled the
    /// multi-tag optical channels of a source NOOP no longer supports; reclaiming one would silently
    /// reinterpret an existing row as a WHOOP transport.
    func testWhoop5TransportCodesArePinnedAndRetiredCodesStayUnclaimed() {
        XCTAssertEqual(RRSourceChannel.whoop5Historical.rawValue, 5)
        XCTAssertEqual(RRSourceChannel.whoop5Realtime.rawValue, 6)
        XCTAssertEqual(RRSourceChannel.whoop5Standard.rawValue, 7)
        for retired in 1...4 {
            XCTAssertNil(RRSourceChannel(rawValue: retired),
                         "code \(retired) is retired and must not be reused for a WHOOP transport")
        }
        XCTAssertTrue(RRSourceChannel.allCases.allSatisfy(\.isWhoop5Transport))
    }

    // MARK: - What the filter must never drop

    /// The regression the read policy could most easily cause. A strap with ONE beat source stores no
    /// transport label, so a whitelist filter would have deleted every such night from scoring.
    func testUnlabelledRowsCarryNoChannelAndAreNeverFiltered() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "strap", mac: nil, name: nil)
        let beats = [812, 795, 840, 801, 833]
        _ = try await store.insert(
            Streams(rr: beats.map { RRInterval(ts: ts, rrMs: $0) }), deviceId: "strap")

        let stored = try await store.rrRowsWithChannelForTest(deviceId: "strap")
        XCTAssertEqual(stored.map(\.srcChannel), Array(repeating: nil, count: 5),
                       "NULL is the honest value for a single-source strap, not a placeholder")
        let read = try await store.rrIntervals(deviceId: "strap", from: 0, to: ts + 10, limit: 100)
        XCTAssertEqual(read.map(\.rrMs), beats, "emission order (#823) is unchanged by the filter")
        XCTAssertEqual(read.map(\.srcChannel), Array(repeating: nil, count: 5))
    }

    /// Rows written before v32 are NULL and still read. They were never labelled, so a backfill would be
    /// a guess and dropping them would delete real history.
    func testPreV32RowsAreUnlabelledAndStillRead() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "strap", mac: nil, name: nil)
        for v in [812, 795, 840] {
            try await store.insertLegacyRrWithoutOrdForTest(deviceId: "strap", ts: ts, rrMs: v)
        }
        let read = try await store.rrIntervals(deviceId: "strap", from: 0, to: ts + 10, limit: 100)
        XCTAssertEqual(read.map(\.rrMs), [795, 812, 840],
                       "pre-v32 rows keep the pre-v30 (rrMs, seq) fallback order, unchanged")
        XCTAssertEqual(read.map(\.srcChannel), [nil, nil, nil])
    }
}
