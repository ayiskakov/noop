import XCTest
@testable import Strand
import StrandAnalytics

/// The Healthspan screen's own decisions on top of the persisted rows: the pace band, the 30-day arrow,
/// the biggest lever and the signed years chip.
final class HealthspanReadoutTests: XCTestCase {

    private func driver(_ key: String, years: Double = 0, value: Double, target: Double,
                        recent: Double? = nil) -> HealthspanDriver {
        HealthspanDriver(key: key, years: years, value: value, target: target, recent: recent)
    }

    /// A margin covering 1× is steady whatever the point estimate; otherwise the band follows the pace.
    func testPaceBands() {
        XCTAssertEqual(HealthspanReadout.band(pace: 1.8, margin: 0.9), .steady)
        XCTAssertEqual(HealthspanReadout.band(pace: -0.4, margin: 0.3), .reversing)
        XCTAssertEqual(HealthspanReadout.band(pace: 0.5, margin: 0.3), .slowing)
        XCTAssertEqual(HealthspanReadout.band(pace: 1.6, margin: 0.3), .accelerating)
    }

    /// The arrow knows which way is better for each driver, and stays silent on a change too small to call.
    func testTrendDirection() {
        XCTAssertEqual(HealthspanReadout.trend(driver("rhr", value: 62, target: 60, recent: 58)), .better)
        XCTAssertEqual(HealthspanReadout.trend(driver("steps", value: 6000, target: 8000, recent: 5000)), .worse)
        XCTAssertEqual(HealthspanReadout.trend(driver("sleep", value: 6.2, target: 7, recent: 7.4)), .better)
        XCTAssertEqual(HealthspanReadout.trend(driver("sleep", value: 8, target: 7, recent: 9.8)), .worse)
        XCTAssertNil(HealthspanReadout.trend(driver("steps", value: 8000, target: 8000, recent: 8100)))
        XCTAssertNil(HealthspanReadout.trend(driver("steps", value: 8000, target: 8000)))
    }

    /// The lever is the costliest driver above the floor, and nothing when every driver is close enough.
    func testLever() {
        func snapshot(_ drivers: [HealthspanDriver]) -> HealthspanSnapshot {
            HealthspanSnapshot(day: "2026-09-23", bodyAge: 40, vitality: nil, pace: nil, paceMargin: nil,
                               projectedBodyAge: nil, drivers: drivers, bodyAgeTrend: [], paceTrend: [])
        }
        let s = snapshot([driver("steps", years: 1.4, value: 5000, target: 8000),
                          driver("strength", years: 2.1, value: 0, target: 40),
                          driver("rhr", years: -0.6, value: 52, target: 60)])
        XCTAssertEqual(s.lever?.key, "strength")
        XCTAssertNil(snapshot([driver("steps", years: 0.1, value: 7900, target: 8000)]).lever)
    }

    func testSignedYears() {
        XCTAssertTrue(HealthspanDrivers.years(1.23).hasPrefix("+1.2"))
        XCTAssertTrue(HealthspanDrivers.years(-0.44).hasPrefix("−0.4"))
        XCTAssertTrue(HealthspanDrivers.years(0.01).hasPrefix("0.0"))
        XCTAssertEqual(HealthspanDrivers.formatTarget(driver("sleep", value: 7.5, target: 7)), "7–9 h")
    }
}
