import XCTest
@testable import Strand

/// The one resolver for who owns a realtime raw stream (W06-061), and the once-per-stream line it earns
/// (W06-018, W06-055).
final class RealtimeRawOwnerTests: XCTestCase {

    /// Every input combination, in the order captureArmed, continuousCapture, inTail, ecgMayBeGenerating, and
    /// then sessionOpen nil / false / true within each group. Pinned from a standalone run of `resolve`:
    /// C capture, E ecgSession, U unknownUntilStoreReady, O openSession, N none.
    func testTheWholeDecisionTable() {
        func code(_ owner: RealtimeRawOwner) -> Character {
            switch owner {
            case .capture: return "C"
            case .ecgSession: return "E"
            case .unknownUntilStoreReady: return "U"
            case .openSession: return "O"
            case .none: return "N"
            }
        }
        var groups: [String] = []
        for captureArmed in [false, true] {
            for continuous in [false, true] {
                for inTail in [false, true] {
                    for ecg in [false, true] {
                        groups.append(String([nil, false, true].map { (sessionOpen: Bool?) in
                            code(RealtimeRawOwner.resolve(
                                captureArmed: captureArmed, continuousCapture: continuous,
                                sinceCaptureStop: inTail ? 0 : 10, ecgMayBeGenerating: ecg,
                                sessionOpen: sessionOpen))
                        }))
                    }
                }
            }
        }
        XCTAssertEqual(groups.joined(separator: " "),
                       "UNO EEE CCC CCC CCC CCC CCC CCC CCC CCC CCC CCC CCC CCC CCC CCC")
    }

    func testTheTailEndsAfterThreeSeconds() {
        func owner(_ since: TimeInterval) -> RealtimeRawOwner {
            RealtimeRawOwner.resolve(captureArmed: false, continuousCapture: false, sinceCaptureStop: since,
                                     ecgMayBeGenerating: false, sessionOpen: false)
        }
        XCTAssertEqual(owner(2.999), .capture)
        XCTAssertEqual(owner(3), .none)
        XCTAssertEqual(owner(Date().timeIntervalSince(.distantPast)), .none, "no capture stopped this launch")
    }

    /// One line per stream: a pause of a minute or a change of owner starts a new stream, a frame a capture or
    /// a session owns ends it, and a frame whose owner cannot be told yet does neither (W06-054).
    func testOneLinePerStream() {
        let none = "Raw IMU: realtime packet type 43 is arriving with no capture or ECG session armed in this app; "
            + "nothing is sent to stop it (noted once per stream)"
        let ecg = "Raw IMU: realtime packet type 43 is arriving while an ECG session from this app may still be "
            + "generating; nothing is sent to stop it (noted once per stream)"
        let script: [(RealtimeRawOwner, TimeInterval, String?)] = [
            (.none, 0, none),
            (.none, 1, nil),
            (.none, 59, nil),
            (.none, 130, none),                    // paused 71 s: a new stream
            (.ecgSession, 131, ecg),               // an ECG turn-on took it over
            (.none, 132, none),                    // the ECG stop left it running
            (.capture, 133, nil),                  // a capture owns it
            (.none, 134, none),
            (.unknownUntilStoreReady, 135, nil),
            (.none, 136, nil),                     // the unknown frame did not end the stream
            (.openSession, 137, nil),
            (.unknownUntilStoreReady, 138, nil),
            (.none, 139, none),                    // the session ended it; the unknown frame did not start one
        ]
        var note = RealtimeRawNote()
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        for (step, (owner, at, expected)) in script.enumerated() {
            XCTAssertEqual(note.line(packetType: 43, owner: owner, now: start.addingTimeInterval(at)), expected,
                           "step \(step)")
        }
        note.reset()
        XCTAssertEqual(note.line(packetType: 43, owner: .none, now: start.addingTimeInterval(140)), none,
                       "a new link notes its stream again")
        XCTAssertEqual(note.line(packetType: 51, owner: .ecgSession, now: start.addingTimeInterval(141)),
                       ecg.replacingOccurrences(of: "type 43", with: "type 51"))
    }
}
