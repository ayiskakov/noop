import XCTest
@testable import WhoopProtocol

/// `Whoop5EcgSession`: the order an MG ECG session's requests go out in, and how each outcome is kept
/// apart from the others (`docs/PROTOCOL_ECG.md` §Commands, §Repeated ECG start).
final class Whoop5EcgSessionTests: XCTestCase {

    private let wrist = Whoop5Ecg.selectWristCmd
    private let filtered = Whoop5Ecg.toggleRealtimeFilteredEcgCmd
    private let save = Whoop5Ecg.toggleSaveRawEcgCmd
    private let generation = Whoop5Ecg.mainControlEcgDataGenerationCmd

    /// A session whose wrist and all three turn-on requests answered SUCCESS.
    private func started() -> Whoop5EcgSession {
        var s = Whoop5EcgSession(wrist: .left)
        XCTAssertEqual(s.noteReply(opcode: wrist, outcome: .success), .sendStart)
        for op in Whoop5EcgSession.startOpcodes { _ = s.noteReply(opcode: op, outcome: .success) }
        return s
    }

    func testTheStartWaitsForTheWristToAnswerSuccess() {
        var s = Whoop5EcgSession(wrist: .right)
        XCTAssertEqual(s.phase, .selectingWrist)
        XCTAssertFalse(s.startSent)
        // A turn-on reply cannot arrive before the start is sent, and must not be taken as one.
        XCTAssertEqual(s.noteReply(opcode: generation, outcome: .success), .none)
        XCTAssertEqual(s.noteReply(opcode: wrist, outcome: .success), .sendStart)
        XCTAssertEqual(s.phase, .started)
        XCTAssertTrue(s.startSent)
        XCTAssertTrue(s.isActive)
    }

    func testPendingSettlesNothingAndTheFinalReplyDecides() {
        var s = Whoop5EcgSession(wrist: .left)
        XCTAssertEqual(s.noteReply(opcode: wrist, outcome: .pending), .none)
        XCTAssertNil(s.wristOutcome)
        XCTAssertEqual(s.phase, .selectingWrist)
        XCTAssertEqual(s.noteReply(opcode: wrist, outcome: .success), .sendStart)
        XCTAssertEqual(s.wristOutcome, .success)
    }

    func testARefusedWristStartsNothingAndNeedsNoStop() {
        var s = Whoop5EcgSession(wrist: .left)
        XCTAssertEqual(s.noteReply(opcode: wrist, outcome: .failure), .none)
        XCTAssertEqual(s.phase, .ended)
        XCTAssertFalse(s.startSent)
        XCTAssertFalse(s.isActive)
        XCTAssertEqual(s.summary, .wristRefused(.failure))
        XCTAssertEqual(s.stopResult, .notNeeded)
        XCTAssertFalse(s.requestStop())
    }

    func testAnUnansweredWristEndsWithoutStarting() {
        var s = Whoop5EcgSession(wrist: .left)
        s.noteWristTimeout()
        XCTAssertEqual(s.summary, .wristUnanswered)
        XCTAssertEqual(s.stopResult, .notNeeded)
        // A reply that turns up after the wait expired must not start anything.
        XCTAssertEqual(s.noteReply(opcode: wrist, outcome: .success), .none)
        XCTAssertFalse(s.startSent)
    }

    func testFinishingBeforeTheWristAnswersCancelsAndALateSuccessStartsNothing() {
        var s = Whoop5EcgSession(wrist: .left)
        XCTAssertFalse(s.requestStop())
        XCTAssertEqual(s.summary, .cancelled)
        XCTAssertEqual(s.noteReply(opcode: wrist, outcome: .success), .none)
        XCTAssertFalse(s.startSent)
        XCTAssertEqual(s.stopResult, .notNeeded)
    }

    func testAStartWithoutAWristIsStartedAtOnce() {
        let s = Whoop5EcgSession(wrist: nil)
        XCTAssertEqual(s.phase, .started)
        XCTAssertTrue(s.startSent)
    }

    func testRecordsOutrankTheReplies() {
        var s = Whoop5EcgSession(wrist: nil)
        _ = s.noteReply(opcode: save, outcome: .failure)
        s.noteRecord()
        s.noteRecord()
        // Data arrived, so the headline is the data; the refused save is reported on its own.
        XCTAssertEqual(s.summary, .recorded(records: 2))
        XCTAssertFalse(s.saveAccepted)
    }

