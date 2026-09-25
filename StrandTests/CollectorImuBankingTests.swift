import XCTest
import CoreBluetooth
import WhoopProtocol
import WhoopStore
@testable import Strand

/// W06-002: the 5/MG frame loop banks IMU buffers into Raw Data Collector sessions through
/// `Collector.bankImuForSessions`. The gate admits intact 1244-byte buffers only, because `Whoop5RawImu`
/// decodes without checking the CRC.
final class CollectorImuBankingTests: XCTestCase {

    /// A real 1244-byte buffer, the fixture `Whoop5RawImuTests` decodes.
    static let fixture: [UInt8] = {
        let hex = "aa01d40401005c702f1580e520af002d3f566a002004640064000300d308cc08c408c908c208cd08b708c208cc08c908cc08e108d608e408d208c508bd08d708c508d208cc08c908bc08b508a908c008cc08cb08d308e108dc08d408d108c108c208c208b708ce08c608e008c308d208bd08c908bb08b708be08c208cc08ce08c608cf08c408c808ca08cb08cf08cb08d508c708c908cc08bf08c308c408cc08cc08cc08c508c708d108c108c608c808c108c408c308c608cf08c808c608cf08ce08c808d008c008d008c608bb08cb08d208c008cb08c708c008c508c208c608cf08d008d3ffcaffc1ffc8ffcaffc5ffccffd4ffd3ffdeffddffd8ffdbffd6ffc7ffc7ffd0ffd5ffd6ffe2ffd4ffceffd6ffd2ffe2ffdbffdbffc7ffc6ffc9ffc1ffb1ffb7ffb7ffc9ffceffe4ffe7ffe4ffeaffe7ffdbffd7ffe0ffd7ffc4ffccffcdffbbffc2ffbeffb9ffccffd4ffd4ffc6ffcaffd3ffc8ffd6ffceffd7ffdaffdfffddffdaffd6ffddffdaffd3ffe1ffd0ffc9ffcdffd1ffcaffd3ffcfffd3ffd6ffcfffcaffc9ffc7ffcaffd7ffd5ffd0ffdaffd4ffddffd6ffd8ffdcffd8ffd4ffcaffe5ffceffccff690d840d810d760d7f0d7a0d730d7a0d800d8a0d820d8c0d800d750d740d740d620d690d800d7a0d7d0d6e0d710d780d790d890d770d810d7d0d760d7d0d7b0d7a0d890d810d830d7a0d6d0d6c0d6f0d690d6d0d790d6d0d730d760d770d850d790d810d760d7d0d750d720d760d740d720d820d750d890d840d830d7d0d7b0d770d7b0d820d6f0d830d6f0d770d6e0d7b0d820d700d760d7f0d6a0d780d790d7c0d830d780d7a0d840d780d6f0d7f0d740d800d7b0d860d7f0d7a0d840d7d0d820d770d810d7c0d6400640005020000000000000900090004000500060007000a000c000b000d000e000c000d000d000c000b00090008000c000d000d0011000e000c000c000b000b000e000f00130011001100100010000e000e000e000e000c000b000c000c000b000e000d0010000e000e000d000d000c000b000c000a000b000c000c000e000b000b000c000c000d000a000b000b000a000b000c000c000c000d000e000f000b000d000b000b000e000d000c000c000b000b000c000c000c000b000b000a000a000b000b000d000f000d000d000b000b000a00fcfffbfffbfffdfff9fffbfffcfffdfffdfffdfffcfffcfffffffcfffcfffdfffffffdfffcffffff01000000fefffdfffdfffefffeffffff0000ffff0200feffffffffff000000000100fefffffffdfffdfffefffdfffefffbfffdffffff0100fefffefffdfffdfffdfffefffdfffffffefffeff0000fefffdfffffffefffdff0000fefffefffefffdfffefffefffefffefffffffffffffffffffdff00000000fefffdfffffffefffdfffefffdfffdfffffffffffdfffefffffffcfffdfffefffdfffdfffefffdfffbfff9fff9fff8fffcfff9fff8fff9fff7fff7fffafffcfffbfffdfffbfffafffcfffcfffbfff9fff8fffcfff9fff8fffbfff9fff9fffcfffcfffcfffffffbfffcfffafff8fff7fff8fff7fff6fff9fff9fffafffcfffbfffdfffdfffcfffcfffcfffcfffbfffbfffafff9fffcfffafff7fffafffbfff9fffbfffafff8fff7fff8fffafff8fff8fffafffafffafffbfffcfffcfffafffafffbfffcfffafffafff9fffafffafff9fff8fff8fff9fff9fffbfff8fffafffafffafffbfffbfff9fffafffafffafff9ff7ae96eb8"
        return stride(from: 0, to: hex.count, by: 2).map {
            let s = hex.index(hex.startIndex, offsetBy: $0)
            return UInt8(hex[s...hex.index(after: s)], radix: 16)!
        }
    }()
    private var realBuffer: [UInt8] { Self.fixture }

