import Combine
import XCTest
@testable import Strand

/// Pins last-sync attribution. Kotlin twin: `LastSyncAttributionTest`.
///
/// Reported three times before it was believed, which is the part worth keeping: the number was
/// plausible, so the reading was treated as mistaken rather than the label. The capture had
/// "Last sync: 4d ago" beside zero banked rows for the active 5/MG, and a 4.0 last seen three days
/// earlier — the timestamp on the 5/MG's screen belonged to the other strap.
final class LastSyncAttributionTests: XCTestCase {

    func testThisStrapsOwnStampAlwaysWins() {
        XCTAssertEqual(LastSyncAttribution.resolve(perDevice: 500, legacyGlobal: 900, pairedCount: 1), 500)
        XCTAssertEqual(LastSyncAttribution.resolve(perDevice: 500, legacyGlobal: 900, pairedCount: 3), 500)
    }

    /// The single-strap upgrade path. The global key is unattributed, but with one strap paired there is
    /// only one strap it can have come from — so it reads correctly across the upgrade instead of
    /// resetting to "never" for everyone.
    func testTheLegacyGlobalIsHonouredOnlyWhenOneStrapCouldHaveWrittenIt() {
        XCTAssertEqual(LastSyncAttribution.resolve(perDevice: nil, legacyGlobal: 900, pairedCount: 1), 900)
        XCTAssertNil(LastSyncAttribution.resolve(perDevice: nil, legacyGlobal: 900, pairedCount: 2))
    }

    /// THE case from the capture. Two straps, and the active one has never synced: the honest answer is
    /// "never", not the other strap's timestamp. Not a degraded answer — the correct one.
    func testAStrapThatHasNeverSyncedSaysSoEvenWhenAnotherHas() {
        XCTAssertNil(LastSyncAttribution.resolve(perDevice: nil, legacyGlobal: 1_787_000_000, pairedCount: 2))
    }

    /// Zero is "never recorded", not a timestamp — the defaults API returns 0.0 for a missing Double, so
    /// treating it as a value would date every strap to 1970.
    func testZeroAndNilAreBothAbsent() {
        XCTAssertNil(LastSyncAttribution.resolve(perDevice: 0, legacyGlobal: 0, pairedCount: 1))
        XCTAssertNil(LastSyncAttribution.resolve(perDevice: nil, legacyGlobal: nil, pairedCount: 1))
        XCTAssertEqual(LastSyncAttribution.resolve(perDevice: 0, legacyGlobal: 900, pairedCount: 1), 900)
    }

    /// A zero-paired registry must not license the global. The count is the evidence that exactly one
    /// strap could have written it; "no straps" is not that evidence, and treating it as such would let a
    /// failed registry read resurrect the bug.
    func testAnEmptyRegistryDoesNotLicenseTheGlobal() {
        XCTAssertNil(LastSyncAttribution.resolve(perDevice: nil, legacyGlobal: 900, pairedCount: 0))
    }

    func testThePrefKeyIsPerDeviceAndCaseInsensitive() {
        XCTAssertEqual(LastSyncAttribution.prefKey(peripheralId: "F1:D4:F7:24:53:DE"),
                       "noop.lastSyncAt.f1:d4:f7:24:53:de")
        XCTAssertEqual(LastSyncAttribution.prefKey(peripheralId: "f1:d4:f7:24:53:de"),
                       LastSyncAttribution.prefKey(peripheralId: "F1:D4:F7:24:53:DE"))
        XCTAssertNil(LastSyncAttribution.prefKey(peripheralId: nil))
        XCTAssertNil(LastSyncAttribution.prefKey(peripheralId: "   "))
    }

    /// It must not collide with the firmware key, which is built the same way from the same identifier.
    func testItDoesNotCollideWithTheFirmwareKeyForTheSameStrap() {
        let id = "f1:d4:f7:24:53:de"
        XCTAssertNotEqual(LastSyncAttribution.prefKey(peripheralId: id),
                          FirmwareAttribution.prefKey(peripheralId: id))
    }

