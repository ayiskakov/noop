import Foundation
import WhoopProtocol

/// Which recipe stages an accepted night. Session DETECTION is the same for all three; only the per-epoch
/// hypnogram inside a detected night differs. The raw value is what the app persists for the user's choice.
public enum SleepStagerVersion: String, CaseIterable, Sendable {
    /// The original percentile-band stager, `SleepStager.stageSession`.
    case v1
    /// The hand-set cardiorespiratory recipe, `SleepStagerV2`.
    case v2
    /// The stager fitted to polysomnography, `SleepStagerV3`. The app's default.
    case v3

    /// "V1" / "V2" / "V3", for traces and diagnostics.
    public var label: String { rawValue.uppercased() }

    /// The recipe that stages a night with no motion at all, through `SleepStager.hrOnlySessions`. V2 and V3
    /// stage it from heart rate and beat intervals. V1 cannot: its epoch grid is built from gravity, and
    /// without any it returns one flat "light" block, so a V1 choice stages such a night with V2.
    public var hrOnlyRecipe: SleepStagerVersion { self == .v1 ? .v2 : self }

    /// Stage `[start, end]` with this recipe. `sleepWindow` is the band's `SleepStager.bandSleepWindow`; V2 and
    /// V3 stage inside it, and V1, which has no such input, ignores it (the band latency trim applies it
    /// afterwards for every recipe).
    public func stageSession(start: Int, end: Int, grav: [GravitySample], hr: [HRSample], rr: [RRInterval],
                             resp: [RespSample], sleepWindow: (from: Int, to: Int)? = nil) -> [StageSegment] {
        switch self {
        case .v1:
            return SleepStager.stageSession(start: start, end: end, grav: grav, hr: hr, rr: rr, resp: resp)
        case .v2:
            return SleepStagerV2.stageSession(start: start, end: end, grav: grav, hr: hr, rr: rr, resp: resp,
                                              sleepWindow: sleepWindow)
        case .v3:
            return SleepStagerV3.stageSession(start: start, end: end, grav: grav, hr: hr, rr: rr, resp: resp,
                                              sleepWindow: sleepWindow)
        }
    }
}
