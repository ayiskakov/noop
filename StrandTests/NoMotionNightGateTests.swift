import XCTest
import StrandAnalytics
@testable import Strand

/// W03-052: a day with no motion takes its night from the owner's stored sessions only when one of them is
/// that day's night.
///
/// The gate read the owner's stored sessions over the whole sleep read and skipped the HR-only night
/// (#1801) whenever any were there. `analyzeDay` keeps only a session that ENDS on the day, and the read
/// runs from 30 h before the day to 12 h past it (W03-024), so a stored night of the day before or the day
/// after blocked a day that had none of its own: it scored no night at all.
final class NoMotionNightGateTests: XCTestCase {
    /// Local midnight (tz 0) that starts `day`.
    private let midnight = 1_700_006_400
    private var day: String { AnalyticsEngine.dayString(midnight, offsetSec: 0) }

    private func night(_ start: Int, _ end: Int) -> SleepSession {
        SleepSession(start: start, end: end, efficiency: 0.9,
                     stages: [StageSegment(start: start, end: end, stage: "light")], restingHR: nil, avgHRV: nil)
    }

    private func gate(_ owner: String, _ stored: [SleepSession], tz: Int = 0)
        -> (source: IntelligenceEngine.NoMotionNight, storedNights: Int) {
        IntelligenceEngine.noMotionNight(owner: owner, stored: stored, day: day, tzOffsetSeconds: tz)
    }

    /// The next night starts after midnight, inside the day's read, and ends on the day after.
    func testTheNextNightDoesNotBlockTheDaysHrOnlyNight() {
        let next = night(midnight + 86_400 + 3600, midnight + 86_400 + 8 * 3600)
        XCTAssertEqual(gate(Repository.whoopSource, [next]).source, .hrOnly)
        XCTAssertEqual(gate("oura-ring", [next]).source, .hrOnly)
    }

    /// The previous night ended on the day before, inside the read's 30 h lookback.
    func testThePreviousNightDoesNotBlockTheDaysHrOnlyNight() {
        let previous = night(midnight - 86_400 - 3600, midnight - 86_400 + 7 * 3600)
        XCTAssertEqual(gate(Repository.whoopSource, [previous]).source, .hrOnly)
    }

    /// A stored night ending on the day decides it, as before, and only the day's nights are counted.
    func testAStoredNightEndingOnTheDayDecidesIt() {
        let own = night(midnight - 3600, midnight + 7 * 3600)
        let next = night(midnight + 86_400 + 3600, midnight + 86_400 + 8 * 3600)
        let imported = gate(Repository.whoopSource, [own, next])
        XCTAssertEqual(imported.source, .storedSessionsExist)
        XCTAssertEqual(imported.storedNights, 1)
        XCTAssertEqual(gate("oura-ring", [own, next]).source, .storedHypnogram)
        XCTAssertEqual(gate(Repository.whoopSource, []).source, .hrOnly)
    }

    /// Day membership is `analyzeDay`'s: the session's end in the day under the pass's offset.
    func testDayMembershipFollowsTheOffset() {
        // Ends 23:00 UTC the day before; at UTC+2 that is 01:00 on the day.
        let late = night(midnight - 8 * 3600, midnight - 3600)
        XCTAssertEqual(gate(Repository.whoopSource, [late], tz: 0).source, .hrOnly)
        XCTAssertEqual(gate(Repository.whoopSource, [late], tz: 2 * 3600).source, .storedSessionsExist)
    }
}
