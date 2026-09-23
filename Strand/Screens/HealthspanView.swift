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

/// One driver behind the stored Body Age, as the pipeline persisted it for the headline's day.
struct HealthspanDriver: Equatable {
    let key: String
    /// This driver's share of the Body Age offset, years (positive = adds to Body Age).
    let years: Double
    /// The six-month value it was scored from, and the target that scores zero.
    let value: Double
    let target: Double
    /// The last-30-day value, when that window had one — the driver behind the pace.
    let recent: Double?
}

/// Reads the drivers behind the stored headline, once, for every screen that shows them.
///
/// Every figure comes from the rows `IntelligenceEngine.recomputeHealthspan` wrote for the SAME day as the
/// headline (`HealthspanSeries`), so a driver's years are exactly the share that headline was summed from.
/// Nothing is recomputed here: a second computation over a window assembled on a screen would be a second
/// answer to a question the headline has already answered, free to disagree with it.
enum HealthspanDrivers {

    /// The drivers for the newest day carrying a Body Age, sorted most-costly first; empty when none.
    @MainActor
    static func latest(repo: Repository) async -> [HealthspanDriver] {
        guard let day = await repo.exploreSeries(key: HealthspanSeries.bodyAge, source: "my-whoop").last?.day
        else { return [] }
        func on(_ key: String) async -> Double? {
            await repo.exploreSeries(key: key, source: "my-whoop").last { $0.day == day }?.value
        }
        var out: [HealthspanDriver] = []
        for key in HealthspanSeries.drivers {
            guard let years = await on(HealthspanSeries.years(key)),
                  let value = await on(HealthspanSeries.value(key)),
                  let target = await on(HealthspanSeries.target(key)) else { continue }
            out.append(HealthspanDriver(key: key, years: years, value: value, target: target,
                                        recent: await on(HealthspanSeries.recent(key))))
        }
        return out.sorted { $0.years > $1.years }
    }

    /// A driver's display name.
    ///
    /// Mapped from the key here rather than taken from `VitalityEngine.Contribution.label`: that label is
    /// authored inside the platform-pure analytics package, which ships no string catalog, so rendering it
    /// would put the one word naming each row into English on every device regardless of locale.
    static func label(_ key: String) -> String {
        switch key {
        case "rhr":         return String(localized: "Resting heart rate")
        case "vo2max":      return String(localized: "Cardio fitness")
        case "sleep":       return String(localized: "Sleep duration")
        case "consistency": return String(localized: "Sleep regularity")
        case "steps":       return String(localized: "Daily steps")
        case "moderate":    return String(localized: "Moderate cardio")
        case "vigorous":    return String(localized: "Vigorous cardio")
        case "strength":    return String(localized: "Strength training")
        case "leanmass":    return String(localized: "Lean mass")
        default:            return key
        }
    }
}

// MARK: - The drivers

/// Each driver behind the Body Age: its six-month value against its target, and which side it falls on.
/// Read from the persisted rows behind the stored headline (`HealthspanDrivers.latest`).
private struct HealthspanDriversSection: View {
    @EnvironmentObject var repo: Repository

    @State private var drivers: [HealthspanDriver] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("What's behind it", overline: "6 months")
            if drivers.isEmpty {
                ComingSoon(what: loaded
                    ? "Wear the strap for a few days and your drivers will appear here."
                    : "Reading your drivers…", symbol: "list.bullet")
            } else {
                ForEach(drivers, id: \.key) { row(for: $0) }
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

    private func row(for d: HealthspanDriver) -> some View {
        NoopCard {
            HStack(alignment: .center, spacing: NoopMetrics.space3) {
                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    Text(HealthspanDrivers.label(d.key))
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("\(Self.format(d.value, d.key)) · target \(Self.format(d.target, d.key))")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer(minLength: NoopMetrics.space2)
                Text(Self.statusLabel(d))
                    .font(StrandFont.caption)
                    .foregroundStyle(statusTint(d))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(HealthspanDrivers.label(d.key)). \(Self.format(d.value, d.key)), target \(Self.format(d.target, d.key)). \(Self.statusLabel(d))")
    }

    /// A driver's standing against its own target, from the sign of its persisted years — the same
    /// quantity the headline was summed from, so the chip cannot disagree with the number.
    ///
    /// The costly side names the DIRECTION the value sits from its target rather than a fixed word: a
    /// resting HR above target and steps below target are both costly, and saying "Below target" for
    /// both would be false for one of them.
    static func statusLabel(_ d: HealthspanDriver) -> String {
        if d.years < -0.01 { return String(localized: "Better than target") }
        if d.years > 0.01 {
            return d.value > d.target
                ? String(localized: "Above target")
                : String(localized: "Below target")
        }
        return String(localized: "On target")
    }

    private func statusTint(_ d: HealthspanDriver) -> Color {
        if d.years < -0.01 { return StrandPalette.statusPositive }
        if d.years > 0.01 { return StrandPalette.statusWarning }
        return StrandPalette.textSecondary
    }

    static func format(_ value: Double, _ key: String) -> String {
        switch key {
        case "steps":       return "\(Int(value.rounded())) steps/day"
        case "sleep":       return String(format: "%.1f h", value)
        case "consistency": return "SRI \(Int(value.rounded()))"
        case "rhr":         return "\(Int(value.rounded())) bpm"
        case "vo2max":      return String(format: "%.1f ml/kg/min", value)
        case "leanmass":    return "\(Int(value.rounded()))%"
        default:            return "\(Int(value.rounded())) min/wk"
        }
    }

    /// Drivers with no reading at all, named so the absence is visible rather than silent.
    private var missing: [String] {
        let present = Set(drivers.map { $0.key })
        return ["moderate", "vigorous", "strength", "leanmass", "vo2max"]
            .filter { !present.contains($0) }
            .map(HealthspanDrivers.label)
    }

    private func load() async {
        drivers = await HealthspanDrivers.latest(repo: repo)
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
