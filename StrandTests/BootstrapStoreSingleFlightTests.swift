import XCTest
import WhoopStore
@testable import Strand

/// W06-014: `bootstrapStore` checked `collector == nil` and then awaited the store open, so two callers that
/// arrive together (an iOS state-restoration relaunch runs both `willRestoreState` and `poweredOn`) could both
/// pass the check. Each opened a store and built its own Collector and Backfiller, and the second replaced the
/// first: buffered HR in the first Collector was dropped, and an offload the first Backfiller was running could
/// be ended, or its END acked from an empty chunk.
@MainActor
final class BootstrapStoreSingleFlightTests: XCTestCase {
    private let replayKey = "rejectArchiveReplayedAppVersion"
    private var savedReplay: Any?
    private var live: LiveState!
    private var manager: BLEManager!
    private var opens = 0

    override func setUp() async throws {
        // The bootstrap replays the reject archive once per app version and then stamps this key. Stamped
        // up front, so the test reads no archive of the host's and leaves the host's key as it found it.
        savedReplay = UserDefaults.standard.object(forKey: replayKey)
        UserDefaults.standard.set(AppChangelog.currentVersion, forKey: replayKey)
        live = LiveState()
        manager = BLEManager(state: live, deviceId: "rig-\(UUID().uuidString)", collector: nil)
        opens = 0
        manager.bootstrapStorePath = { "/unused/w06-014.sqlite" }
        manager.bootstrapOpenStore = { [weak self] _ in
            self?.opens += 1
            // Hold the open long enough for a second caller to arrive, as the real file open does.
            try await Task.sleep(nanoseconds: 50_000_000)
            return try await WhoopStore.inMemory()
        }
    }

    override func tearDown() async throws {
        if let savedReplay { UserDefaults.standard.set(savedReplay, forKey: replayKey) }
        else { UserDefaults.standard.removeObject(forKey: replayKey) }
        manager = nil
        live = nil
    }

    func testTwoCallersArrivingTogetherOpenOneStore() async {
        async let restore: Void = manager.bootstrapStore()
        async let poweredOn: Void = manager.bootstrapStore()
        _ = await (restore, poweredOn)
        XCTAssertEqual(opens, 1, "a second caller must wait for the bootstrap in flight, not open another store")
        XCTAssertTrue(manager.storeBootstrapped)
    }

    func testTheWaitingCallerReturnsWithTheStoreReady() async {
        // The restore path adopts the strap's identity right after its await, which needs the registry the
        // bootstrap builds, so the caller that waited must not return before the bootstrap it waited on.
        let first = Task { await manager.bootstrapStore() }
        await Task.yield()
        await manager.bootstrapStore()
        XCTAssertTrue(manager.storeBootstrapped, "the waiting caller returned before the store was ready")
        await first.value
        XCTAssertEqual(opens, 1)
        // At least once, not exactly: the manager's real CBCentralManager can report poweredOn inside the open's
        // window, and that path calls `bootstrapStore()` too, which waits and says so as well.
        XCTAssertGreaterThanOrEqual(live.log.filter { $0.contains("Backfill: bootstrap already in flight") }.count, 1,
                                    live.log.joined(separator: "\n"))
    }

    func testAFailedBootstrapIsRetriedByTheNextCaller() async {
        // #222: a locked iPhone fails the first open, and the next backfill tick retries. Single-flight must
        // not turn that failure into a permanent no-op.
        var fail = true
        manager.bootstrapOpenStore = { [weak self] _ in
            self?.opens += 1
            if fail { fail = false; throw CocoaError(.fileReadNoPermission) }
            return try await WhoopStore.inMemory()
        }
        await manager.bootstrapStore()
        XCTAssertFalse(manager.storeBootstrapped)
        await manager.bootstrapStore()
        XCTAssertTrue(manager.storeBootstrapped)
        XCTAssertEqual(opens, 2)
    }
}
