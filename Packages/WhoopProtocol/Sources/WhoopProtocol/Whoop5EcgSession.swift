import Foundation

/// One WHOOP MG ECG session, from the wrist selection to the stop, as a small state machine the BLE
/// layer drives and a screen reads (#891).
///
/// `docs/PROTOCOL_ECG.md` asks a client to "select and acknowledge the intended wrist before start", to
/// "serialize ECG session transitions and resolve the previous session before starting another", and to
/// "report wrist refusal, start refusal, acknowledged start without data, and received records
/// separately". Every one of those is a rule about ORDER or ATTRIBUTION, so they live here, in one pure
/// type `swift test` covers, rather than in a view's flags and a manager's callbacks, where the screen and
/// the strap log could each resolve the same outcome differently.
///
/// The type sends nothing. An event that requires a send returns it as an `Action`, and the caller sends.
public struct Whoop5EcgSession: Equatable, Sendable {

    public typealias Outcome = Whoop5EcgProbe.CommandOutcome

    public enum Phase: Equatable, Sendable {
        /// SELECT_WRIST is out. Generation is not requested until it answers SUCCESS.
        case selectingWrist
        /// The turn-on requests are out; the strap may be generating.
        case started
        /// The stop requests are out and their replies are awaited.
        case stopping
        /// Nothing more is awaited on this link.
        case ended
    }

    /// What the caller must do after an event.
    public enum Action: Equatable, Sendable {
        case none
        /// The wrist was accepted: send the turn-on requests now.
        case sendStart
    }

    /// The turn-on requests, in send order: live filtered output, raw saving, then generation.
    public static let startOpcodes: [UInt8] = [
        Whoop5Ecg.toggleRealtimeFilteredEcgCmd, Whoop5Ecg.toggleSaveRawEcgCmd,
        Whoop5Ecg.mainControlEcgDataGenerationCmd,
    ]
    /// The stop requests, in send order: generation first, then both outputs.
    public static let stopOpcodes: [UInt8] = [
        Whoop5Ecg.mainControlEcgDataGenerationCmd, Whoop5Ecg.toggleSaveRawEcgCmd,
        Whoop5Ecg.toggleRealtimeFilteredEcgCmd,
    ]

    /// The wrist sent first, or nil for a start without one.
    public let wrist: Whoop5Ecg.WristSelection?
    public private(set) var phase: Phase
    /// The wrist reply's final outcome; nil while none has settled.
    public private(set) var wristOutcome: Outcome?
    /// Final outcomes of the turn-on requests, by opcode, as they settle.
    public private(set) var startOutcomes: [UInt8: Outcome] = [:]
    /// Final outcomes of the stop requests, by opcode, as they settle.
    public private(set) var stopOutcomes: [UInt8: Outcome] = [:]
    /// Live records received while the session was started or stopping.
    public private(set) var records = 0
    /// True once the turn-on requests went out.
    public private(set) var startSent: Bool
    /// True once the stop requests went out.
    public private(set) var stopSent = false
    /// True when the session ended with the turn-on requests sent and no stop sent: the link dropped, or
    /// the stop could not be sent. The strap may still be generating.
    public private(set) var stopUnsent = false
    /// True when the user finished while the wrist was still unanswered, so nothing was started.
    public private(set) var cancelledBeforeStart = false

    /// A session that sends `wrist` first, or starts at once when `wrist` is nil. The caller sends
    /// SELECT_WRIST, or the turn-on requests, right after creating it.
    public init(wrist: Whoop5Ecg.WristSelection?) {
        self.wrist = wrist
        phase = wrist == nil ? .started : .selectingWrist
        startSent = wrist == nil
    }

    // MARK: - Events

    /// A COMMAND_RESPONSE for one of the ECG opcodes.
    ///
    /// PENDING settles nothing: the strap answers again with a final result, and treating the interim
    /// reply as final would report a refusal the strap never made.
    public mutating func noteReply(opcode: UInt8, outcome: Outcome) -> Action {
        guard outcome != .pending, outcome != .noReply else { return .none }
        switch phase {
        case .selectingWrist:
            guard opcode == Whoop5Ecg.selectWristCmd else { return .none }
            wristOutcome = outcome
            guard outcome == .success else {
                phase = .ended
                return .none
            }
            phase = .started
            startSent = true
            return .sendStart
        case .started:
            settleStart(opcode, outcome)
        case .stopping:
            // The stop reuses the turn-on opcodes, and replies come back in send order, so a request of
            // the turn-on set that has not settled yet takes a reply first. Only a lost turn-on reply could
            // move a stop reply onto it, and the stop wait expiring covers that case.
            if Self.startOpcodes.contains(opcode), startOutcomes[opcode] == nil {
                settleStart(opcode, outcome)
            } else if Self.stopOpcodes.contains(opcode), stopOutcomes[opcode] == nil {
                stopOutcomes[opcode] = outcome
                if Self.stopOpcodes.allSatisfy({ stopOutcomes[$0] != nil }) { phase = .ended }
            }
        case .ended:
            break
        }
        return .none
    }

