import XCTest
@testable import Strand

/// The durable strap-log tail used to be a SINGLE slot: a fresh process began logging and, 32 lines in,
/// `persistTail` overwrote it — so the lines that would explain an unexplained restart were destroyed by
/// the restart itself. Three consecutive overnight Oura captures were lost exactly that way. These pin the
/// generation ring that rescues the tail at first append.
@MainActor
final class LiveStateLogGenerationsTests: XCTestCase {
    private let tailKey = "strapLog.tail"
    private let gensKey = "strapLog.generations"
    private let tailSessionLinesKey = "strapLog.tailSessionLines"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: tailKey)
        UserDefaults.standard.removeObject(forKey: gensKey)
        UserDefaults.standard.removeObject(forKey: tailSessionLinesKey)
        LiveState.resetGenerationRollLatchForTesting()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: tailKey)
        UserDefaults.standard.removeObject(forKey: gensKey)
        UserDefaults.standard.removeObject(forKey: tailSessionLinesKey)
        LiveState.resetGenerationRollLatchForTesting()
        super.tearDown()
    }

    /// THE ONE THAT MATTERS: a surviving tail is moved into a generation, and the live slot is cleared so
    /// the next `persistTail` cannot destroy it.
    func testRollMovesTheSurvivingTailIntoAGeneration() {
        UserDefaults.standard.set(["22:01 connected", "22:02 drain done"], forKey: tailKey)

        LiveState.rollLogGenerationsIfNeeded()

        let gens = LiveState.persistedLogGenerations()
        XCTAssertEqual(gens.count, 1)
        XCTAssertEqual(gens[0].dropFirst(), ["22:01 connected", "22:02 drain done"])
        XCTAssertTrue(gens[0][0].contains("previous app session"), "generation must carry its own header")
        XCTAssertEqual(LiveState.persistedLogTail(), [], "the live slot must be cleared, not left to duplicate")
    }

    /// Idempotent per process: a second call must NOT push this process's own partial tail in as a
    /// "previous" session (which would evict a real one and mislabel the current lines).
    func testRollIsOncePerProcess() {
        UserDefaults.standard.set(["old line"], forKey: tailKey)
        LiveState.rollLogGenerationsIfNeeded()
        UserDefaults.standard.set(["a line this process just wrote"], forKey: tailKey)

        LiveState.rollLogGenerationsIfNeeded()

        XCTAssertEqual(LiveState.persistedLogGenerations().count, 1)
        XCTAssertEqual(LiveState.persistedLogTail(), ["a line this process just wrote"])
    }

    /// A launch that logs nothing (or one right after a roll) must not push an empty generation — that
    /// would evict a real one, which is the opposite of the point.
    func testEmptyTailRollsNothing() {
        LiveState.rollLogGenerationsIfNeeded()
        XCTAssertEqual(LiveState.persistedLogGenerations().count, 0)
    }

    /// The ring is bounded and drops the OLDEST, keeping the most recent restarts.
    func testRingKeepsTheMostRecentGenerations() {
        for i in 1...(LiveState.maxLogGenerations + 2) {
            UserDefaults.standard.set(["session \(i)"], forKey: tailKey)
            LiveState.resetGenerationRollLatchForTesting()   // stands in for a fresh process
            LiveState.rollLogGenerationsIfNeeded()
        }
        let gens = LiveState.persistedLogGenerations()
        XCTAssertEqual(gens.count, LiveState.maxLogGenerations)
        XCTAssertEqual(gens.first?.dropFirst().first, "session 3", "oldest generations are evicted first")
        XCTAssertEqual(gens.last?.dropFirst().first, "session \(LiveState.maxLogGenerations + 2)")
    }

    /// Each generation is clipped to its own cap so the ring cannot grow UserDefaults without bound, and
    /// the clip keeps the TAIL — what explains a stop is the end of the previous session, not its start.
    func testGenerationIsClippedToItsTail() {
        let many = (0..<(LiveState.generationTailLimit + 50)).map { "line \($0)" }
        UserDefaults.standard.set(many, forKey: tailKey)

        LiveState.rollLogGenerationsIfNeeded()

        let body = Array(LiveState.persistedLogGenerations()[0].dropFirst())
        XCTAssertEqual(body.count, LiveState.generationTailLimit)
        XCTAssertEqual(body.last, "line \(LiveState.generationTailLimit + 49)", "the newest line must survive")
    }

    /// A clipped generation must SAY it lost its head. The header reported the pre-clip total, so a
    /// generation holding 1,000 of 2,000 lines announced "2000 line(s)" and read as a complete session —
    /// and the dropped head then measures as silence in the log tools.
    func testClippedGenerationHeaderSaysWhatWasKept() {
        let many = (0..<(LiveState.generationTailLimit + 50)).map { "line \($0)" }
        UserDefaults.standard.set(many, forKey: tailKey)

        LiveState.rollLogGenerationsIfNeeded()

        let header = LiveState.persistedLogGenerations()[0][0]
        XCTAssertTrue(header.contains("\(LiveState.generationTailLimit) of \(many.count) line(s)"),
                      "header must carry both the kept and the pre-clip count: \(header)")
        XCTAssertTrue(header.contains("head clipped"), "a clipped generation must say so: \(header)")
    }

    /// ...and an UNCLIPPED one must not cry wolf: no "head clipped", just the count.
    func testUnclippedGenerationHeaderClaimsNoLoss() {
        UserDefaults.standard.set(["22:01 connected", "22:02 drain done"], forKey: tailKey)

        LiveState.rollLogGenerationsIfNeeded()

        let header = LiveState.persistedLogGenerations()[0][0]
        XCTAssertTrue(header.contains("2 line(s)"), header)
        XCTAssertFalse(header.contains("clipped"), header)
    }

    /// The export puts previous sessions AHEAD of the current one, so `report.txt` stays chronological and
    /// the log-parsing tools keep working on it unchanged.
    func testPreviousSessionsTextPrecedesTheCurrentMarker() {
        UserDefaults.standard.set(["last night 03:00 disconnected"], forKey: tailKey)
        LiveState.rollLogGenerationsIfNeeded()

        let text = LiveState.previousSessionsText()
        let prevIdx = try? XCTUnwrap(text.range(of: "last night 03:00 disconnected")?.lowerBound)
        let curIdx = try? XCTUnwrap(text.range(of: "current app session")?.lowerBound)
        XCTAssertNotNil(prevIdx)
        XCTAssertNotNil(curIdx)
        if let p = prevIdx, let c = curIdx { XCTAssertTrue(p < c) }
    }

    func testNoGenerationsRendersNothing() {
        XCTAssertEqual(LiveState.previousSessionsText(), "")
    }

    /// #1263: a manual export taken BEFORE this process's first append must still carry the previous
    /// session. `exportableLogText()` rolls the surviving tail itself (not only `append`), so an
    /// instant post-restart Report is not empty — the exact case the generation ring exists for.
    func testExportBeforeFirstAppendStillCarriesThePreviousSession() {
        UserDefaults.standard.set(["last night 03:14 reconnect storm", "03:15 gave up"], forKey: tailKey)
        // Fresh process: setUp reset the roll latch and the in-memory `log` is empty (no append yet).
        let text = LiveState().exportableLogText()
        XCTAssertTrue(text.contains("last night 03:14 reconnect storm"),
                      "export before the first append must roll + include the previous session")
        XCTAssertTrue(text.contains("previous app session"), "the previous session keeps its header")
        XCTAssertEqual(LiveState.persistedLogTail(), [], "the roll clears the live slot")
    }

    // MARK: - W06-108: a clipped current session says so

    /// One line past the ring's trim point evicts the head. Both exports must say how much is gone, and must
    /// print the header with no previous generation ahead of it: the live one from the ring, the scheduled one
    /// from the durable tail, over the same session's line count.
    func testAClippedCurrentSessionSaysSoInBothExports() {
        let live = LiveState()
        let total = LiveState.maxLogLines + 257
        for i in 0..<total { live.append(log: "line \(i)") }
        live.clearBiometrics()   // the disconnect flush, so the durable tail is current

        XCTAssertEqual(live.droppedLogLines, 257)
        XCTAssertTrue(live.exportableLogText().contains(
            "===== current app session, \(LiveState.maxLogLines) of \(total) line(s), head clipped ====="))
        XCTAssertTrue(LiveState.scheduledExportText().contains(
            "===== current app session, \(LiveState.tailLimit) of \(total) line(s), head clipped ====="))
    }

    /// ...and a session that kept every line claims no loss.
    func testAnUnclippedCurrentSessionClaimsNoLoss() {
        let live = LiveState()
        for i in 0..<10 { live.append(log: "line \(i)") }
        live.clearBiometrics()
        XCTAssertFalse(live.exportableLogText().contains("clipped"))
        XCTAssertFalse(LiveState.scheduledExportText().contains("clipped"))
    }

    // MARK: - W06-113: a previous session's header counts the session, not the tail's cap

    /// The durable tail holds the newest `tailLimit` lines of a session that logged more. The generation's
    /// header must report the session's own count, which the tail's length cannot tell.
    func testAGenerationHeaderCountsTheWholeSessionNotTheTailCap() {
        let tail = (0..<LiveState.tailLimit).map { "line \($0)" }
        UserDefaults.standard.set(tail, forKey: tailKey)
        UserDefaults.standard.set(["lines": 5_185, "lastLine": tail.last!], forKey: tailSessionLinesKey)

        LiveState.rollLogGenerationsIfNeeded()

        let header = LiveState.persistedLogGenerations()[0][0]
        XCTAssertTrue(header.contains("\(LiveState.generationTailLimit) of 5185 line(s), head clipped"), header)
    }

    /// A tail the ring and the cap both kept whole is unclipped even when its count was persisted.
    func testAWholeSessionWithACountClaimsNoLoss() {
        UserDefaults.standard.set(["a", "b"], forKey: tailKey)
        UserDefaults.standard.set(["lines": 2, "lastLine": "b"], forKey: tailSessionLinesKey)

        LiveState.rollLogGenerationsIfNeeded()

        let header = LiveState.persistedLogGenerations()[0][0]
        XCTAssertTrue(header.contains("2 line(s)"), header)
        XCTAssertFalse(header.contains("clipped"), header)
    }

    /// W06-119: a build without the count key writes a tail and never the count, so a count left by a newer
    /// build must not be read against that tail and invent a clip.
    func testACountLeftByAnotherBuildIsNotPairedWithItsTail() {
        let live = LiveState()
        for i in 0..<40 { live.append(log: "new build line \(i)") }   // persists the tail and its count at 32
        LiveState.resetGenerationRollLatchForTesting()
        // An older build runs: it rolls nothing we check here and writes a short tail of its own.
        UserDefaults.standard.set(["old build a", "old build b"], forKey: tailKey)

        LiveState.rollLogGenerationsIfNeeded()

        let header = LiveState.persistedLogGenerations().last?[0] ?? ""
        XCTAssertTrue(header.contains("2 line(s)"), header)
        XCTAssertFalse(header.contains("clipped"), header)
    }

    /// W06-120: a scheduled export in a fresh process, before its first line, reads the previous process's
    /// tail. It must file that tail under a previous-session header, as the manual export does (#1263), not
    /// call it the current session.
    func testAScheduledExportBeforeTheFirstLineCallsTheTailPrevious() {
        UserDefaults.standard.set(["last night 03:14 reconnect storm", "03:15 gave up"], forKey: tailKey)
        UserDefaults.standard.set(["lines": 10, "lastLine": "03:15 gave up"], forKey: tailSessionLinesKey)

        let text = LiveState.scheduledExportText()

        XCTAssertTrue(text.contains("previous app session, 2 of 10 line(s), head clipped"), text)
        XCTAssertFalse(text.contains("current app session, 2 of 10"), text)
        XCTAssertTrue(text.contains("last night 03:14 reconnect storm"), text)
    }
}
