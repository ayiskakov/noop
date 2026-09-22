import XCTest
@testable import StrandAnalytics

final class StrengthActivityTests: XCTestCase {

    /// Every spelling the app can actually produce resolves through the one resolver: NOOP's own catalog
    /// entry, the HealthKit workout names, and the WHOOP export variants.
    func testRecognisesEverySpellingInUse() {
        for sport in ["Weightlifting", "weightlifting", "  Weight Training ", "Strength",
                      "Functional Strength Training", "Traditional Strength Training",
                      "Resistance Training", "Powerlifting", "CrossFit", "Calisthenics"] {
            XCTAssertTrue(StrengthActivity.isStrengthSport(sport), sport)
        }
    }

    func testRejectsNonStrengthSports() {
        for sport in ["Running", "Cycling", "Yoga", "Walking", "Swimming", ""] {
            XCTAssertFalse(StrengthActivity.isStrengthSport(sport), sport)
        }
    }

    /// The substring rule the WHOOP CSV importer has always used still holds, so unifying the two callers
    /// cannot reclassify a day a user already has on disk.
    func testKeepsTheImporterSubstringRule() {
        for name in ["Strength Workout", "Olympic Weightlifting", "weighted carries", "Body Weight"] {
            XCTAssertTrue(StrengthActivity.isStrengthSport(name), name)
        }
    }

    func testClassifierVerdict() {
        XCTAssertTrue(StrengthActivity.isStrengthClass(.strength))
        XCTAssertFalse(StrengthActivity.isStrengthClass(.run))
        XCTAssertFalse(StrengthActivity.isStrengthClass(.other))
    }

    /// A session left running overnight, or an import with a wrong end timestamp, must not move a Body Age.
    func testSessionMinutesAreCappedAndNonPositiveDropped() {
        XCTAssertEqual(StrengthActivity.weeklyMinutes(sessionMinutes: [45, 50]), 95, accuracy: 1e-9)
        XCTAssertEqual(StrengthActivity.weeklyMinutes(sessionMinutes: [45, -10, 0]), 45, accuracy: 1e-9)
        XCTAssertEqual(StrengthActivity.weeklyMinutes(sessionMinutes: [3000]),
                       StrengthActivity.maxMinutesPerSession, accuracy: 1e-9)
        XCTAssertEqual(StrengthActivity.weeklyMinutes(sessionMinutes: []), 0, accuracy: 1e-9)
    }
}
