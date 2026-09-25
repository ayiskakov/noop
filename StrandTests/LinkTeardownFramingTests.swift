import XCTest
import WhoopProtocol
@testable import Strand

/// W06-033: a dropped link takes its reassembler and its reject tally with it. A standing reconnect never
/// runs `connectCore`, which is where both were otherwise rebuilt.
@MainActor
final class LinkTeardownFramingTests: XCTestCase {

    /// The disconnect handler rebuilds the reassembler and resets the tally.
    func testTheDisconnectHandlerRebuildsTheLinkFraming() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Strand/BLE/BLEManager.swift"))
        let start = try XCTUnwrap(source.range(of: "didDisconnectPeripheral peripheral: CBPeripheral,"))
        let end = try XCTUnwrap(source.range(of: "\n    public func centralManager(", range: start.upperBound..<source.endIndex))
        let handler = source[start.upperBound..<end.lowerBound]
        XCTAssertTrue(handler.contains("reassembler = Reassembler(family: selectedModel.deviceFamily)"))
        XCTAssertTrue(handler.contains("router.resetLinkTally()"))
    }

    /// The tally folds a reassembler's drops as growth past the total it last saw, so a fresh reassembler
    /// without a fresh tally would hide the next link's drops until they passed the old total.
    func testAResetTallyCountsAFreshReassemblersDrops() {
        let router = FrameRouter(state: LiveState())
        router.noteReassemblerHeaderDrops(5)
        XCTAssertEqual(router.rejectTally.count(.headerChecksumMismatch), 5)

        router.resetLinkTally()
        XCTAssertEqual(router.rejectTally.totalRejected, 0)
        router.noteReassemblerHeaderDrops(2)
        XCTAssertEqual(router.rejectTally.count(.headerChecksumMismatch), 2)
    }
}
