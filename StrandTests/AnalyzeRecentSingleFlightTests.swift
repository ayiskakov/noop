import XCTest
import WhoopStore
@testable import Strand

/// W07-009: `analyzeRecent` checked its `computing` lock, then awaited the store handle and the analysis
/// fingerprint, and only then took the lock, without checking it again. Two calls arriving together both
/// passed the check across those awaits and ran the pass side by side.
@MainActor
final class AnalyzeRecentSingleFlightTests: XCTestCase {
    private let canonical = "my-whoop"

    func testTwoCallsArrivingTogetherRunOnePass() async throws {
        try await withEngineTestPreferences {
            let store = try await WhoopStore.inMemory()
            let repo = Repository(deviceId: canonical)
            repo.setStoreForTesting(store)
            let engine = IntelligenceEngine(repo: repo, profile: ProfileStore(), deviceId: canonical)
            var log: [String] = []
            engine.diagnosticSink = { line, _ in log.append(line) }

            // Not forced: a forced call that finds the lock held re-arms a pass the first one launches from its
            // `defer`, which this test could not await.
            async let first: Void = engine.analyzeRecent(maxDays: 2, force: false)
            async let second: Void = engine.analyzeRecent(maxDays: 2, force: false)
            _ = await (first, second)

            let triggers = log.filter { $0.hasPrefix("re-score: trigger=") }
            XCTAssertEqual(triggers.count, 1, "only one pass may enter: \(log)")
            XCTAssertFalse(log.contains { $0.contains("skipped") }, "the caller that found the lock says no skip: \(log)")
            XCTAssertFalse(engine.computing)
        }
    }

    /// W07-011: a forced call that finds a narrower pass holding the lock is re-run over its own window, not the
    /// running pass's.
    func testAForcedCallQueuedBehindANarrowerPassKeepsItsWindow() async throws {
        try await withEngineTestPreferences {
            let store = try await WhoopStore.inMemory()
            let repo = Repository(deviceId: canonical)
            repo.setStoreForTesting(store)
            let engine = IntelligenceEngine(repo: repo, profile: ProfileStore(), deviceId: canonical)
            var rePasses: [Int] = []
            engine.launchForcedRePass = { rePasses.append($0) }

            let narrow = Task { await engine.analyzeRecent(maxDays: 2, force: false) }
            for _ in 0..<10_000 where !engine.computing { await Task.yield() }
            XCTAssertTrue(engine.computing, "the narrow pass holds the lock")
            await engine.analyzeRecent(maxDays: 40, force: true)
            await narrow.value

            XCTAssertEqual(rePasses, [40])
        }
    }
}
