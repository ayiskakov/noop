import Foundation
import StrandAnalytics
@testable import Strand

/// Runs `body` with the preferences an `IntelligenceEngine` pass reads cleared and pinned (midnight day
/// cycle, sleep stager V2, motion-aware wake off), and restores the host's values afterwards.
@MainActor
func withEngineTestPreferences(_ body: () async throws -> Void) async throws {
    let defaults = UserDefaults.standard
    let keys = [
        "profile.dateOfBirth", "profile.age", "profile.sex", "profile.weightKg",
        "profile.heightCm", "profile.waistCm", "profile.hrMaxOverride",
        "noop.analyzeWatermark", "analyzeRecent.stepsMotionCache.v1",
        "noop.hrvBaselineEpoch", "noop.recoveryBaselineEpoch", UnitPrefs.hrvWindowKey,
        RescoreBackgroundScheduler.owedKey, RescoreBackgroundScheduler.owedTokenKey,
        RescoreBackgroundScheduler.lastPassSecondsKey, DayCycleMode.storageKey,
        PuffinExperiment.experimentalSleepV2Key, PuffinExperiment.sleepStagerKey,
        PuffinExperiment.motionAwareWakeKey,
    ]
    let saved = keys.map { ($0, defaults.object(forKey: $0)) }
    defer {
        for (key, value) in saved {
            if let value { defaults.set(value, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
    }
    for key in keys { defaults.removeObject(forKey: key) }
    defaults.set(DayCycleMode.midnight.rawValue, forKey: DayCycleMode.storageKey)
    defaults.set(SleepStagerVersion.v2.rawValue, forKey: PuffinExperiment.sleepStagerKey)
    defaults.set(false, forKey: PuffinExperiment.motionAwareWakeKey)
    try await body()
}