    /// `fixture` with its base second moved `seconds` later (the CRC is left stale; the session store does
    /// not check it).
    static func fixture(shiftedBy seconds: UInt32) -> [UInt8] {
        var frame = fixture
        let ts = UInt32(Whoop5RawImu.baseTs(frame)!) + seconds
        for i in 0..<4 { frame[15 + i] = UInt8(truncatingIfNeeded: ts >> (8 * UInt32(i))) }
        return frame
    }

    func testAnIntactBufferIsBanked() {
        XCTAssertEqual(realBuffer.count, Whoop5RawImu.bufferLength)
        XCTAssertTrue(Collector.isBankableImu(realBuffer))
    }

    func testACorruptBufferIsNotBanked() {
        var corrupt = realBuffer
        corrupt[600] ^= 0x01
        XCTAssertNotNil(Whoop5RawImu.rawColumns(corrupt), "precondition: the decoder alone would accept it")
        XCTAssertFalse(Collector.isBankableImu(corrupt))
    }

    func testOtherFramesAreNotBanked() {
        XCTAssertFalse(Collector.isBankableImu(Array(realBuffer.prefix(124))))
        XCTAssertFalse(Collector.isBankableImu([]))
    }

    /// `fixture` with bytes 8 and 9 replaced and its CRC32 recomputed, so only the type check can refuse it.
    static func fixture(type: UInt8, layout: UInt8) -> [UInt8] {
        var frame = fixture
        frame[8] = type; frame[9] = layout
        let crc = crc32(frame, 8, 1240)
        for i in 0..<4 { frame[1240 + i] = UInt8(truncatingIfNeeded: crc >> (8 * UInt32(i))) }
        XCTAssertTrue(verifyFrame(frame, family: .whoop5).ok, "precondition: an intact frame")
        return frame
    }
    private func resealed(type: UInt8, layout: UInt8) -> [UInt8] { Self.fixture(type: type, layout: layout) }

    /// W06-029: an intact frame of the same length but another packet type or layout is not an IMU buffer.
    func testOnlyR21BuffersAreBanked() {
        XCTAssertTrue(Collector.isBankableImu(resealed(type: 43, layout: 21)), "live R21")
        XCTAssertFalse(Collector.isBankableImu(resealed(type: 47, layout: 20)), "historical, another layout")
        XCTAssertFalse(Collector.isBankableImu(resealed(type: 52, layout: 21)), "the dedicated IMU stream")
        XCTAssertFalse(Collector.isBankableImu(resealed(type: 0x24, layout: 9)), "a command frame")
    }

}

