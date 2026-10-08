import XCTest
import WhoopProtocol
import WhoopStore
@testable import Strand

/// W07-017, W07-033: a data delete that lands while a re-score runs must not be undone by it.
///
/// A pass reads its raw first and writes its scores at the end. A strap or Apple Health delete landing
/// between the two removed the recordings and their computed rows, then the pass wrote back the scores it
/// had computed from what it read before the delete. With no raw left, no later pass could evict them.
/// Every delete now runs through `IntelligenceEngine.withScoringHeld`.
@MainActor
final class DataDeleteDuringRescoreTests: XCTestCase {
    private let canonical = "my-whoop"

    /// A day of heart rate yesterday, one sample a minute, enough for the pass to score the day.
    private func seed(_ store: WhoopStore) async throws {
        let yesterday = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970) - 86_400
        let hr = (0..<1_440).map { i in
            HRSample(ts: yesterday + i * 60, bpm: 70 + Int(sin(Double(i) / 30.0) * 25 + 25))
        }
        try await store.upsertDevice(id: canonical, mac: nil, name: nil)
        _ = try await store.insert(Streams(hr: hr), deviceId: canonical)
    }

    private func engine(_ store: WhoopStore) -> IntelligenceEngine {
        let repo = Repository(deviceId: canonical)
        repo.setStoreForTesting(store)
        return IntelligenceEngine(repo: repo, profile: ProfileStore(), deviceId: canonical)
    }

    /// The delete lands between the pass's day scan and its first write, the window of the bug.
    func testADeleteBetweenTheScanAndTheWritesLeavesNoScores() async throws {
        try await withEngineTestPreferences {
            let store = try await WhoopStore.inMemory()
            try await seed(store)
            let engine = engine(store)
            var log: [String] = []
            engine.diagnosticSink = { line, _ in log.append(line) }
            var rescored: [Int] = []
            engine.launchRescoreAfterDataDelete = { rescored.append($0) }
            var deleteRanDuringPass: Bool?
            var delete: Task<Void, Never>?
            engine.scanFinishedForTesting = {
                engine.scanFinishedForTesting = nil
                delete = Task {
                    await engine.withScoringHeld {
                        deleteRanDuringPass = engine.computing
                        try? await store.deleteAllData(deviceId: self.canonical)
                    }
                }
                for _ in 0..<10_000 where !engine.isScoringHeldForDataDelete { await Task.yield() }
            }

            await engine.analyzeRecent(maxDays: 3, force: true)
            await delete?.value

            let days = try await store.dailyMetrics(deviceId: canonical + "-noop", from: "0000-01-01", to: "9999-12-31")
            XCTAssertEqual(days.map(\.day), [], "the pass wrote back scores computed from deleted recordings")
            XCTAssertEqual(deleteRanDuringPass, false, "the delete must wait for the pass to release the lock")
            XCTAssertTrue(log.contains { $0.hasPrefix("re-score: dropped after the day scan") }, "\(log)")
            XCTAssertEqual(rescored, [21], "one re-score after the delete")
            XCTAssertFalse(engine.isScoringHeldForDataDelete)
        }
    }

    /// With no pass running the delete runs at once and is followed by the re-score.
    func testADeleteWithNoPassRunningRunsAtOnceAndRescores() async throws {
        try await withEngineTestPreferences {
            let store = try await WhoopStore.inMemory()
            let engine = engine(store)
            var rescored: [Int] = []
            engine.launchRescoreAfterDataDelete = { rescored.append($0) }
            var ran = false
            await engine.withScoringHeld { ran = true }
            XCTAssertTrue(ran)
            XCTAssertEqual(rescored, [21])
        }
    }

    /// A forced trigger arriving during a delete starts no pass; the delete's re-score covers its window.
    func testAForcedTriggerDuringADeleteIsFoldedIntoItsRescore() async throws {
        try await withEngineTestPreferences {
            let store = try await WhoopStore.inMemory()
            try await seed(store)
            let engine = engine(store)
            var log: [String] = []
            engine.diagnosticSink = { line, _ in log.append(line) }
            var rescored: [Int] = []
            engine.launchRescoreAfterDataDelete = { rescored.append($0) }
            var rePasses: [Int] = []
            engine.launchForcedRePass = { rePasses.append($0) }

            await engine.withScoringHeld {
                await engine.analyzeRecent(maxDays: 40, force: true)
                XCTAssertFalse(engine.computing, "no pass may start while a delete runs")
            }

            XCTAssertEqual(rescored, [40])
            XCTAssertEqual(rePasses, [])
            XCTAssertFalse(log.contains { $0.hasPrefix("re-score: trigger=") }, "\(log)")
            XCTAssertTrue(log.contains { $0.hasPrefix("re-score: held until a data delete finishes") }, "\(log)")
        }
    }
}
