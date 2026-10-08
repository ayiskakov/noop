import XCTest
import WhoopStore
import WhoopProtocol
import StrandAnalytics
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
    /// returned once to scoring, the active strap's copy winning (the Sleep tab's union keeps both copies,
    /// which is the display's question, not scoring's).
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

    private func registry(_ store: WhoopStore, _ ids: [(String, DeviceStatus)]) throws {
        let reg = DeviceRegistryStore(dbQueue: store.registryWriter)
        for (id, status) in ids {
            try reg.add(PairedDevice(id: id, brand: "WHOOP", model: "WHOOP 5.0 / MG", sourceKind: .liveBLE,
                                     capabilities: [.hr, .sleep], status: status, addedAt: 1, lastSeenAt: 1))
        }
    }

    /// Dense still gravity and calm HR over [start, end], one sample a minute.
    private func night(_ start: Int, _ end: Int) -> Streams {
        let ts = Array(stride(from: start, through: end, by: 60))
        return Streams(hr: ts.map { HRSample(ts: $0, bpm: 50) },
                       gravity: ts.map { GravitySample(ts: $0, x: 0, y: 0, z: 1) })
    }

    /// W07-041: two re-adds later, a nap logged under the first re-added strap's sibling is still a night the
    /// Sleep tab shows (it reads every registered strap's computed sibling), so scoring must read it too.
    func testAnEditedNightUnderAnEarlierReAddedStrapReachesScoring() async throws {
        let store = try await WhoopStore.inMemory()
        try registry(store, [("whoop-old", .archived), ("whoop-new", .active)])
        let nap = CachedSleepSession(startTs: 1_000_000, endTs: 1_005_400, efficiency: 0.9, restingHr: 55,
                                     avgHrv: nil, stagesJSON: nil, userEdited: true)
        _ = try await store.upsertSleepSessions([nap], deviceId: "whoop-old-noop")
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        _ = repo.adoptActiveDeviceId("whoop-new")

        let rows = await repo.selfHealEditedStages(from: 900_000, to: 1_100_000)
        XCTAssertEqual(rows.map(\.startTs), [1_000_000])
    }

    /// W07-042: a night edited under two siblings is healed in both, so the copy that does not win scoring
    /// does not go stale while the Sleep tab still shows it.
    func testEveryEditedCopyIsHealed() async throws {
        let store = try await WhoopStore.inMemory()
        try registry(store, [("whoop-x", .active)])
        let start = 1_000_000, end = 1_028_800
        _ = try await store.insert(night(start - 3_600, end + 3_600), deviceId: "whoop-x")
        for id in ["my-whoop-noop", "whoop-x-noop"] {
            _ = try await store.upsertSleepSessions([CachedSleepSession(startTs: start, endTs: end, efficiency: 0.9,
                                                                        restingHr: 50, avgHrv: nil, stagesJSON: nil,
                                                                        userEdited: true)], deviceId: id)
        }
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        _ = repo.adoptActiveDeviceId("whoop-x")

        _ = await repo.selfHealEditedStages(from: start - 100, to: end + 100)
        for id in ["my-whoop-noop", "whoop-x-noop"] {
            let row = try await store.sleepSessions(deviceId: id, from: start - 100, to: end + 100, limit: 10).first
            XCTAssertNotNil(row?.stagesJSON, "the copy under \(id) was not healed")
        }
    }

    /// W07-043: a canonical night the old strap recorded is re-staged from the old strap's raw, not left
    /// alone because the active strap holds none (and never overwritten from the active strap's sparse raw).
    func testACanonicalNightIsRestagedFromTheStrapThatRecordedIt() async throws {
        let store = try await WhoopStore.inMemory()
        try registry(store, [("whoop-x", .active)])
        let start = 1_000_000, end = 1_028_800
        _ = try await store.insert(night(start - 3_600, end + 3_600), deviceId: "my-whoop")
        _ = try await store.insert(Streams(hr: [HRSample(ts: start + 600, bpm: 90)],
                                           gravity: stride(from: start, through: start + 30 * 120, by: 120)
                                            .map { GravitySample(ts: $0, x: 0.3, y: 0, z: 0.9) }),
                                   deviceId: "whoop-x")
        _ = try await store.upsertSleepSessions([CachedSleepSession(startTs: start, endTs: end, efficiency: 0.9,
                                                                    restingHr: 50, avgHrv: nil, stagesJSON: nil,
                                                                    userEdited: true)], deviceId: "my-whoop-noop")
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        _ = repo.adoptActiveDeviceId("whoop-x")

        let rows = await repo.selfHealEditedStages(from: start - 100, to: end + 100)
        let stages = AnalyticsEngine.decodeStages(rows.first?.stagesJSON)
        XCTAssertFalse(stages.isEmpty, "the night was not re-staged from the strap that recorded it")
        XCTAssertFalse(stages.contains { $0.stage == "wake" && $0.end - $0.start > 3_600 },
                       "the night was staged from the active strap's sparse, moving raw")
    }
}