    /// The #57 write-health pair had the identical defect one line below in the same capture: "rows last
    /// landed 4d ago" against a strap whose own row count was zero. Both halves are scoped, because they
    /// are read as a pair — "stalled more recently than ok" is the alarm — and scoping only one would
    /// compare this strap's stall against another strap's success.
    func testTheWriteHealthPairIsScopedAndItsHalvesStayDistinct() {
        let id = "f1:d4:f7:24:53:de"
        XCTAssertEqual(LastSyncAttribution.writeHealthPrefKey(peripheralId: id, kind: "lastWriteOkAt"),
                       "sync.lastWriteOkAt.f1:d4:f7:24:53:de")
        XCTAssertNotEqual(LastSyncAttribution.writeHealthPrefKey(peripheralId: id, kind: "lastWriteOkAt"),
                          LastSyncAttribution.writeHealthPrefKey(peripheralId: id, kind: "lastWriteStalledAt"))
        XCTAssertNil(LastSyncAttribution.writeHealthPrefKey(peripheralId: nil, kind: "lastWriteOkAt"))
        XCTAssertNil(LastSyncAttribution.writeHealthPrefKey(peripheralId: "  ", kind: "lastWriteOkAt"))
    }

    /// Two straps must never share a write-health key, or one strap's successful offload would clear the
    /// alarm raised by another strap's stall.
    func testTwoStrapsGetDifferentWriteHealthKeys() {
        XCTAssertNotEqual(
            LastSyncAttribution.writeHealthPrefKey(peripheralId: "aa:bb:cc:dd:ee:ff", kind: "lastWriteOkAt"),
            LastSyncAttribution.writeHealthPrefKey(peripheralId: "ff:ee:dd:cc:bb:aa", kind: "lastWriteOkAt"))
    }

    // MARK: - W07-016: the launch seed is not a completed sync

    /// The launch seed publishes a persisted time; the log may not call the refresh it causes a sync.
    @MainActor
    func testTheLaunchSeedIsAttributedToThePersistedTime() {
        let live = LiveState()
        XCTAssertNil(live.lastSyncedAtOrigin)
        live.seedLastSynced(1_790_000_000)
        XCTAssertEqual(live.lastSyncedAt, 1_790_000_000)
        XCTAssertEqual(live.lastSyncedAtOrigin, .persisted)
    }

    /// A HISTORY_COMPLETE after the seed re-attributes the value, and one before it is not overwritten by
    /// the seed: in both orders the value and its origin are the completed sync's.
    @MainActor
    func testACompletedSyncWinsOverTheSeedInEitherOrder() {
        let seededFirst = LiveState()
        seededFirst.seedLastSynced(1_790_000_000)
        seededFirst.stampCompletedSync(at: 1_790_000_900)
        XCTAssertEqual(seededFirst.lastSyncedAt, 1_790_000_900)
        XCTAssertEqual(seededFirst.lastSyncedAtOrigin, .completedSync)

        let syncedFirst = LiveState()
        syncedFirst.stampCompletedSync(at: 1_790_000_900)
        syncedFirst.seedLastSynced(1_790_000_000)
        XCTAssertEqual(syncedFirst.lastSyncedAt, 1_790_000_900)
        XCTAssertEqual(syncedFirst.lastSyncedAtOrigin, .completedSync)
    }

    /// The origin is set before the value, so a `$lastSyncedAt` subscriber reads the origin of the value
    /// it is being handed (`@Published` emits in willSet).
    @MainActor
    func testASubscriberReadsTheOriginOfTheValueItIsHanded() {
        let live = LiveState()
        var seen: [LastSyncOrigin?] = []
        let c = live.$lastSyncedAt.dropFirst().sink { _ in seen.append(live.lastSyncedAtOrigin) }
        live.seedLastSynced(1_790_000_000)
        live.stampCompletedSync(at: 1_790_000_900)
        c.cancel()
        XCTAssertEqual(seen, [.persisted, .completedSync])
    }

    /// The completed-sync strings are the ones logs have always carried; the seed gets its own, and its
    /// re-score is not labelled `post-offload`.
    func testOnlyACompletedSyncIsLoggedAsOne() {
        XCTAssertEqual(LastSyncOrigin.completedSync.refreshLogLine,
                       "Backfill: refreshing dashboard cache from completed sync")
        XCTAssertNil(LastSyncOrigin.completedSync.rescoreTriggerLabel)
        XCTAssertFalse(LastSyncOrigin.persisted.refreshLogLine.contains("completed sync"))
        XCTAssertEqual(LastSyncOrigin.persisted.rescoreTriggerLabel, "launch-seed")
    }

    /// W07-044: a value with no recorded writer is reported as unattributed, never as a completed sync.
    func testAnUnrecordedOriginIsNotLoggedAsACompletedSync() {
        XCTAssertEqual(LastSyncOrigin.observed(nil), .unattributed)
        XCTAssertEqual(LastSyncOrigin.observed(.completedSync), .completedSync)
        XCTAssertFalse(LastSyncOrigin.unattributed.refreshLogLine.contains("completed sync"))
        XCTAssertEqual(LastSyncOrigin.unattributed.rescoreTriggerLabel, "last-sync-unattributed")
    }
}
