import SwiftUI
import StrandDesign
import StrandAnalytics

// HealthspanView.swift — Body Age and Pace of Aging on one screen, with the drivers behind them.
//
// Two numbers that answer different questions. Body Age says WHERE you are: the years your habits read
// as, against your own calendar age. Pace of Aging says WHERE YOU ARE HEADING: whether that number is
// climbing, holding, or coming down, as a multiple of ordinary time. Both come out of the one
// mortality-hazard model in `VitalityEngine` (see its header), and the pace is literally the drift of the
// same summed log-hazard the Body Age is derived from, so they cannot tell different stories.
//
// ── WHAT THIS SCREEN DELIBERATELY DOES NOT DO ──────────────────────────────────────────────────────
//
// It never states the Body Age twice. The headline is the STORED weekly value — the same row Trends, the
// Metric Explorer and the Today card read — and the driver rows below it show each input's value against
// its reference and which side of it that falls on. They do NOT carry a per-driver "adds 1.2 years",
// because a years figure recomputed here, over a window assembled here, would be a second answer to a
// question the headline has already answered, free to disagree with it. What a driver is worth in years
// lives in exactly one place: the engine that wrote the stored number.
//
// The pace is shown with the margin persisted beside it. When the fitted trend is not distinguishable
// from zero the screen says "holding steady" and shows no multiple at all — a pace is a promise about
// where someone is heading, and there is no promise to make from noise.
struct HealthspanView: View {
    var body: some View {
        ScreenScaffold(title: "Healthspan", subtitle: "Body Age & Pace of Aging") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                HealthspanHeroSection()
                HealthspanDriversSection()
                HealthspanAboutSection()
            }
        }
    }
}

// MARK: - Body Age + Pace heroes

