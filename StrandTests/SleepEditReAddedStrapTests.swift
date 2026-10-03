import XCTest
import WhoopStore
@testable import Strand

/// W07-023: after a strap is removed and re-added the registry's active id is `whoop-<uuid>`, so
/// `Repository.computedDeviceId` is `whoop-<uuid>-noop`. The engine still banks every detected night under
/// the canonical `my-whoop-noop`, and an edit of one lands there, so reading edited nights from the active
/// sibling alone found none: the day's totals and Rest kept the detected bounds.
@MainActor
final class SleepEditReAddedStrapTests: XCTestCase {

    func testEditedNightUnderTheCanonicalSiblingReachesScoringOnAReAddedStrap() async throws {
        let store = try await WhoopStore.inMemory()
        let edited = CachedSleepSession(startTs: 1_000_000, endTs: 1_028_800, efficiency: 0.9, restingHr: 52,
                                        avgHrv: 60, stagesJSON: nil, userEdited: true)
        _ = try await store.upsertSleepSessions([edited], deviceId: "my-whoop-noop")

        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        _ = repo.adoptActiveDeviceId("whoop-x")

        let rows = await repo.selfHealEditedStages(from: 900_000, to: 1_100_000)
        XCTAssertEqual(rows.map(\.startTs), [1_000_000])
    }

    /// The active strap's own edited nights are still read, and one night edited under both siblings is
    /// returned once, the active strap's copy winning, as every other computed read does.
    func testActiveSiblingWinsADuplicatedEditedNight() async throws {
        let store = try await WhoopStore.inMemory()
        let canonical = CachedSleepSession(startTs: 1_000_000, endTs: 1_028_800, efficiency: 0.8, restingHr: 52,
                                           avgHrv: 60, stagesJSON: nil, userEdited: true)
        let active = CachedSleepSession(startTs: 1_000_000, endTs: 1_030_000, efficiency: 0.9, restingHr: 52,
                                        avgHrv: 60, stagesJSON: nil, userEdited: true)
        let nap = CachedSleepSession(startTs: 1_050_000, endTs: 1_052_000, efficiency: 0.9, restingHr: 60,
                                     avgHrv: nil, stagesJSON: nil, userEdited: true)
        _ = try await store.upsertSleepSessions([canonical], deviceId: "my-whoop-noop")
        _ = try await store.upsertSleepSessions([active, nap], deviceId: "whoop-x-noop")

        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        _ = repo.adoptActiveDeviceId("whoop-x")

        let rows = await repo.selfHealEditedStages(from: 900_000, to: 1_100_000)
        XCTAssertEqual(rows.map(\.startTs), [1_000_000, 1_050_000])
        XCTAssertEqual(rows.first?.endTs, 1_030_000, "the active strap's copy wins")
    }
}
