import XCTest
import CoreBluetooth
@testable import Strand

/// W06-144: when the #617 bond-loop detector trips on a drop, auto-reconnect pauses and a standing connect is parked
/// in the same breath (#1539), so a strap freed while the phone is in a pocket is claimed without an app foreground.
/// The park is refused while `state.connected` is set, so it has to run after the drop clears it.
@MainActor
final class BondLoopParkTests: XCTestCase {
    private var live: LiveState!
    private var manager: BLEManager!

    override func setUp() async throws {
        live = LiveState()
        manager = BLEManager(state: live, deviceId: "rig-\(UUID().uuidString)", collector: nil)
        // Keeps the parked connect off the radio: the connect gate refuses after the park has been decided and logged.
        manager.setWhoopIsActiveDevice(false)
    }

    override func tearDown() async throws {
        manager = nil
        live = nil
    }

    private func lines(containing needle: String) -> [String] { live.log.filter { $0.contains(needle) } }

    /// A link that bonded a moment ago and drops on a connection timeout: the #617 tell.
    private func dropABondedLinkOnATimeout() {
        live.connected = true
        manager.bondedAt = Date()
        manager.linkDropped(peripheralUUID: UUID().uuidString, error: CBError(.connectionTimeout))
    }

    func testTheBondLoopTripParksAStandingConnect() {
        dropABondedLinkOnATimeout()
        dropABondedLinkOnATimeout()
        XCTAssertEqual(lines(containing: "Bond-loop (#617)").count, 1, live.log.joined(separator: "\n"))
        XCTAssertEqual(lines(containing: "parking a standing connect").count, 1)
    }

    func testOneBondedTimeoutParksNothing() {
        dropABondedLinkOnATimeout()
        XCTAssertEqual(lines(containing: "Bond-loop (#617)").count, 0)
        XCTAssertEqual(lines(containing: "parking a standing connect").count, 0)
    }
}