/// A `BLEManager` whose collector banks for a fresh strap id, with an open Raw Data Collector session for
/// that strap in the shared IMU store. `close()` removes the session and its files.
@MainActor
final class ImuBankingRig {
    private final class NullStore: StoreWriting {
        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int,
                spo2: Int, skinTemp: Int, resp: Int, gravity: Int, v18Aux: Int) { (0, 0, 0, 0, 0, 0, 0, 0, 0) }
        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {}
    }

    static let dataChar = CBUUID(string: "fd4b0005-cce1-4033-93ce-002d5875f58a")
    let live = LiveState()
    let manager: BLEManager
    let sessionId = "rig-\(UUID().uuidString)"

    init() {
        let deviceId = "rig-\(UUID().uuidString)"
        let ts = Int64(Whoop5RawImu.baseTs(CollectorImuBankingTests.fixture)!)
        ImuSessionFileStore.shared.start(id: sessionId, deviceId: deviceId, fromMs: (ts - 10) * 1_000)
        manager = BLEManager(state: live, collector: Collector(store: NullStore(), deviceId: deviceId))
    }

    var banked: Bool { ImuSessionFileStore.shared.newestBankedTs(sessionId) != nil }

    func close() {
        _ = ImuSessionFileStore.shared.deleteFiles(sessionId)
        ImuSessionFileStore.shared.remove(id: sessionId)
    }
}

/// W06-002's call site, driven through the 5/MG frame handling itself (W06-043): a buffer banks into an open
/// session from the live stream and from an offload alike. Removing the call fails both; moving it inside the
/// offload branch fails the first, and after it the second.
@MainActor
final class Whoop5FrameImuBankingTests: XCTestCase {
    private var rig: ImuBankingRig!

    override func setUp() async throws { rig = ImuBankingRig() }
    override func tearDown() async throws { rig.close() }

    func testALiveBufferIsBanked() {
        rig.manager.feedWhoop5(CollectorImuBankingTests.fixture(type: 43, layout: 21), char: ImuBankingRig.dataChar)
        XCTAssertTrue(rig.banked)
    }

    /// A raw-data session logs the packet type and layout byte of its first live buffer, once (W06-041).
    func testASessionLogsItsFirstLiveBuffersLayout() {
        let line = "Raw-data session: first live 1244-byte buffer is packet type 43, layout 21, intact"
        func count() -> Int { rig.live.log.filter { $0.hasSuffix(line) }.count }
        let buffer = CollectorImuBankingTests.fixture(type: 43, layout: 21)
        rig.manager.feedWhoop5(buffer, char: ImuBankingRig.dataChar)
        XCTAssertEqual(count(), 0, "no session armed")
        XCTAssertTrue(rig.manager.startGroundTruthRawCapture(sessionId: rig.sessionId))
        rig.manager.feedWhoop5(buffer, char: ImuBankingRig.dataChar)
        rig.manager.feedWhoop5(buffer, char: ImuBankingRig.dataChar)
        XCTAssertEqual(count(), 1)
    }

    func testAnOffloadBufferIsBanked() {
        let historical = CollectorImuBankingTests.fixture
        XCTAssertTrue(BLEManager.isOffloadFrame(historical, family: .whoop5), "precondition: routed to the Backfiller")
        rig.manager.handleWhoop5Frame(historical, char: ImuBankingRig.dataChar, offloading: true)
        XCTAssertTrue(rig.banked)
    }
}

