import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import WhoopStore

// HealthspanView.swift — Body Age and Pace of Aging on one screen, with the drivers behind them.
//
// Two numbers that answer different questions. Body Age says WHERE you are: the years your last six
// months of habits read as, against health targets (meeting every target reads as your own age). Pace of
// Aging says WHERE YOU ARE HEADING: how fast that number would move over the next six months if your last
// 30 days held. Both come out of the one mortality-hazard model in `VitalityEngine`.
//
// ── ONE STORED POINT PER DAY, READ ONCE ──────────────────────────────────────────────────────────────
//
// Every readout here — the hero, the dial, each driver's years chip, the biggest lever and the trend
// charts — reads the rows `IntelligenceEngine.recomputeHealthspan` persisted, through ONE loader
// (`HealthspanSnapshot.load`) called once per refresh and handed down. The driver chips are the exact
// shares the headline was summed from, and the chart's last point IS the headline, so no two readouts on
// this screen can disagree. Nothing is recomputed from raw days here. (The driver-detail sheet draws each
// driver's published CURVE from the engine, which is a statement about the evidence, not about the user.)
//
// The pace is shown with the margin persisted beside it. When the margin covers 1× the screen says
// "holding steady" and shows no multiple — a pace is a promise about where someone is heading, and there
// is no promise to make from noise.
struct HealthspanView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore

    @State private var snapshot: HealthspanSnapshot?
    @State private var unlock = HealthspanUnlock(scoredDays: 0, age: 0)
    @State private var hrv: (value: Double, norm: Double)?
    @State private var loaded = false
    @AppStorage(ResiliencePrefs.enabledKey) private var resilienceEnabled = false

    var body: some View {
        ScreenScaffold(title: "Healthspan", subtitle: "Body Age & Pace of Aging") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                HealthspanHeroSection(snapshot: snapshot, unlock: unlock, loaded: loaded, age: profile.age)
                if let snapshot {
                    HealthspanPaceSection(snapshot: snapshot)
                    HealthspanLeverSection(snapshot: snapshot)
                    HealthspanDriversSection(snapshot: snapshot, age: Double(profile.age), sex: profile.sex)
                    HealthspanTrendSection(snapshot: snapshot)
                }
                if let hrv { HealthspanContextSection(hrv: hrv.value, norm: hrv.norm) }
                if resilienceEnabled { ResilienceSection() }
                HealthspanAboutSection()
            }
        }
        .task(id: repo.refreshSeq) { await load() }
    }

    private func load() async {
        snapshot = await HealthspanSnapshot.load(repo: repo)
        unlock = HealthspanUnlock.current(days: repo.days, age: Double(profile.age))
        let last30 = repo.days.suffix(30).compactMap { $0.avgHrv }
        hrv = IntelligenceEngine.healthspanMedian(last30).map {
            ($0, VitalityEngine.rmssdNorm(forAge: Double(profile.age)))
        }
        loaded = true
    }
}

// MARK: - The one loader

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

/// Everything this screen shows, read once from the persisted Healthspan rows for the newest day.
struct HealthspanSnapshot {
    let day: String
    let bodyAge: Double
    let vitality: Double?
    let pace: Double?
    let paceMargin: Double?
    let projectedBodyAge: Double?
    /// Most costly first.
    let drivers: [HealthspanDriver]
    /// Up to six months, oldest first; the last point is the headline's day.
    let bodyAgeTrend: [(day: String, value: Double)]
    let paceTrend: [(day: String, value: Double)]

    /// The driver whose target would take the most years off — exactly its persisted share, since
    /// reaching the target zeroes it (the engine's shrink is linear).
    var lever: HealthspanDriver? {
        drivers.filter { $0.years >= VitalityEngine.minLeverYears }.max { $0.years < $1.years }
    }

