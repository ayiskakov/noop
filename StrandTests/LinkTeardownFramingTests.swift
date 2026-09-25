import XCTest
import WhoopProtocol
@testable import Strand

/// W06-033: a dropped link takes its reassembler and its reject tally with it. A standing reconnect never
/// runs `connectCore`, which is where both were otherwise rebuilt.
@MainActor
final class LinkTeardownFramingTests: XCTestCase {

    /// Half a buffer carried over from a dropped link swallows the next link's first buffer; after
    /// `resetLinkFraming` that buffer arrives whole and banks (W06-043).
    func testResettingTheFramingSavesTheNextLinksFirstBuffer() {
        let buffer = CollectorImuBankingTests.fixture(type: 43, layout: 21)
        for reset in [false, true] {
            let rig = ImuBankingRig()
            defer { rig.close() }
            rig.manager.feedWhoop5(Array(buffer.prefix(600)), char: ImuBankingRig.dataChar)
            if reset { rig.manager.resetLinkFraming() }
            rig.manager.feedWhoop5(buffer, char: ImuBankingRig.dataChar)
            XCTAssertEqual(rig.banked, reset, reset ? "reset: the buffer banks" : "no reset: the buffer is lost")
        }
    }

    /// Every disconnect runs the reset: the handler calls it at its top level, not under a condition and not
    /// commented out. The handler takes a `CBPeripheral`, which a test cannot make, so this one reads the
    /// source with comments removed.
    func testTheDisconnectHandlerResetsTheFraming() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Strand/BLE/BLEManager.swift"))
        let start = try XCTUnwrap(source.range(of: "didDisconnectPeripheral peripheral: CBPeripheral,"))
        let end = try XCTUnwrap(source.range(of: "\n    public func centralManager(", range: start.upperBound..<source.endIndex))
        let code = source[start.upperBound..<end.lowerBound].split(separator: "\n").map { line in
            line.range(of: "//").map { line[..<$0.lowerBound] } ?? line
        }
        XCTAssertTrue(code.contains("        resetLinkFraming()"))
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