/// The Raw Data Collector's IMU session store (W06-025, W06-026).
@MainActor
final class ImuSessionFileStoreTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "imu-session-store-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    }

    private let buffer = CollectorImuBankingTests.fixture

    /// After a relaunch a history sync re-delivers seconds the live stream banked. Each duplicate used to
    /// decode the whole segment file again; the scan is now kept, so the segment is read once.
    func testDuplicatesAfterARelaunchReadTheSegmentOnce() throws {
        let ts = Int64(try XCTUnwrap(Whoop5RawImu.baseTs(buffer)))
        let first = ImuSessionFileStore(directory: directory, defaults: defaults)
        first.start(id: "s", deviceId: "strap", fromMs: (ts - 10) * 1_000)
        XCTAssertEqual(first.append(deviceId: "strap", frame: buffer, receivedAtMs: 0), 1)
        first.complete(id: "s", toMs: (ts + 10) * 1_000)

        final class Reads { var count = 0 }
        let reads = Reads()
        let relaunched = ImuSessionFileStore(directory: directory, defaults: defaults,
                                             read: { reads.count += 1; return try? Data(contentsOf: $0) })
        XCTAssertEqual(relaunched.append(deviceId: "strap", frame: buffer, receivedAtMs: 0), 0)
        let afterOne = reads.count
        for _ in 0..<49 { XCTAssertEqual(relaunched.append(deviceId: "strap", frame: buffer, receivedAtMs: 0), 0) }
        XCTAssertEqual(reads.count, afterOne, "49 more duplicates read no file again")
        XCTAssertEqual(relaunched.stats("s", from: Int(ts) - 10, to: Int(ts) + 10).coveredSeconds, 1)
    }

    /// After a relaunch the newest banked second comes from the session's files (W06-038), even when a sync
    /// first re-delivers an older buffer; a newer buffer moves it on.
    func testTheNewestBankedSecondSurvivesARelaunch() throws {
        let ts = Int64(try XCTUnwrap(Whoop5RawImu.baseTs(buffer)))
        let first = ImuSessionFileStore(directory: directory, defaults: defaults)
        first.start(id: "s", deviceId: "strap", fromMs: (ts - 10) * 1_000)
        first.append(deviceId: "strap", frame: buffer, receivedAtMs: 0)
        first.append(deviceId: "strap", frame: CollectorImuBankingTests.fixture(shiftedBy: 3), receivedAtMs: 0)
        first.prepareForRead("s")

        let relaunched = ImuSessionFileStore(directory: directory, defaults: defaults)
        relaunched.append(deviceId: "strap", frame: CollectorImuBankingTests.fixture(shiftedBy: 1), receivedAtMs: 0)
        XCTAssertEqual(relaunched.newestBankedTs("s"), ts + 3, "the files hold a newer second than the sync's")
        relaunched.append(deviceId: "strap", frame: CollectorImuBankingTests.fixture(shiftedBy: 5), receivedAtMs: 0)
        XCTAssertEqual(relaunched.newestBankedTs("s"), ts + 5)
        XCTAssertNil(ImuSessionFileStore(directory: directory, defaults: defaults).newestBankedTs("none"))
    }

    /// A segment is named for the UTC start of its half hour, on disk and in the export (pinned for W06-047).
    func testSegmentsAreNamedForTheirUTCHalfHour() throws {
        let ts = Int64(try XCTUnwrap(Whoop5RawImu.baseTs(buffer)))
        let store = ImuSessionFileStore(directory: directory, defaults: defaults)
        store.start(id: "s", deviceId: "strap", fromMs: (ts - 10) * 1_000)
        store.append(deviceId: "strap", frame: buffer, receivedAtMs: 0)
        XCTAssertEqual(store.exportSegments("s", from: Int(ts) - 10, to: Int(ts) + 10).map(\.name),
                       ["imu-20260714T133000Z.imus"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("s/imu-20260714T133000Z.imus").path))
    }

    /// The collector waits on this second before it stops the stream (W06-025).
    func testNewestBankedSecondFollowsTheNewestBuffer() throws {
        let ts = Int64(try XCTUnwrap(Whoop5RawImu.baseTs(buffer)))
        let store = ImuSessionFileStore(directory: directory, defaults: defaults)
        store.start(id: "s", deviceId: "strap", fromMs: (ts - 10) * 1_000)
        XCTAssertNil(store.newestBankedTs("s"))
        store.append(deviceId: "strap", frame: CollectorImuBankingTests.fixture(shiftedBy: 2), receivedAtMs: 0)
        store.append(deviceId: "strap", frame: buffer, receivedAtMs: 0)
        XCTAssertEqual(store.newestBankedTs("s"), ts + 2, "a late older buffer does not move it back")
        store.append(deviceId: "other", frame: CollectorImuBankingTests.fixture(shiftedBy: 5), receivedAtMs: 0)
        XCTAssertEqual(store.newestBankedTs("s"), ts + 2, "another strap's buffer is not this session's")
        store.remove(id: "s")
        XCTAssertNil(store.newestBankedTs("s"))
    }
}
