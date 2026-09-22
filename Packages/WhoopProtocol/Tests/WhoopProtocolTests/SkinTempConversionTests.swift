import XCTest
@testable import WhoopProtocol

/// Skin-temp raw→°C conversion.
///
/// The 5/MG v18 historical record banks `skin_temp_raw` (@73) in CENTIDEGREES, so the map is `/100`.
/// It is asserted rather than assumed because the register is a bare integer with no unit on the wire:
/// a conversion that drifts by a factor of ten sends every night below the 28 °C worn gate, and skin
/// temp plus the illness signal silently vanish rather than reading wrong (issue #938).
final class SkinTempConversionTests: XCTestCase {

    /// The proven 5/MG scale: the real Whoop5HistoricalTests captures read worn 3057 = 30.6 °C and
    /// off-wrist 2247 = 22.5 °C — physically right on both ends. This must NOT change.
    func testWhoop5IsCentidegrees() {
        XCTAssertEqual(skinTempCelsius(raw: 3057, family: .whoop5), 30.57, accuracy: 1e-9)
        XCTAssertEqual(skinTempCelsius(raw: 2247, family: .whoop5), 22.47, accuracy: 1e-9)
        XCTAssertEqual(skinTempCelsius(raw: 3400, family: .whoop5), 34.0, accuracy: 1e-9)
    }

    /// A worn night lands inside the plausible worn band (28–42 °C) — the gate every downstream skin-temp
    /// consumer applies — and an off-wrist reading lands below it, so doff samples are excluded from the
    /// nightly mean rather than poisoning it.
    func testWornReadingsClearTheGateAndOffWristDoesNot() {
        for raw in [2850, 3057, 3200, 3400, 4190] {
            let c = skinTempCelsius(raw: raw, family: .whoop5)
            XCTAssertGreaterThanOrEqual(c, 28.0, "worn raw \(raw) → \(c) °C must clear the 28 °C worn gate")
            XCTAssertLessThanOrEqual(c, 42.0, "worn raw \(raw) → \(c) °C must stay under the 42 °C ceiling")
        }
        for raw in [2247, 2500, 2799] {
            XCTAssertLessThan(skinTempCelsius(raw: raw, family: .whoop5), 28.0,
                              "off-wrist raw \(raw) must fall below the worn gate")
        }
    }

    /// The map is exact and linear, with no anchor or offset: 100 raw units is exactly 1 °C everywhere in
    /// the range. A regression that reintroduces an affine correction fails here.
    func testScaleIsExactlyLinearWithNoOffset() {
        for raw in stride(from: 0, through: 5000, by: 137) {
            XCTAssertEqual(skinTempCelsius(raw: raw, family: .whoop5), Double(raw) / 100.0, accuracy: 1e-12)
        }
        XCTAssertEqual(skinTempCelsius(raw: 0, family: .whoop5), 0.0, accuracy: 1e-12)
    }
}
