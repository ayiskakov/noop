import XCTest
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
            streaming: { true }, now: { clock.now }, sleep: clock.sleep)
        XCTAssertEqual(outcome, .delivered)
        XCTAssertEqual(clock.now.timeIntervalSince(pressedAt), 4, accuracy: RawSessionTail.pollInterval)
    }

    func testAlreadyBankedStopsAtOnce() async {
        let clock = Clock()
        let outcome = await RawSessionTail.wait(for: 50, newest: { 50 }, streaming: { true },
                                                now: { clock.now }, sleep: clock.sleep)
        XCTAssertEqual(outcome, .delivered)
        XCTAssertEqual(clock.sleeps, 0)
    }

    func testAStalledStreamStopsAfterTheTimeout() async {
        let clock = Clock()
        let start = clock.now
        let outcome = await RawSessionTail.wait(for: 50, newest: { 46 }, streaming: { true },
                                                now: { clock.now }, sleep: clock.sleep)
        XCTAssertEqual(outcome, .short(missing: 4, disconnected: false))
        XCTAssertEqual(clock.now.timeIntervalSince(start), RawSessionTail.timeout,
                       accuracy: RawSessionTail.pollInterval)
    }

    func testADisconnectEndsTheWait() async {
        let clock = Clock()
        let outcome = await RawSessionTail.wait(for: 50, newest: { 47 }, streaming: { clock.sleeps < 2 },
                                                now: { clock.now }, sleep: clock.sleep)
        XCTAssertEqual(outcome, .short(missing: 3, disconnected: true))
        XCTAssertEqual(clock.sleeps, 2)
    }

    func testNothingBankedIsNamedAsSuch() async {
        let clock = Clock()
        let outcome = await RawSessionTail.wait(for: 50, newest: { nil }, streaming: { true },
                                                now: { clock.now }, sleep: clock.sleep)
        XCTAssertEqual(outcome, .short(missing: nil, disconnected: false))
    }

    /// The log states what was banked and never claims a flush the stop does not do.
    func testStopLogLines() {
        XCTAssertEqual(RawSessionTail.stopLogLine(.notAwaited), "Raw-data session: stopped")
        XCTAssertEqual(RawSessionTail.stopLogLine(.delivered),
                       "Raw-data session: stopped after the last full second was banked")
        XCTAssertEqual(RawSessionTail.stopLogLine(.short(missing: 4, disconnected: false)),
                       "Raw-data session: stopped 4 s short of the last full second, after waiting 10 s")
        XCTAssertEqual(RawSessionTail.stopLogLine(.short(missing: nil, disconnected: true)),
                       "Raw-data session: stopped with no IMU buffer banked, after the strap disconnected")
    }
}
