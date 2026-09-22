import XCTest
@testable import Strand
import WhoopProtocol

/// #769: the Breathe / biofeedback teardown clears an in-progress strap haptic pattern with STOP_HAPTICS
/// (cmd 122) so a pattern the strap is mid-way through can't wedge its haptic manager when the link drops.
/// The send itself is gated in BLEManager (no-op when not connected, and SKIPPED on a 5/MG since cmd 122
/// isn't confirmed on its 0x13 haptics path), so what is left to pin is the opcode the documented clear
/// stands on.
final class StopHapticsCommandTests: XCTestCase {

    /// STOP_HAPTICS is on-wire command 122 (the documented stop-haptics opcode).
    func testStopHapticsRawValueIs122() {
        XCTAssertEqual(WhoopCommand.stopHaptics.rawValue, 122)
    }

}
