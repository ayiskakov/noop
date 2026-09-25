import XCTest
import WhoopProtocol
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

    /// `realBuffer` with bytes 8 and 9 replaced and its CRC32 recomputed, so only the type check can refuse it.
    private func resealed(type: UInt8, layout: UInt8) -> [UInt8] {
        var frame = realBuffer
        frame[8] = type; frame[9] = layout
        let crc = crc32(frame, 8, 1240)
        for i in 0..<4 { frame[1240 + i] = UInt8(truncatingIfNeeded: crc >> (8 * UInt32(i))) }
        XCTAssertTrue(verifyFrame(frame, family: .whoop5).ok, "precondition: an intact frame")
        return frame
    }

    /// W06-029: an intact frame of the same length but another packet type or layout is not an IMU buffer.
    func testOnlyR21BuffersAreBanked() {
        XCTAssertTrue(Collector.isBankableImu(resealed(type: 43, layout: 21)), "live R21")
        XCTAssertFalse(Collector.isBankableImu(resealed(type: 47, layout: 20)), "historical, another layout")
        XCTAssertFalse(Collector.isBankableImu(resealed(type: 52, layout: 21)), "the dedicated IMU stream")
        XCTAssertFalse(Collector.isBankableImu(resealed(type: 0x24, layout: 9)), "a command frame")
    }

    /// W06-002's call site: the 5/MG frame loop hands every frame to the session store before the offload
    /// branch, which `continue`s. Nothing else would fail if the call were removed.
    func testTheFrameLoopBanksBeforeTheOffloadBranch() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Strand/BLE/BLEManager.swift"))
        let loop = try XCTUnwrap(source.range(of: "let completedFrames = reassembler.feed(bytes)"))
        let tail = source[loop.upperBound...]
        let bank = try XCTUnwrap(tail.range(of: "collector?.bankImuForSessions(frame)"))
        let offload = try XCTUnwrap(tail.range(of: "routeBackfillFrame(frame)"))
        XCTAssertLessThan(bank.lowerBound, offload.lowerBound)
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

        let relaunched = ImuSessionFileStore(directory: directory, defaults: defaults)
        for _ in 0..<50 { XCTAssertEqual(relaunched.append(deviceId: "strap", frame: buffer, receivedAtMs: 0), 0) }
        XCTAssertEqual(relaunched.segmentScans, 1)
        XCTAssertEqual(relaunched.stats("s", from: Int(ts) - 10, to: Int(ts) + 10).coveredSeconds, 1)
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