    private mutating func settleStart(_ opcode: UInt8, _ outcome: Outcome) {
        if Self.startOpcodes.contains(opcode), startOutcomes[opcode] == nil { startOutcomes[opcode] = outcome }
    }

    /// One CRC-valid live ECG record arrived.
    public mutating func noteRecord() {
        if phase == .started || phase == .stopping { records += 1 }
    }

    /// The wrist reply did not arrive in time. Nothing was started, so there is nothing to stop.
    public mutating func noteWristTimeout() {
        if phase == .selectingWrist { phase = .ended }
    }

    /// The user finished. Returns true when the caller must send the stop requests: only a session whose
    /// turn-on requests went out has anything to stop. A session still waiting on its wrist simply ends,
    /// and a wrist reply that arrives later starts nothing.
    public mutating func requestStop() -> Bool {
        switch phase {
        case .selectingWrist:
            cancelledBeforeStart = true
            phase = .ended
            return false
        case .started:
            return true
        case .stopping, .ended:
            return false
        }
    }

    /// The stop requests went out.
    public mutating func noteStopSent() {
        guard phase == .started else { return }
        stopSent = true
        phase = .stopping
    }

    /// The stop could not be sent (no MG link).
    public mutating func noteStopUnsent() {
        guard phase == .started else { return }
        stopUnsent = true
        phase = .ended
    }

    /// The stop replies did not all arrive in time.
    public mutating func noteStopTimeout() {
        if phase == .stopping { phase = .ended }
    }

    /// The link dropped. A started session loses its stop; a stopping one loses the rest of its replies.
    public mutating func noteLinkLost() {
        switch phase {
        case .started: stopUnsent = true
        case .selectingWrist, .stopping, .ended: break
        }
        phase = .ended
    }

    // MARK: - What the session established

    /// True while a transition is in flight or the strap may be generating: another start must wait.
    public var isActive: Bool { phase != .ended }

    /// The headline outcome, in the order the protocol doc keeps them apart.
    public enum Summary: Equatable, Sendable {
        /// SELECT_WRIST answered other than SUCCESS; nothing was started.
        case wristRefused(Outcome)
        /// SELECT_WRIST never answered; nothing was started.
        case wristUnanswered
        /// The session ended before its wrist settled, at the user's request; nothing was started.
        case cancelled
        /// A turn-on request answered other than SUCCESS, and no record arrived.
        case startRefused(opcode: UInt8, Outcome)
        /// A turn-on request never answered, none refused, and no record arrived.
        case startUnanswered
        /// Every turn-on request answered SUCCESS, and no record arrived.
        case acceptedWithoutRecords
        /// Live records arrived.
        case recorded(records: Int)
    }

    /// Meaningful once the wrist has settled: while it is still out this reads `wristUnanswered`.
    public var summary: Summary {
        if !startSent {
            if let outcome = wristOutcome { return .wristRefused(outcome) }
            return cancelledBeforeStart ? .cancelled : .wristUnanswered
        }
        if records > 0 { return .recorded(records: records) }
        for opcode in Self.startOpcodes {
            if let outcome = startOutcomes[opcode], outcome != .success {
                return .startRefused(opcode: opcode, outcome)
            }
        }
        if Self.startOpcodes.contains(where: { startOutcomes[$0] == nil }) { return .startUnanswered }
        return .acceptedWithoutRecords
    }

    /// True when the live-output or the generation request answered other than SUCCESS: live data cannot
    /// follow, so a client waiting on it can stop. A refused raw save alone is not this: the save and
    /// live gates are independent (`docs/PROTOCOL_ECG.md` §Commands), so live data can still arrive.
    public var liveDataRefused: Bool {
        [Whoop5Ecg.toggleRealtimeFilteredEcgCmd, Whoop5Ecg.mainControlEcgDataGenerationCmd].contains { opcode in
            if let outcome = startOutcomes[opcode] { return outcome != .success }
            return false
        }
    }

    /// True when the raw-save request answered SUCCESS, which is what lets a client say the full-resolution
    /// record was asked for. It is a request accepted, not a recording confirmed.
    public var saveAccepted: Bool { startOutcomes[Whoop5Ecg.toggleSaveRawEcgCmd] == .success }

    /// How the stop went, or nil while the session is still running or stopping.
    public enum StopResult: Equatable, Sendable {
        /// Nothing was started, so nothing needed stopping.
        case notNeeded
        /// The stop could not be sent; the strap may still be generating.
        case unsent
        /// Every stop request answered SUCCESS.
        case confirmed
        /// A stop request answered other than SUCCESS.
        case refused(opcode: UInt8, Outcome)
        /// The stop went out but not every request answered.
        case unanswered
    }

    public var stopResult: StopResult? {
        guard phase == .ended else { return nil }
        if !startSent { return .notNeeded }
        if stopUnsent { return .unsent }
        for opcode in Self.stopOpcodes {
            if let outcome = stopOutcomes[opcode], outcome != .success {
                return .refused(opcode: opcode, outcome)
            }
        }
        return Self.stopOpcodes.allSatisfy { stopOutcomes[$0] != nil } ? .confirmed : .unanswered
    }
}
