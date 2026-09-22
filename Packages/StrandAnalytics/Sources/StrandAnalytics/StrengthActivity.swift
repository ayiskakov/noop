import Foundation

// StrengthActivity.swift — the ONE place that decides whether an activity counts as muscle-strengthening.
//
// The weekly strength dose feeding `VitalityEngine.strengthLnHazard` can arrive from three directions: a
// workout row's `sport` string (typed by the user, or carried in from a WHOOP/Apple import), a Lift Log
// session, or the motion classifier's `.strength` verdict. Those spell the same activity differently —
// "Weightlifting", "Functional Strength Training", "strength" — and a scattered string compare would
// silently drop whichever spelling the caller didn't think of, exactly as scattered device-model compares
// used to miss straps. So the resolver lives here, once, and every caller reads it.
public enum StrengthActivity {

    /// Sport names that count as muscle-strengthening, lowercased. Covers NOOP's own catalog entry
    /// ("Weightlifting"), the HealthKit workout types that import as strength, and the plural/spacing
    /// variants seen in WHOOP CSV exports.
    static let sportNames: Set<String> = [
        "weightlifting", "weight lifting", "weight training", "strength", "strength training",
        "functional strength training", "traditional strength training", "resistance training",
        "powerlifting", "crossfit", "calisthenics", "bodyweight", "bodyweight training",
    ]

    /// Substrings that mark an activity name as muscle-strengthening whatever else it is called. This is
    /// the rule the WHOOP CSV importer has always applied to `activityName`; it is kept here, rather than
    /// narrowed to the exact set above, so unifying the two callers cannot silently reclassify days a user
    /// already has on disk. It is deliberately generous — "Weighted Vest Walk" matches — because the dose
    /// it feeds plateaus quickly and a missed session costs more than a generous one.
    static let strengthSubstrings = ["strength", "weight"]

    /// Whether an activity or sport name is muscle-strengthening. Case- and whitespace-insensitive, and the
    /// ONE answer every caller uses: the analytics pass reading workout rows, and the WHOOP CSV importer
    /// reading `activityName`. Two rules would put a session in a user's strength minutes on import and
    /// leave it out on re-score, with nothing on screen to explain the gap.
    public static func isStrengthSport(_ sport: String) -> Bool {
        let name = sport.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if sportNames.contains(name) { return true }
        return strengthSubstrings.contains { name.contains($0) }
    }

    /// Whether the motion classifier's verdict counts as muscle-strengthening.
    public static func isStrengthClass(_ predicted: CoarseWorkoutClass) -> Bool { predicted == .strength }

    /// Weekly strength minutes from per-session minutes, capped per session.
    ///
    /// The cap is not cosmetic: a session left running overnight, or an import whose end timestamp is
    /// wrong, would otherwise hand someone hundreds of "strength minutes" and move their Body Age on a
    /// data error. `strengthLnHazard` plateaus at 30 min/wk anyway, so the cap costs a real user nothing.
    public static let maxMinutesPerSession = 240.0

    /// Sum session minutes into a weekly dose, discarding non-positive and capping each session.
    public static func weeklyMinutes(sessionMinutes: [Double]) -> Double {
        sessionMinutes.filter { $0 > 0 }.reduce(0) { $0 + min($1, maxMinutesPerSession) }
    }
}
