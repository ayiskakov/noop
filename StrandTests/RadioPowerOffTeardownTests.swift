import XCTest
import CoreBluetooth
@testable import Strand

/// W06-083: CoreBluetooth on iOS sends no `didDisconnectPeripheral` when Bluetooth powers off, so the radio state
/// change is where the link ends. These pin that a power-off or a reset ends a held link as a disconnect does, that
/// the next link runs the 5/MG handshake again, and that a state change with no link held, or a second one for the
/// same link, changes nothing.
@MainActor
final class RadioPowerOffTeardownTests: XCTestCase {
    private var live: LiveState!
    private var manager: BLEManager!

    override func setUp() async throws {
        live = LiveState()
        manager = BLEManager(state: live, deviceId: "rig-\(UUID().uuidString)", collector: nil)
    }

    override func tearDown() async throws {
        manager = nil
        live = nil
    }

    private func lines(containing needle: String) -> [String] { live.log.filter { $0.contains(needle) } }

    /// What a 5/MG link past its handshake leaves set, as far as a test can set it without a strap.
    private func holdALinkPastTheHandshake() {
        live.connected = true
        live.historyReady = true
        live.charging = true
        manager.whoop5SessionStarted = true
    }

    func testAPowerOffEndsAHeldLinkSoTheNextOneRunsTheHandshake() {
        holdALinkPastTheHandshake()
        let token = manager.strapClockCheckToken
        manager.endLinkForRadioState(.poweredOff)
        XCTAssertFalse(live.connected, live.log.joined(separator: "\n"))
        XCTAssertFalse(live.historyReady)
        XCTAssertNil(live.charging)
        XCTAssertFalse(manager.whoop5SessionStarted)
        XCTAssertNotEqual(manager.strapClockCheckToken, token, "a pending clock-check timeout must not outlive the link")
        XCTAssertEqual(lines(containing: "Link ended: Bluetooth off").count, 1)
    }

    func testABluetoothResetEndsAHeldLinkToo() {
        holdALinkPastTheHandshake()
        manager.endLinkForRadioState(.resetting)
        XCTAssertFalse(live.connected)
        XCTAssertFalse(manager.whoop5SessionStarted)
        XCTAssertEqual(lines(containing: "Link ended: Bluetooth resetting").count, 1)
    }

    /// A launch reports `.unknown` and, on macOS, can report a transient `.unauthorized` (#391) while a restored link
    /// is being re-discovered; neither ends it.
    func testAStateThatDoesNotDropLinksLeavesTheLinkAlone() {
        for radio in [CBManagerState.unknown, .unauthorized, .unsupported] {
            holdALinkPastTheHandshake()
            manager.endLinkForRadioState(radio)
            XCTAssertTrue(live.connected, "\(radio.rawValue)")
            XCTAssertTrue(manager.whoop5SessionStarted, "\(radio.rawValue)")
        }
        XCTAssertEqual(lines(containing: "Link ended").count, 0)
    }

    func testAPowerOffWithNoLinkHeldSaysNothing() {
        manager.endLinkForRadioState(.poweredOff)
        XCTAssertEqual(lines(containing: "Link ended").count, 0)
    }

    func testASecondPowerOffForTheSameLinkSaysNothing() {
        holdALinkPastTheHandshake()
        manager.endLinkForRadioState(.poweredOff)
        manager.endLinkForRadioState(.poweredOff)
        XCTAssertEqual(lines(containing: "Link ended").count, 1)
    }
}