    func testStartRefusalAcceptedWithoutRecordsAndUnansweredStayApart() {
        var refused = Whoop5EcgSession(wrist: nil)
        _ = refused.noteReply(opcode: filtered, outcome: .success)
        _ = refused.noteReply(opcode: generation, outcome: .unsupported)
        XCTAssertEqual(refused.summary, .startRefused(opcode: generation, .unsupported))

        var silent = Whoop5EcgSession(wrist: nil)
        for op in Whoop5EcgSession.startOpcodes { _ = silent.noteReply(opcode: op, outcome: .success) }
        XCTAssertEqual(silent.summary, .acceptedWithoutRecords)
        XCTAssertTrue(silent.saveAccepted)

        var unanswered = Whoop5EcgSession(wrist: nil)
        _ = unanswered.noteReply(opcode: filtered, outcome: .success)
        XCTAssertEqual(unanswered.summary, .startUnanswered)
    }

    func testOnlyALiveOrGenerationRefusalMeansNoLiveDataCanFollow() {
        var saveRefused = Whoop5EcgSession(wrist: nil)
        _ = saveRefused.noteReply(opcode: filtered, outcome: .success)
        _ = saveRefused.noteReply(opcode: save, outcome: .failure)
        _ = saveRefused.noteReply(opcode: generation, outcome: .success)
        XCTAssertFalse(saveRefused.liveDataRefused, "the save gate is independent of live output")

        var liveRefused = Whoop5EcgSession(wrist: nil)
        _ = liveRefused.noteReply(opcode: filtered, outcome: .failure)
        XCTAssertTrue(liveRefused.liveDataRefused)

        var generationUnsupported = Whoop5EcgSession(wrist: nil)
        _ = generationUnsupported.noteReply(opcode: generation, outcome: .unsupported)
        XCTAssertTrue(generationUnsupported.liveDataRefused)

        XCTAssertFalse(Whoop5EcgSession(wrist: nil).liveDataRefused, "nothing settled is not a refusal")
    }

    func testTheStopSettlesInOrderAndEndsOnItsLastReply() {
        var s = started()
        XCTAssertTrue(s.requestStop())
        s.noteStopSent()
        XCTAssertEqual(s.phase, .stopping)
        XCTAssertNil(s.stopResult)
        XCTAssertTrue(s.isActive)
        for op in Whoop5EcgSession.stopOpcodes { _ = s.noteReply(opcode: op, outcome: .success) }
        XCTAssertEqual(s.phase, .ended)
        XCTAssertEqual(s.stopResult, .confirmed)
        XCTAssertFalse(s.isActive)
    }

    func testALateTurnOnReplyIsNotTakenAsTheStopReply() {
        var s = Whoop5EcgSession(wrist: nil)
        _ = s.noteReply(opcode: filtered, outcome: .success)
        _ = s.noteReply(opcode: save, outcome: .success)
        XCTAssertTrue(s.requestStop())
        s.noteStopSent()
        // Generation's turn-on reply was still out when the stop went: it settles the start, not the stop.
        _ = s.noteReply(opcode: generation, outcome: .success)
        XCTAssertEqual(s.startOutcomes[generation], .success)
        XCTAssertNil(s.stopOutcomes[generation])
        XCTAssertEqual(s.phase, .stopping)
    }

    func testAStopThatCouldNotBeSentOrWasLostSaysTheStrapMayStillRun() {
        var unsent = started()
        XCTAssertTrue(unsent.requestStop())
        unsent.noteStopUnsent()
        XCTAssertEqual(unsent.stopResult, .unsent)

        var dropped = started()
        dropped.noteLinkLost()
        XCTAssertEqual(dropped.stopResult, .unsent)

        var timedOut = started()
        _ = timedOut.requestStop()
        timedOut.noteStopSent()
        _ = timedOut.noteReply(opcode: generation, outcome: .success)
        timedOut.noteStopTimeout()
        XCTAssertEqual(timedOut.stopResult, .unanswered)

        var refused = started()
        _ = refused.requestStop()
        refused.noteStopSent()
        _ = refused.noteReply(opcode: generation, outcome: .failure)
        refused.noteStopTimeout()
        XCTAssertEqual(refused.stopResult, .refused(opcode: generation, .failure))
    }

    func testRecordsCountOnlyWhileTheSessionCanProduceThem() {
        var s = Whoop5EcgSession(wrist: .left)
        s.noteRecord()                       // before the start: another session's frame
        XCTAssertEqual(s.records, 0)
        _ = s.noteReply(opcode: wrist, outcome: .success)
        s.noteRecord()
        _ = s.requestStop()
        s.noteStopSent()
        s.noteRecord()                       // in flight when the stop went out
        s.noteStopTimeout()
        s.noteRecord()                       // after the session ended
        XCTAssertEqual(s.records, 2)
    }

    func testTheWristTokenRoundTripsAndNeverReadsTheWireArgument() {
        for w in Whoop5Ecg.WristSelection.allCases {
            XCTAssertEqual(Whoop5Ecg.WristSelection(token: w.token), w)
        }
        XCTAssertNil(Whoop5Ecg.WristSelection(token: "1"))
        XCTAssertNil(Whoop5Ecg.WristSelection(token: ""))
    }
}