private struct HealthspanHeroSection: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore

    @State private var bodyAge: Double?
    @State private var vitality: Double?
    @State private var pace: Double?
    @State private var paceMargin: Double?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Where you stand", overline: "Weekly")
            if let bodyAge {
                bodyAgeCard(bodyAge)
            } else if loaded {
                ComingSoon(what: "A few more days of wear and we can show your Body Age.", symbol: "figure.stand")
            } else {
                ComingSoon(what: "Reading your Body Age…", symbol: "figure.stand")
            }
            paceCard
        }
        .task(id: repo.refreshSeq) { await load() }
    }

    private func bodyAgeCard(_ years: Double) -> some View {
        let delta = Double(profile.age) - years
        let younger = delta >= 0
        let wholeYears = Int(abs(delta).rounded())
        return NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space3) {
                    VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                        Text("Body Age").strandOverline()
                        Text("\(Int(years.rounded()))")
                            .font(StrandFont.number(44))
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: NoopMetrics.space1) {
                        Text("Your age").strandOverline()
                        Text("\(profile.age)")
                            .font(StrandFont.number(28))
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                Text(deltaLine(years: wholeYears, younger: younger))
                    .font(StrandFont.headline)
                    .foregroundStyle(younger ? StrandPalette.statusPositive : StrandPalette.statusWarning)
                if let vitality {
                    Text("Vitality \(Int(vitality.rounded())) of 100")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Text("± \(Int(VitalityEngine.bandYears)) yrs · a wellness estimate from your habits, not a clinical biological age.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var paceCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("Pace of Aging").strandOverline()
                if let pace, let paceMargin {
                    // The margin is the 95% band the engine fitted. When it covers 1x the trend is not
                    // distinguishable from holding steady, and no multiple is shown — see the file header.
                    if abs(pace - 1) <= paceMargin {
                        Text("Holding steady")
                            .font(StrandFont.number(30))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Your recent habits are keeping your Body Age where it is.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(Self.multiple(pace))
                            .font(StrandFont.number(38))
                            .foregroundStyle(pace < 1 ? StrandPalette.statusPositive : StrandPalette.statusWarning)
                        Text(paceLine(pace))
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    paceScale(pace: pace)
                } else if loaded {
                    Text("Not enough history yet")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("The pace is a trend, not a snapshot: it needs about two months of wear before it can tell a direction from a quiet week.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Reading your pace…")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    /// The −1× … 3× scale with a marker at the fitted pace and a tick at 1× (holding steady).
    private func paceScale(pace: Double) -> some View {
        let lo = PaceOfAgingEngine.minPace, hi = PaceOfAgingEngine.maxPace
        let fraction = max(0, min(1, (pace - lo) / (hi - lo)))
        let steadyFraction = (1 - lo) / (hi - lo)
        return VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(StrandPalette.surfaceInset)
                    Capsule()
                        .fill(StrandPalette.hairlineStrong)
                        .frame(width: NoopMetrics.hairlineWidth)
                        .offset(x: geo.size.width * steadyFraction)
                    Circle()
                        .fill(pace < 1 ? StrandPalette.statusPositive : StrandPalette.statusWarning)
                        .frame(width: 12, height: 12)
                        .offset(x: max(0, geo.size.width * fraction - 6))
                }
            }
            .frame(height: 12)
            HStack {
                Text(Self.multiple(lo, decimals: 0))
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                Spacer()
                Text("1× steady").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                Spacer()
                Text(Self.multiple(hi, decimals: 0))
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Pace of aging \(Self.multiple(pace)), where 1× is holding steady"))
    }

    /// A bare multiple ("1.4×"). A number and a sign — nothing to translate, so it is formatted rather
    /// than carried through the String Catalog as copy.
    private static func multiple(_ value: Double, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f×", value)
    }

    /// Whole-phrase variants per direction, so translators never see a stitched fragment.
    private func paceLine(_ pace: Double) -> String {
        pace < 1
            ? String(localized: "Your recent habits are pulling your Body Age down.")
            : String(localized: "Your recent habits are pushing your Body Age up.")
    }

    private func deltaLine(years: Int, younger: Bool) -> String {
        if years == 0 { return String(localized: "About your age") }
        switch (younger, years == 1) {
        case (true, true):   return String(localized: "1 yr younger than your age")
        case (true, false):  return String(localized: "\(years) yrs younger than your age")
        case (false, true):  return String(localized: "1 yr older than your age")
        case (false, false): return String(localized: "\(years) yrs older than your age")
        }
    }

    private func load() async {
        bodyAge = (await repo.exploreSeries(key: "body_age", source: "my-whoop")).last?.value
        vitality = (await repo.exploreSeries(key: "vitality", source: "my-whoop")).last?.value
        pace = (await repo.exploreSeries(key: "pace_of_aging", source: "my-whoop")).last?.value
        paceMargin = (await repo.exploreSeries(key: "pace_of_aging_margin", source: "my-whoop")).last?.value
        loaded = true
    }
}

// MARK: - The one loader both Healthspan and the Health hub's Vitality card read

/// Assembles THIS WEEK's Healthspan drivers, once, for every screen that shows them.
///
/// It exists because there are two such screens, and before it there were two recipes: the Health hub's
/// Vitality card built its own six-driver inputs inline, so when the engine grew to ten the card kept
/// naming a "helping most" from a model the headline beside it was no longer computed with. The builder
/// itself (`IntelligenceEngine.healthspanInputs`) is the same one the analytics pass uses, so what a
/// screen shows and what the stored number was made of cannot drift apart either.
enum HealthspanDrivers {

    /// The per-driver contributions for the last 7 days of `repo`, or empty when nothing is measurable yet.
    @MainActor
    static func thisWeek(repo: Repository, age: Int, sex: String,
                         heightCm: Double) async -> [VitalityEngine.Contribution] {
        let last7 = Array(repo.days.suffix(7))
        guard !last7.isEmpty else { return [] }
        let days = last7.map { $0.day }
        async let moderateA = repo.exploreSeries(key: "zone_min_2_3", source: "my-whoop")
        async let vigorousA = repo.exploreSeries(key: "zone_min_4_5", source: "my-whoop")
        async let strengthA = repo.exploreSeries(key: "strength_min", source: "my-whoop")
        async let leanA = repo.exploreSeries(key: "lean_mass", source: "apple-health")
        let (moderate, vigorous, strength, lean) = await (moderateA, vigorousA, strengthA, leanA)

        let wanted = Set(days)
        func byDay(_ points: [(day: String, value: Double)]) -> [String: Double] {
            Dictionary(points.filter { wanted.contains($0.day) }.map { ($0.day, $0.value) },
                       uniquingKeysWith: { _, b in b })
        }
        let moderateByDay = byDay(moderate), vigorousByDay = byDay(vigorous)
        var zone: [String: (moderate: Double, vigorous: Double)] = [:]
        for day in days where moderateByDay[day] != nil || vigorousByDay[day] != nil {
            zone[day] = (moderate: moderateByDay[day] ?? 0, vigorous: vigorousByDay[day] ?? 0)
        }
        let inputs = IntelligenceEngine.healthspanInputs(
            days: last7, zone: zone, strength: byDay(strength),
            age: Double(age), sex: sex,
            heightCm: heightCm > 0 ? heightCm : nil,
            leanMassKg: lean.last?.value)
        return VitalityEngine.contributions(inputs)
    }
}

// MARK: - The drivers

/// Each input behind the Body Age: what it measured this week and the reference it is measured against.
/// Built through `IntelligenceEngine.healthspanInputs`, the SAME builder the analytics pass uses, so the
/// rows describe the inputs the stored headline was actually computed from rather than a second recipe.
private struct HealthspanDriversSection: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore

    @State private var contributions: [VitalityEngine.Contribution] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("What's behind it", overline: "Last 7 days")
            if contributions.isEmpty {
                ComingSoon(what: loaded
                    ? "Wear the strap for a few days and your drivers will appear here."
                    : "Reading your drivers…", symbol: "list.bullet")
            } else {
                ForEach(contributions, id: \.key) { row(for: $0) }
                if missing.isEmpty == false {
                    Text("Not measured: \(missing.joined(separator: ", ")). Connect Apple Health or add the missing profile details to include them.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task(id: repo.refreshSeq) { await load() }
    }

    private func row(for c: VitalityEngine.Contribution) -> some View {
        NoopCard {
            HStack(alignment: .center, spacing: NoopMetrics.space3) {
                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    Text(Self.driverLabel(c))
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("\(format(c.value, c)) · target \(format(c.target, c))")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer(minLength: NoopMetrics.space2)
                Text(statusLabel(c))
                    .font(StrandFont.caption)
                    .foregroundStyle(statusTint(c))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(Self.driverLabel(c)). \(format(c.value, c)), target \(format(c.target, c)). \(statusLabel(c))")
    }

    /// A driver's display name.
    ///
    /// Mapped from the key here rather than taken from `Contribution.label`: that label is authored inside
    /// the platform-pure analytics package, which ships no string catalog, so rendering it would put the
    /// one word naming each row into English on every device regardless of locale. The key is the stable
    /// identifier; the name belongs to the screen.
    static func driverLabel(_ c: VitalityEngine.Contribution) -> String {
        switch c.key {
        case "rhr":         return String(localized: "Resting heart rate")
        case "vo2max":      return String(localized: "Cardio fitness")
        case "sleep":       return String(localized: "Sleep duration")
        case "consistency": return String(localized: "Sleep regularity")
        case "hrv":         return String(localized: "Heart-rate variability")
        case "steps":       return String(localized: "Daily steps")
        case "moderate":    return String(localized: "Moderate cardio")
        case "vigorous":    return String(localized: "Vigorous cardio")
        case "strength":    return String(localized: "Strength training")
        case "leanmass":    return String(localized: "Lean mass")
        default:            return c.label
        }
    }

    /// A driver's standing against its own reference, from the sign of its log-hazard — the same quantity
    /// the engine scored it on, so the chip cannot disagree with the number it sits beside.
    private func statusLabel(_ c: VitalityEngine.Contribution) -> String {
        if c.lnHazard < -0.001 { return String(localized: "Ahead of target") }
        if c.lnHazard > 0.001 { return String(localized: "Below target") }
        return String(localized: "On target")
    }

    private func statusTint(_ c: VitalityEngine.Contribution) -> Color {
        if c.lnHazard < -0.001 { return StrandPalette.statusPositive }
        if c.lnHazard > 0.001 { return StrandPalette.statusWarning }
        return StrandPalette.textSecondary
    }

    private func format(_ value: Double, _ c: VitalityEngine.Contribution) -> String {
        let rounded: String
        switch c.key {
        case "steps":       rounded = "\(Int(value.rounded()))"
        case "consistency": return "\(Int((value * 100).rounded()))%"
        case "sleep":       rounded = String(format: "%.1f", value)
        default:            rounded = "\(Int(value.rounded()))"
        }
        return c.unit.isEmpty ? rounded : "\(rounded) \(c.unit)"
    }

    /// Drivers with no reading at all this week, named so the absence is visible rather than silent.
    private var missing: [String] {
        let present = Set(contributions.map { $0.key })
        return [("moderate", String(localized: "Moderate cardio")),
                ("vigorous", String(localized: "Vigorous cardio")),
                ("strength", String(localized: "Strength training")),
                ("leanmass", String(localized: "Lean mass")),
                ("vo2max", String(localized: "Cardio fitness"))]
            .filter { !present.contains($0.0) }
            .map { $0.1 }
    }

    private func load() async {
        contributions = await HealthspanDrivers.thisWeek(
            repo: repo, age: profile.age, sex: profile.sex, heightCm: profile.heightCm)
        loaded = true
    }
}

// MARK: - What this is

private struct HealthspanAboutSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("How this is worked out", overline: "On \(Platform.deviceNounPhrase)")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    Text("Every driver above is matched to its published all-cause-mortality hazard ratio from large cohort studies, and the combined result is converted into years using the rate at which mortality risk doubles with age.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Drivers that measure the same thing are not counted twice: your steps, cardio minutes and strength minutes are four views of how much you move, and they are weighed against each other before they count.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Nothing here leaves this \(Platform.deviceNounPhrase), and none of it is medical advice.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
