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
        manager.endLinkForRadioState(.poweredOff, peripheralUUID: "strap-1")
        XCTAssertFalse(live.connected, live.log.joined(separator: "\n"))
        XCTAssertFalse(live.historyReady)
        XCTAssertNil(live.charging)
        XCTAssertFalse(manager.whoop5SessionStarted)
        XCTAssertNotEqual(manager.strapClockCheckToken, token, "a pending clock-check timeout must not outlive the link")
        XCTAssertEqual(lines(containing: "Link ended: Bluetooth off").count, 1)
    }

    func testABluetoothResetEndsAHeldLinkToo() {
        holdALinkPastTheHandshake()
        manager.rebootRequestedAt = .now()
        manager.endLinkForRadioState(.resetting, peripheralUUID: "strap-1")
        XCTAssertFalse(live.connected)
        XCTAssertFalse(manager.whoop5SessionStarted)
        XCTAssertEqual(lines(containing: "Link ended: Bluetooth resetting").count, 1)
        XCTAssertNil(manager.rebootRequestedAt, "a reset closes a reboot trail too (W06-157)")
        XCTAssertEqual(lines(containing: "reboot: link ended by Bluetooth resetting").count, 1)
    }

    /// A launch reports `.unknown` and, on macOS, can report a transient `.unauthorized` (#391) while a restored link
    /// is being re-discovered; neither ends it.
    func testAStateThatDoesNotDropLinksLeavesTheLinkAlone() {
        for radio in [CBManagerState.unknown, .unauthorized, .unsupported] {
            holdALinkPastTheHandshake()
            manager.endLinkForRadioState(radio, peripheralUUID: "strap-1")
            XCTAssertTrue(live.connected, "\(radio.rawValue)")
            XCTAssertTrue(manager.whoop5SessionStarted, "\(radio.rawValue)")
        }
        XCTAssertEqual(lines(containing: "Link ended").count, 0)
    }

    func testAPowerOffWithNoLinkHeldSaysNothing() {
        manager.endLinkForRadioState(.poweredOff, peripheralUUID: "strap-1")
        XCTAssertEqual(lines(containing: "Link ended").count, 0)
    }

    func testASecondPowerOffForTheSameLinkSaysNothing() {
        holdALinkPastTheHandshake()
        manager.endLinkForRadioState(.poweredOff, peripheralUUID: "strap-1")
        manager.endLinkForRadioState(.poweredOff, peripheralUUID: "strap-1")
        XCTAssertEqual(lines(containing: "Link ended").count, 1)
    }

    /// W06-157: a reboot in flight when Bluetooth powers off loses its evidence, since the link ended for the radio's
    /// reason. The trail closes and says so; left armed, the reconnect after power-on is logged as the reboot's round
    /// trip and clears the "Reconnecting…" pill as if the strap had rebooted.
    func testAPowerOffClosesARebootTrailItCannotAttribute() {
        holdALinkPastTheHandshake()
        manager.rebootRequestedAt = .now()
        live.rebootInProgress = true
        manager.endLinkForRadioState(.poweredOff, peripheralUUID: "strap-1")
        XCTAssertNil(manager.rebootRequestedAt, live.log.joined(separator: "\n"))
        XCTAssertFalse(live.rebootInProgress)
        XCTAssertEqual(lines(containing: "reboot: link ended by Bluetooth off").count, 1)
        XCTAssertEqual(lines(containing: "whether the strap rebooted is unknown").count, 1)
    }

    // MARK: - A disconnect after the power-off (W06-147, W06-148)

    private var alreadyEndedLines: Int { lines(containing: "that link already ended at the radio state change").count }
    private var fullDisconnectLines: Int { live.log.filter { $0.hasPrefix("Disconnected") || $0.contains("] Disconnected") }.count - alreadyEndedLines }

    /// A late disconnect for the link the power-off ended is not torn down again: one line says so.
    func testALateDisconnectForTheSameLinkIsNotTornDownTwice() {
        holdALinkPastTheHandshake()
        manager.endLinkForRadioState(.poweredOff, peripheralUUID: "strap-1")
        manager.linkDropped(peripheralUUID: "strap-1", error: nil)
        XCTAssertEqual(alreadyEndedLines, 1, live.log.joined(separator: "\n"))
        XCTAssertEqual(fullDisconnectLines, 0)
    }

    /// W06-148: a disconnect for another peripheral is its own, and runs the handler.
    func testADisconnectForAnotherPeripheralRunsTheHandler() {
        holdALinkPastTheHandshake()
        manager.endLinkForRadioState(.poweredOff, peripheralUUID: "strap-1")
        manager.linkDropped(peripheralUUID: "strap-2", error: nil)
        XCTAssertEqual(alreadyEndedLines, 0, live.log.joined(separator: "\n"))
        XCTAssertEqual(fullDisconnectLines, 1)
    }

    /// W06-148: the user's own Disconnect after a power-off runs its intentional branch.
    func testTheUsersDisconnectAfterAPowerOffRunsItsOwnBranch() {
        holdALinkPastTheHandshake()
        manager.endLinkForRadioState(.poweredOff, peripheralUUID: "strap-1")
        manager.disconnect()
        manager.linkDropped(peripheralUUID: "strap-1", error: nil)
        XCTAssertEqual(alreadyEndedLines, 0, live.log.joined(separator: "\n"))
        XCTAssertEqual(lines(containing: "Disconnected (intentional)").count, 1)
    }

    /// A power-off that held no peripheral swallows nothing.
    func testAPowerOffWithNoPeripheralSwallowsNoDisconnect() {
        holdALinkPastTheHandshake()
        manager.endLinkForRadioState(.poweredOff, peripheralUUID: nil)
        manager.linkDropped(peripheralUUID: "strap-1", error: nil)
        XCTAssertEqual(alreadyEndedLines, 0)
    }

    /// W06-150: a link known only by its uptime clock (the flag not set) still ends, with its epitaph naming the cause.
    func testALinkKnownByItsUptimeEndsWithAnEpitaph() {
        manager.linkUpSince = DispatchTime.now()
        manager.endLinkForRadioState(.poweredOff, peripheralUUID: "strap-1")
        XCTAssertEqual(lines(containing: "Link epitaph:").filter { $0.contains("ended=Bluetooth off") }.count, 1,
                       live.log.joined(separator: "\n"))
        XCTAssertEqual(lines(containing: "Link ended: Bluetooth off").count, 1)
        XCTAssertNil(manager.linkUpSince)
    }
}