    /// Nil when no Body Age has been stored yet.
    @MainActor
    static func load(repo: Repository) async -> HealthspanSnapshot? {
        let window = PaceOfAgingEngine.baselineWindowDays + 14
        func series(_ key: String) async -> [(day: String, value: Double)] {
            await repo.exploreSeries(key: key, source: "my-whoop", days: window)
        }
        let ages = await series(HealthspanSeries.bodyAge)
        guard let head = ages.last else { return nil }
        func on(_ key: String) async -> Double? { await series(key).last { $0.day == head.day }?.value }

        var drivers: [HealthspanDriver] = []
        for key in HealthspanSeries.drivers {
            guard let years = await on(HealthspanSeries.years(key)),
                  let value = await on(HealthspanSeries.value(key)),
                  let target = await on(HealthspanSeries.target(key)) else { continue }
            drivers.append(HealthspanDriver(key: key, years: years, value: value, target: target,
                                            recent: await on(HealthspanSeries.recent(key))))
        }
        let paces = await series(HealthspanSeries.pace)
        return HealthspanSnapshot(
            day: head.day, bodyAge: head.value,
            vitality: await on(HealthspanSeries.vitality),
            pace: paces.last { $0.day == head.day }?.value,
            paceMargin: await on(HealthspanSeries.paceMargin),
            projectedBodyAge: await on(HealthspanSeries.projectedBodyAge),
            drivers: drivers.sorted { $0.years > $1.years },
            bodyAgeTrend: ages.filter { $0.day <= head.day },
            paceTrend: paces.filter { $0.day <= head.day })
    }
}

/// The drivers behind the stored headline, for screens other than this one (the Health hub's card).
enum HealthspanDrivers {

    @MainActor
    static func latest(repo: Repository) async -> [HealthspanDriver] {
        await HealthspanSnapshot.load(repo: repo)?.drivers ?? []
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
        case "moderate":    return String(localized: "Zones 1–3 cardio")
        case "vigorous":    return String(localized: "Zones 4–5 cardio")
        case "strength":    return String(localized: "Strength training")
        case "leanmass":    return String(localized: "Lean mass")
        default:            return key
        }
    }

    /// A value in its driver's unit. Units and numbers only — nothing to translate.
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

    /// The target as a user reads it: sleep's is a band, the others a single value.
    static func formatTarget(_ d: HealthspanDriver) -> String {
        d.key == "sleep"
            ? String(format: "%.0f–%.0f h", VitalityEngine.sleepTargetLow, VitalityEngine.sleepTargetHigh)
            : format(d.target, d.key)
    }

    /// A signed years figure ("+1.2 yrs", "−0.4 yrs").
    static func years(_ y: Double) -> String {
        let sign = y > 0.05 ? "+" : (y < -0.05 ? "−" : "")
        return String(localized: "\(sign + String(format: "%.1f", abs(y))) yrs")
    }
}

/// The 21-scored-days-in-31 gate, counted from the same daily rows the pipeline gates on.
struct HealthspanUnlock {
    let scoredDays: Int
    let age: Double
    var status: (unlocked: Bool, daysUntilUnlock: Int) {
        VitalityEngine.unlockStatus(scoredDaysInWindow: scoredDays, age: age)
    }

    @MainActor
    static func current(days: [DailyMetric], age: Double) -> HealthspanUnlock {
        guard let today = PaceOfAgingEngine.dayIndex(Repository.dayString(Date())) else {
            return HealthspanUnlock(scoredDays: 0, age: age)
        }
        let window = (today - VitalityEngine.unlockWindowDays + 1)...today
        let scored = days.filter {
            $0.restingHr != nil && PaceOfAgingEngine.dayIndex($0.day).map(window.contains) == true
        }.count
        return HealthspanUnlock(scoredDays: scored, age: age)
    }
}

/// The two pure display decisions the screen makes from the persisted rows, kept out of the views so they
/// are testable.
enum HealthspanReadout {

    /// WHOOP's four readings of the −1× … 3× scale. `steady` is decided by the margin, not a band edge:
    /// when the ± band covers 1× there is no direction to report.
    enum Band { case reversing, slowing, steady, accelerating }

    static func band(pace: Double, margin: Double) -> Band {
        if abs(pace - 1) <= margin { return .steady }
        if pace < 0 { return .reversing }
        return pace < 1 ? .slowing : .accelerating
    }

    enum Trend { case better, worse }

