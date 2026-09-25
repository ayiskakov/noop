import XCTest
import WhoopProtocol
@testable import Strand

/// W06-025: a live 5/MG raw-data session stops the strap's stream only once the buffer of its last full
/// second is banked, because the strap delivers each one-second buffer seconds after that second starts.
@MainActor
final class RawSessionTailTests: XCTestCase {

    /// A fake clock that moves by one poll interval per sleep, and counts the sleeps.
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_000)
        var sleeps = 0
        func sleep(_ seconds: TimeInterval) async { sleeps += 1; now.addTimeInterval(seconds) }
    }

    /// The shape a real session showed: at the press the newest banked buffer is four seconds behind the
    /// last full second, and one more arrives per second.
    func testWaitsForTheLastFullSecondBeforeStopping() async {
        let bounds = RawDataCollectorView.fullSecondBounds(fromMs: 100_720, toMs: 253_832)
        XCTAssertEqual(bounds?.to, 252, "the last full second before the press")
        let lastSecond = 252
        let clock = Clock()
        let pressedAt = clock.now
        let outcome = await RawSessionTail.wait(
            for: lastSecond,
            newest: { Int64(lastSecond - 4) + Int64(clock.now.timeIntervalSince(pressedAt)) },
            armed: { true }, now: { clock.now }, sleep: clock.sleep)
        XCTAssertEqual(outcome, .delivered)
        XCTAssertEqual(clock.now.timeIntervalSince(pressedAt), 4, accuracy: RawSessionTail.pollInterval)
    }

    func testAlreadyBankedStopsAtOnce() async {
        let clock = Clock()
        let outcome = await RawSessionTail.wait(for: 50, newest: { 50 }, armed: { true },
                                                now: { clock.now }, sleep: clock.sleep)
        XCTAssertEqual(outcome, .delivered)
        XCTAssertEqual(clock.sleeps, 0)
    }

    func testAStalledStreamStopsAfterTheTimeout() async {
        let clock = Clock()
        let start = clock.now
        let outcome = await RawSessionTail.wait(for: 50, newest: { 46 }, armed: { true },
                                                now: { clock.now }, sleep: clock.sleep)
        XCTAssertEqual(outcome, .short(missing: 4, disarmed: false))
        XCTAssertEqual(clock.now.timeIntervalSince(start), RawSessionTail.timeout,
                       accuracy: RawSessionTail.pollInterval)
    }

    /// A disconnect disarms the capture, and then no stop can go out to discard anything.
    func testADisarmedCaptureEndsTheWait() async {
        let clock = Clock()
        let outcome = await RawSessionTail.wait(for: 50, newest: { 47 }, armed: { clock.sleeps < 2 },
                                                now: { clock.now }, sleep: clock.sleep)
        XCTAssertEqual(outcome, .short(missing: 3, disarmed: true))
        XCTAssertEqual(clock.sleeps, 2)
    }

    func testNothingBankedIsNamedAsSuch() async {
        let clock = Clock()
        let outcome = await RawSessionTail.wait(for: 50, newest: { nil }, armed: { true },
                                                now: { clock.now }, sleep: clock.sleep)
        XCTAssertEqual(outcome, .short(missing: nil, disarmed: false))
    }

    // MARK: - The stop itself (W06-036)

    /// A session store over throwaway files, its IMU store too.
    private struct Rig {
        let sessions: URL, imuFiles: URL, defaults: UserDefaults
        let imu: ImuSessionFileStore, store: RawDataSessionStore
    }

    private func rig() throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "raw-session-tail-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let sessions = root.appendingPathComponent("sessions"), imuFiles = root.appendingPathComponent("imu")
        let imu = ImuSessionFileStore(directory: imuFiles, defaults: defaults)
        return Rig(sessions: sessions, imuFiles: imuFiles, defaults: defaults, imu: imu,
                   store: RawDataSessionStore(directory: sessions, imu: imu))
    }

    private struct Stopped {
        let rig: Rig, session: RawDataSessionStore.Session, firstSecond: Int, pressedAt: Date
        let outcome: RawSessionTail.Outcome?
        /// The active session a collector opened at each poll of the wait would load.
        let activeDuringWait: [String?]
    }

    /// A session whose first full second is banked at the press, two seconds short of its last one; one
    /// more buffer arrives per poll of the wait, and a marker is added a quarter second after the press.
    private func stopWithATwoSecondTail() async throws -> Stopped {
        let rig = try rig()
        let ts = try XCTUnwrap(Whoop5RawImu.baseTs(CollectorImuBankingTests.fixture))
        let session = try XCTUnwrap(rig.store.start(deviceId: "strap",
                                                    now: Date(timeIntervalSince1970: TimeInterval(ts))))
        rig.imu.append(deviceId: "strap", frame: CollectorImuBankingTests.fixture, receivedAtMs: 0)
        let clock = Clock()
        clock.now = Date(timeIntervalSince1970: TimeInterval(ts) + 3.5)
        let pressedAt = clock.now
        var outcome: RawSessionTail.Outcome?
        var activeDuringWait: [String?] = []
        await RawSessionTail.stop(rig.store, pressedAt: pressedAt, armed: { true },
                                  stopStream: { outcome = $0 }, now: { clock.now }, sleep: { seconds in
            activeDuringWait.append(RawDataSessionStore(directory: rig.sessions, imu: rig.imu).active?.id)
            if clock.sleeps == 1 { rig.store.addMarker(sessionId: session.id, at: clock.now, type: "moment", text: "") }
            rig.imu.append(deviceId: "strap", frame: CollectorImuBankingTests.fixture(shiftedBy: UInt32(clock.sleeps + 1)),
                           receivedAtMs: 0)
            await clock.sleep(seconds)
        })
        return Stopped(rig: rig, session: session, firstSecond: ts, pressedAt: pressedAt, outcome: outcome,
                       activeDuringWait: activeDuringWait)
    }

    /// The session is saved as ended at the press, before the wait: a collector opened meanwhile loads no
    /// active session, so it can neither re-arm the stream nor stop the session again and move its end.
    func testTheSessionEndsAtThePressBeforeTheWait() async throws {
        let stopped = try await stopWithATwoSecondTail()
        XCTAssertEqual(stopped.outcome, .delivered)
        XCTAssertEqual(stopped.activeDuringWait, [nil, nil])
        let saved = try XCTUnwrap(RawDataSessionStore(directory: stopped.rig.sessions, imu: stopped.rig.imu).sessions.first)
        XCTAssertEqual(saved.endedAtMs, Int64(stopped.pressedAt.timeIntervalSince1970 * 1_000))
        XCTAssertEqual(saved.events.filter { $0.kind == "stop" }.count, 1)
    }

    /// A marker added while the tail is awaited is stamped inside the session (W06-044), not after its end,
    /// where the export would drop it.
    func testAMarkerAddedWhileStoppingStaysInTheSession() async throws {
        let stopped = try await stopWithATwoSecondTail()
        let saved = try XCTUnwrap(stopped.rig.store.sessions.first)
        let markers = saved.events.filter { $0.kind == "marker" }
        XCTAssertEqual(markers.map(\.atMs), [try XCTUnwrap(saved.endedAtMs)])
        let events = try XCTUnwrap(stopped.rig.store.exportEntries(for: saved).first { $0.name == "events.jsonl" })
        XCTAssertTrue(String(decoding: events.data, as: UTF8.self).contains("\"kind\":\"marker\""))
    }

    /// With no stop to go out (no capture armed on the link, or continuous raw capture on) nothing discards
    /// the tail, so Stop does not wait, and the outcome claims no disconnect (W06-037, W06-039).
    func testNothingIsAwaitedWhenNoStopWillGoOut() async throws {
        let rig = try rig()
        let started = Date(timeIntervalSince1970: 2_000)
        _ = try XCTUnwrap(rig.store.start(deviceId: "strap", now: started))
        let clock = Clock()
        var outcome: RawSessionTail.Outcome?
        await RawSessionTail.stop(rig.store, pressedAt: started.addingTimeInterval(60.5), armed: { false },
                                  stopStream: { outcome = $0 }, now: { clock.now }, sleep: clock.sleep)
        XCTAssertEqual(outcome, .notAwaited)
        XCTAssertEqual(clock.sleeps, 0)
        XCTAssertEqual(rig.store.sessions.first?.endedAtMs, 2_060_500)
    }

    /// The tail that banks after the session ended is on disk once the stream stops, so a relaunch before
    /// the export still finds every second.
    func testTheTailIsOnDiskOnceTheStreamStops() async throws {
        let stopped = try await stopWithATwoSecondTail()
        let relaunched = ImuSessionFileStore(directory: stopped.rig.imuFiles, defaults: stopped.rig.defaults)
        let stats = relaunched.stats(stopped.session.id, from: stopped.firstSecond, to: stopped.firstSecond + 2)
        XCTAssertEqual(stats.coveredSeconds, 3)
    }

    /// The log states what was banked and when no stop went out. It never claims a flush the stop does not
    /// do, nor a disconnect it did not see.
    func testStopLogLines() {
        XCTAssertEqual(RawSessionTail.stopLogLine(.notAwaited), "Raw-data session: stopped")
        XCTAssertEqual(RawSessionTail.stopLogLine(.delivered),
                       "Raw-data session: stopped after the last full second was banked")
        XCTAssertEqual(RawSessionTail.stopLogLine(.short(missing: 4, disarmed: false)),
                       "Raw-data session: stopped 4 s short of the last full second, after waiting 10 s")
        XCTAssertEqual(RawSessionTail.stopLogLine(.short(missing: nil, disarmed: true), unsent: .notArmed),
                       "Raw-data session: stopped with no IMU buffer banked, when the capture was disarmed; "
                       + "no stop sent: no capture is armed on this link")
        XCTAssertEqual(RawSessionTail.stopLogLine(.notAwaited, unsent: .notArmed),
                       "Raw-data session: stopped; no stop sent: no capture is armed on this link")
        XCTAssertEqual(RawSessionTail.stopLogLine(.notAwaited, unsent: .continuousCapture),
                       "Raw-data session: stopped; no stop sent: continuous raw capture is on")
    }
}
