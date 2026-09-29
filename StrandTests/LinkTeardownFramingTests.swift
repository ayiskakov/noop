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

    /// A disconnect runs the reset, driven through the handler's body (`linkDropped`, W06-147) rather than read from
    /// the source, so an early return added before the teardown fails it (W06-162): half a buffer before the drop,
    /// and the next link's first buffer still banks. The one early return there is, for a link a power-off already
    /// tore down, is covered by `RadioPowerOffTeardownTests`.
    func testTheDisconnectHandlerResetsTheFraming() {
        let buffer = CollectorImuBankingTests.fixture(type: 43, layout: 21)
        let rig = ImuBankingRig()
        defer { rig.close() }
        rig.manager.feedWhoop5(Array(buffer.prefix(600)), char: ImuBankingRig.dataChar)
        rig.manager.linkDropped(peripheralUUID: "strap-1", error: nil)
        rig.manager.feedWhoop5(buffer, char: ImuBankingRig.dataChar)
        XCTAssertTrue(rig.banked, rig.live.log.joined(separator: "\n"))
    }

    /// The radio state change reaches the power-off teardown first thing when the radio is not powered on (W06-083).
    /// A test cannot make a `CBCentralManager` report a state, so this one reads the source.
    func testTheRadioStateChangeReachesThePowerOffTeardown() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Strand/BLE/BLEManager.swift"))
        let delegate = try XCTUnwrap(source.range(of: "public func centralManagerDidUpdateState(_ central: CBCentralManager) {"))
        let guardLine = try XCTUnwrap(source.range(of: "        guard central.state == .poweredOn else {\n",
                                                   range: delegate.upperBound..<source.endIndex))
        let next = source[guardLine.upperBound...].prefix { $0 != "\n" }
        XCTAssertEqual(next, "            endLinkForRadioState(central.state, peripheralUUID: peripheral?.identifier.uuidString)")
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