    /// Whether the last 30 days sit closer to (or further past) the target than the six months do — the
    /// driver behind the pace. Nil when the change is too small to call (under 3 % of the target) or the
    /// 30-day window had no reading.
    static func trend(_ d: HealthspanDriver) -> Trend? {
        guard let recent = d.recent else { return nil }
        let tolerance = abs(d.target) * 0.03
        let change: Double
        switch d.key {
        case "rhr":
            change = d.value - recent                      // lower is better
        case "sleep":
            // Better is closer to the 7–9 h band.
            func gap(_ h: Double) -> Double {
                max(0, VitalityEngine.sleepTargetLow - h, h - VitalityEngine.sleepTargetHigh)
            }
            change = gap(d.value) - gap(recent)
        default:
            change = recent - d.value                      // higher is better
        }
        if abs(change) < tolerance { return nil }
        return change > 0 ? .better : .worse
    }
}

// MARK: - Hero

private struct HealthspanHeroSection: View {
    let snapshot: HealthspanSnapshot?
    let unlock: HealthspanUnlock
    let loaded: Bool
    let age: Int

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Where you stand", overline: "6 months")
            if let snapshot {
                bodyAgeCard(snapshot)
            } else if loaded {
                unlockCard
            } else {
                ComingSoon(what: "Reading your Body Age…", symbol: "figure.stand")
            }
        }
    }

    private func bodyAgeCard(_ s: HealthspanSnapshot) -> some View {
        let delta = Double(age) - s.bodyAge
        let younger = delta >= 0
        let wholeYears = Int(abs(delta).rounded())
        return NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space3) {
                    VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                        Text("Body Age").strandOverline()
                        Text(String(format: "%.1f", s.bodyAge))
                            .font(StrandFont.number(44))
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: NoopMetrics.space1) {
                        Text("Your age").strandOverline()
                        Text("\(age)")
                            .font(StrandFont.number(28))
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                Text(deltaLine(years: wholeYears, younger: younger))
                    .font(StrandFont.headline)
                    .foregroundStyle(younger ? StrandPalette.statusPositive : StrandPalette.statusWarning)
                if let vitality = s.vitality {
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

    /// Before the first Body Age: how far off it is, counted on the same gate the pipeline applies.
    private var unlockCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("Body Age").strandOverline()
                if unlock.age < VitalityEngine.minAge {
                    Text("Healthspan is for adults 18 and over.")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                } else {
                    Text("\(min(unlock.scoredDays, VitalityEngine.unlockMinScoredDays)) of \(VitalityEngine.unlockMinScoredDays) scored days in the last 31")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    ProgressView(value: Double(min(unlock.scoredDays, VitalityEngine.unlockMinScoredDays)),
                                 total: Double(VitalityEngine.unlockMinScoredDays))
                        .tint(StrandPalette.accent)
                    Text("Body Age compares your last six months with health targets. Keep wearing the strap overnight.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
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
}

// MARK: - Pace dial

private struct HealthspanPaceSection: View {
    let snapshot: HealthspanSnapshot

    typealias Band = HealthspanReadout.Band

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("Pace of Aging").strandOverline()
                if let pace = snapshot.pace, let margin = snapshot.paceMargin {
                    let band = HealthspanReadout.band(pace: pace, margin: margin)
                    HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                        Text(band == .steady ? String(localized: "Holding steady") : Self.multiple(pace))
                            .font(StrandFont.number(band == .steady ? 30 : 38))
                            .foregroundStyle(tint(band))
                        Spacer(minLength: 0)
                        Text(bandName(band))
                            .font(StrandFont.caption)
                            .foregroundStyle(tint(band))
                    }
                    Text(line(band))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    scale(pace: pace)
                    Text("± \(Self.multiple(margin)) · if your last 30 days hold for six months")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                    if let projected = snapshot.projectedBodyAge {
                        Text("Projected Body Age in six months: \(String(format: "%.1f", projected))")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                } else {
                    Text("Not enough history yet")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("The pace compares your last 30 days with your last six months, so it appears once both can be scored.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func tint(_ band: Band) -> Color {
        switch band {
        case .reversing, .slowing: return StrandPalette.statusPositive
        case .steady:              return StrandPalette.textPrimary
        case .accelerating:        return StrandPalette.statusWarning
        }
    }

    private func bandName(_ band: Band) -> String {
        switch band {
        case .reversing:    return String(localized: "Reversing")
        case .slowing:      return String(localized: "Slowing")
        case .steady:       return String(localized: "Steady")
        case .accelerating: return String(localized: "Accelerating")
        }
    }

    /// Whole-phrase variants per band, so translators never see a stitched fragment.
    private func line(_ band: Band) -> String {
        switch band {
        case .steady:       return String(localized: "Your recent habits are keeping your Body Age where it is.")
        case .accelerating: return String(localized: "Your recent habits are pushing your Body Age up.")
        case .reversing, .slowing: return String(localized: "Your recent habits are pulling your Body Age down.")
        }
    }

    /// The −1× … 3× scale in its four bands, a marker at the pace and a tick at 1× (holding steady).
    private func scale(pace: Double) -> some View {
        let lo = PaceOfAgingEngine.minPace, hi = PaceOfAgingEngine.maxPace
        let x: (Double) -> Double = { max(0, min(1, ($0 - lo) / (hi - lo))) }
        let segments: [(from: Double, to: Double, color: Color)] = [
            (lo, 0, StrandPalette.statusPositive.opacity(0.55)),
            (0, 1, StrandPalette.statusPositive.opacity(0.25)),
            (1, hi, StrandPalette.statusWarning.opacity(0.3)),
        ]
        return VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    ForEach(segments.indices, id: \.self) { i in
                        let s = segments[i]
                        Capsule().fill(s.color)
                            .frame(width: geo.size.width * (x(s.to) - x(s.from)))
                            .offset(x: geo.size.width * x(s.from))
                    }
                    Capsule()
                        .fill(StrandPalette.hairlineStrong)
                        .frame(width: NoopMetrics.hairlineWidth)
                        .offset(x: geo.size.width * x(1))
                    Circle()
                        .fill(pace <= 1 ? StrandPalette.statusPositive : StrandPalette.statusWarning)
                        .frame(width: NoopMetrics.space3, height: NoopMetrics.space3)
                        .offset(x: max(0, geo.size.width * x(pace) - NoopMetrics.space3 / 2))
                }
            }
            .frame(height: NoopMetrics.space3)
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

    /// A bare multiple ("1.4×"). A number and a sign — nothing to translate.
    static func multiple(_ value: Double, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f×", value)
    }
}

// MARK: - Biggest lever

private struct HealthspanLeverSection: View {
    let snapshot: HealthspanSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Biggest lever")
            NoopCard {
                HStack(alignment: .top, spacing: NoopMetrics.space3) {
                    Image(systemName: "arrow.down.forward.circle")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.statusPositive)
                    if let lever = snapshot.lever {
                        Text("Reaching your target for \(HealthspanDrivers.label(lever.key)) would take about \(String(format: "%.1f", lever.years)) years off your Body Age.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Every driver is on target. Nothing is costing you years.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

// MARK: - The drivers

/// Each driver behind the Body Age: its six-month value against its target, the years it is worth, and
/// whether the last 30 days are moving it. Every figure is a persisted row behind the headline.
private struct HealthspanDriversSection: View {
    let snapshot: HealthspanSnapshot
    let age: Double
    let sex: String

    @State private var detail: HealthspanDriver?

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("What's behind it", overline: "6 months")
            ForEach(snapshot.drivers, id: \.key) { d in
                Button { detail = d } label: { row(for: d) }
                    .buttonStyle(.plain)
            }
            if missing.isEmpty == false {
                Text("Not measured: \(missing.joined(separator: ", ")). Connect Apple Health or add the missing profile details to include them.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(item: Binding(get: { detail.map(DetailID.init) }, set: { detail = $0?.driver })) { item in
            HealthspanDriverDetail(driver: item.driver, age: age, sex: sex) { detail = nil }
        }
    }

    private struct DetailID: Identifiable {
        let driver: HealthspanDriver
        var id: String { driver.key }
    }

    private func row(for d: HealthspanDriver) -> some View {
        NoopCard {
            HStack(alignment: .center, spacing: NoopMetrics.space3) {
                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    HStack(spacing: NoopMetrics.space1) {
                        Text(HealthspanDrivers.label(d.key))
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        if let trend = HealthspanReadout.trend(d) {
                            Image(systemName: trend == .better ? "arrow.up.right" : "arrow.down.right")
                                .font(StrandFont.caption)
                                .foregroundStyle(trend == .better ? StrandPalette.statusPositive
                                                                  : StrandPalette.statusWarning)
                                .accessibilityLabel(trend == .better ? Text("Last 30 days: better")
                                                                     : Text("Last 30 days: worse"))
                        }
                    }
                    Text("\(HealthspanDrivers.format(d.value, d.key)) · target \(HealthspanDrivers.formatTarget(d))")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer(minLength: NoopMetrics.space2)
                Text(HealthspanDrivers.years(d.years))
                    .font(StrandFont.caption)
                    .foregroundStyle(tint(d))
                    .padding(.horizontal, NoopMetrics.space2)
                    .padding(.vertical, NoopMetrics.spaceHalf)
                    .background(tint(d).opacity(0.14), in: Capsule(style: .continuous))
                Image(systemName: "chevron.right")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func tint(_ d: HealthspanDriver) -> Color {
        if d.years < -0.05 { return StrandPalette.statusPositive }
        if d.years > 0.05 { return StrandPalette.statusWarning }
        return StrandPalette.textSecondary
    }

    private var missing: [String] {
        let present = Set(snapshot.drivers.map { $0.key })
        return ["moderate", "vigorous", "strength", "leanmass", "vo2max"]
            .filter { !present.contains($0) }
            .map(HealthspanDrivers.label)
    }
}

/// One driver's published curve (hazard ratio against its target) with the user's value marked, and the
/// evidence it comes from.
private struct HealthspanDriverDetail: View {
    let driver: HealthspanDriver
    let age: Double
    let sex: String
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    NoopCard {
                        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                            Text("Risk against your target").strandOverline()
                            chart
                            Text("1.0 is your target. Above the line costs years; below it helps.")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    NoopCard {
                        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                            Text("\(HealthspanDrivers.format(driver.value, driver.key)) · target \(HealthspanDrivers.formatTarget(driver))")
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text(HealthspanDrivers.years(driver.years))
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                            Text("Source").strandOverline()
                            Text(verbatim: Self.citation(driver.key))
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(NoopMetrics.screenPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle(HealthspanDrivers.label(driver.key))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onClose).foregroundStyle(StrandPalette.accent)
                }
                #else
                ToolbarItem { Button("Done", action: onClose).foregroundStyle(StrandPalette.accent) }
                #endif
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 460)
        #endif
    }

    private var chart: some View {
        let curve = Self.curve(driver.key, age: age, sex: sex)
        let points = curve.map { c in
            stride(from: c.domain.lowerBound, through: c.domain.upperBound,
                   by: (c.domain.upperBound - c.domain.lowerBound) / 80).map { (x: $0, hr: exp(c.f($0))) }
        } ?? []
        let clamped = curve.map { min(max(driver.value, $0.domain.lowerBound), $0.domain.upperBound) }
        return Chart {
            ForEach(points, id: \.x) { p in
                LineMark(x: .value("Value", p.x), y: .value("Hazard ratio", p.hr))
                    .foregroundStyle(StrandPalette.accent)
            }
            RuleMark(y: .value("Target", 1.0))
                .foregroundStyle(StrandPalette.hairlineStrong)
                .lineStyle(StrokeStyle(lineWidth: NoopMetrics.hairlineWidth, dash: [4, 4]))
            if let c = curve, let x = clamped {
                PointMark(x: .value("Value", x), y: .value("Hazard ratio", exp(c.f(x))))
                    .foregroundStyle(driver.years > 0.05 ? StrandPalette.statusWarning : StrandPalette.statusPositive)
                    .symbolSize(80)
            }
        }
        .frame(height: 200)
        .accessibilityLabel(Text("Hazard ratio curve for \(HealthspanDrivers.label(driver.key))"))
    }

    /// The engine curve for a driver over a readable domain. The same functions the score uses, drawn
    /// before any overlap correction — a picture of the evidence, not a second computation of the user.
    static func curve(_ key: String, age: Double, sex: String)
        -> (domain: ClosedRange<Double>, f: (Double) -> Double)? {
        switch key {
        case "rhr":         return (40...110, { VitalityEngine.restingHRLnHazard(bpm: $0, sex: sex) })
        case "vo2max":
            let t = VitalityEngine.vo2maxTarget(age: age, sex: sex)
            return (15...70, { VitalityEngine.vo2maxLnHazard(vo2max: $0, target: t) })
        case "sleep":       return (3...12, { VitalityEngine.sleepDurationLnHazard(hours: $0) })
        case "consistency": return (20...100, { VitalityEngine.sriLnHazard(sri: $0) })
        case "steps":       return (0...15000, { VitalityEngine.stepsLnHazard(steps: $0, age: age) })
        case "moderate":    return (0...400, { VitalityEngine.moderateLnHazard(minPerWeek: $0, age: age) })
        case "vigorous":    return (0...90, { VitalityEngine.vigorousLnHazard(minPerWeek: $0, age: age) })
        case "strength":    return (0...200, { VitalityEngine.strengthLnHazard(minPerWeek: $0) })
        case "leanmass":    return (50...95, { VitalityEngine.leanMassLnHazard(percent: $0, age: age, sex: sex) })
        default:            return nil
        }
    }

    /// The study behind each curve (bibliographic, so not translated).
    static func citation(_ key: String) -> String {
        switch key {
        case "rhr":         return "Zhang D et al., CMAJ 2016 (PMID 26598376); Aune D et al., Nutr Metab Cardiovasc Dis 2017 (PMID 28552551). +12 % all-cause mortality per +10 bpm."
        case "vo2max":      return "Kokkinos P et al., JACC 2022 (PMID 35926933); Lang JJ et al., Br J Sports Med 2024 (PMID 38599681); Mandsager K et al., JAMA Netw Open 2018. About 13 % lower mortality per MET."
        case "sleep":       return "UK Biobank device-measured sleep, J Gerontol A 2023 (doi 10.1093/gerona/glad108); Yin J et al., J Am Heart Assoc 2017. Short sleep HR 1.27, long 1.16 per hour outside 7–9 h."
        case "consistency": return "Windred DP et al., SLEEP 2024 (doi 10.1093/sleep/zsad253); Cribb L et al., eLife 2023. Least regular quintile carries most of the hazard."
        case "steps":       return "Paluch AE et al., Lancet Public Health 2022 (doi 10.1016/S2468-2667(21)00302-9); Banach M et al., Eur J Prev Cardiol 2023."
        case "moderate":    return "Ekelund U et al., BMJ 2019 (doi 10.1136/bmj.l4570); Lee DH et al., Circulation 2022. Heart-rate-reserve zones 1–3."
        case "vigorous":    return "Ahmadi MN et al., Eur Heart J 2022 (doi 10.1093/eurheartj/ehac572); Stamatakis E et al., Nat Med 2022. 15 min/wk HR 0.82, 54 min/wk HR 0.64."
        case "strength":    return "Momma H et al., Br J Sports Med 2022 (doi 10.1136/bjsports-2021-105061). Benefit plateaus near 40–60 min/wk."
        case "leanmass":    return "Fat-free mass meta-analysis, J Cachexia Sarcopenia Muscle 2026 (doi 10.1002/jcsm.70331). Lean mass is an imported estimate, so this driver is the least certain."
        default:            return ""
        }
    }
}

// MARK: - Trend

private struct HealthspanTrendSection: View {
    let snapshot: HealthspanSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Trend", overline: "6 months")
            if snapshot.bodyAgeTrend.count >= 2 {
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        Text("Body Age").strandOverline()
                        TrendChart(points: points(snapshot.bodyAgeTrend),
                                   gradient: Gradient(colors: [StrandPalette.chargeColor.opacity(0.55),
                                                               StrandPalette.chargeColor]),
                                   valueRange: domain(snapshot.bodyAgeTrend, pad: 1),
                                   showsArea: false, height: 160,
                                   valueFormat: { String(format: "%.1f", $0) },
                                   accessibilityLabel: String(localized: "Body Age over six months"),
                                   yDomain: domain(snapshot.bodyAgeTrend, pad: 1))
                    }
                }
            }
            if snapshot.paceTrend.count >= 2 {
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        Text("Pace of Aging").strandOverline()
                        TrendChart(points: points(snapshot.paceTrend),
                                   gradient: Gradient(colors: [StrandPalette.statusPositive,
                                                               StrandPalette.statusWarning]),
                                   valueRange: PaceOfAgingEngine.minPace...PaceOfAgingEngine.maxPace,
                                   showsArea: false, baselineValue: 1, height: 140,
                                   valueFormat: { String(format: "%.1f×", $0) },
                                   accessibilityLabel: String(localized: "Pace of Aging over six months"))
                    }
                }
            }
        }
    }

    private func points(_ series: [(day: String, value: Double)]) -> [TrendPoint] {
        series.compactMap { p in
            PaceOfAgingEngine.dayIndex(p.day).map {
                TrendPoint(date: Date(timeIntervalSince1970: TimeInterval($0) * 86_400 + 43_200), value: p.value)
            }
        }
    }

    private func domain(_ series: [(day: String, value: Double)], pad: Double) -> ClosedRange<Double> {
        let values = series.map(\.value)
        let lo = (values.min() ?? 0) - pad, hi = (values.max() ?? 0) + pad
        return lo...max(hi, lo + 1)
    }
}

// MARK: - Context (not scored)

private struct HealthspanContextSection: View {
    let hrv: Double
    let norm: Double

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Context", overline: "Not scored")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    Text("Heart-rate variability")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("\(String(Int(hrv.rounded()))) ms over the last 30 days · typical for your age \(String(Int(norm.rounded()))) ms")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Text("Shown for context only. HRV is not a driver: its link to lifespan does not hold up as cause and effect.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Method

private struct HealthspanAboutSection: View {
    @State private var showMethod = false

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("How this is worked out", overline: "On \(Platform.deviceNounPhrase)")
            Button { showMethod = true } label: {
                NoopCard {
                    HStack(spacing: NoopMetrics.space3) {
                        Image(systemName: "function")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.accent)
                        Text("Method and references")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer(minLength: NoopMetrics.space2)
                        Image(systemName: "chevron.right")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
            .buttonStyle(.plain)
            Text("Nothing here leaves this \(Platform.deviceNounPhrase), and none of it is medical advice.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $showMethod) { HealthspanMethodSheet { showMethod = false } }
    }
}

private struct HealthspanMethodSheet: View {
    let onClose: () -> Void

    private static let references = [
        "WHOOP, The WHOOP Healthspan Feature, white paper rev. 2025-09-04",
        "Spiegelhalter D, BMC Med Inform Decis Mak 2016;16:104",
        "Windred DP et al., SLEEP 2024;47(1):zsad253",
        "Cribb L et al., eLife 2023",
        "UK Biobank device-measured sleep, J Gerontol A 2023",
        "Ahmadi MN et al., Eur Heart J 2022",
        "Stamatakis E et al., Nat Med 2022",
        "Ekelund U et al., BMJ 2019",
        "Lee DH et al., Circulation 2022",
        "Momma H et al., Br J Sports Med 2022",
        "Paluch AE et al., Lancet Public Health 2022",
        "Kokkinos P et al., JACC 2022; Lang JJ et al., Br J Sports Med 2024",
        "Zhang D et al., CMAJ 2016; Aune D et al., Nutr Metab Cardiovasc Dis 2017",
        "Fat-free mass meta-analysis, J Cachexia Sarcopenia Muscle 2026",
        "UK Biobank HRV Mendelian randomisation, Commun Biol 2023",
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    NoopCard {
                        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                            paragraph("Each driver is compared with a health target, not with the average person. Meeting every target reads as your own age; the average adult reads several years older.")
                            paragraph("Each driver's distance from its target is matched to a published all-cause-mortality hazard ratio and converted to years at 10 × ln(hazard ratio).")
                            paragraph("Drivers that measure the same thing are not counted twice: steps, cardio minutes and strength minutes are weighed against each other, and a strap-estimated VO₂max is folded into resting heart rate.")
                            paragraph("Body Age uses your last six months. Pace of Aging holds your last 30 days for six months: 1× is holding steady.")
                            paragraph("The hazard ratios come from observational studies, and nothing here has been validated against lifespan. Treat it as a wellness trend, not a clinical biological age.")
                        }
                    }
                    NoopCard {
                        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                            Text("References").strandOverline()
                            ForEach(Self.references, id: \.self) { ref in
                                Text(verbatim: ref)
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(NoopMetrics.screenPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("How this is worked out")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onClose).foregroundStyle(StrandPalette.accent)
                }
                #else
                ToolbarItem { Button("Done", action: onClose).foregroundStyle(StrandPalette.accent) }
                #endif
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }

    private func paragraph(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
