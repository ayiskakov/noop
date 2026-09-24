import XCTest
import StrandAnalytics
@testable import Strand

/// `PuffinExperiment.sleepStager` is the one resolver every reader of the staging choice goes through. These
/// pin the upgrade from the old V2 on/off switch: nobody who chose V1 is moved to V3 unasked, everyone on
/// the old default gets the new one, and a choice made in the new picker always wins.
final class SleepStagerSettingTests: XCTestCase {

    private let keys = [PuffinExperiment.sleepStagerKey, PuffinExperiment.experimentalSleepV2Key]
    private var saved: [(String, Any?)] = []

    override func setUp() {
        super.setUp()
        saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        for (key, value) in saved {
            if let value { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    func testFreshInstallStagesWithV3() {
        XCTAssertEqual(PuffinExperiment.sleepStager, .v3)
    }

    func testTheOldDefaultMovesToV3() {
        UserDefaults.standard.set(true, forKey: PuffinExperiment.experimentalSleepV2Key)
        XCTAssertEqual(PuffinExperiment.sleepStager, .v3)
    }

    func testAnExplicitV2OffStaysOnV1() {
        UserDefaults.standard.set(false, forKey: PuffinExperiment.experimentalSleepV2Key)
        XCTAssertEqual(PuffinExperiment.sleepStager, .v1)
    }

    func testThePickerWinsOverTheOldSwitch() {
        UserDefaults.standard.set(false, forKey: PuffinExperiment.experimentalSleepV2Key)
        for version in SleepStagerVersion.allCases {
            UserDefaults.standard.set(version.rawValue, forKey: PuffinExperiment.sleepStagerKey)
            XCTAssertEqual(PuffinExperiment.sleepStager, version)
        }
    }

    func testAnUnknownStoredValueFallsBackInsteadOfCrashing() {
        UserDefaults.standard.set("v9", forKey: PuffinExperiment.sleepStagerKey)
        XCTAssertEqual(PuffinExperiment.sleepStager, .v3)
    }
}
