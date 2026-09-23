import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

// ResilienceSection.swift — the Experimental "how quickly do I settle back?" section of the Healthspan
// screen, its detail screen and its method sheet.
//
// Every readout comes from the ONE `ResilienceSnapshot` (`ResilienceLoader`), loaded once per refresh and
// handed down; the detail screen's trend ends at that snapshot's own result. Honesty rules from the plan
// shape the copy: τ is never shown without its 90 % range, the cohort ages are context rather than a
// norm, steps is labelled as the published signal and the other two as NOOP extensions, and nothing here
// is called an age.
struct ResilienceSection: View {
    @EnvironmentObject var repo: Repository

    @State private var snapshot: ResilienceSnapshot?
    @State private var selected: ResilienceEngine.Signal = .steps
    @State private var showDetail = false
    @State private var showMethod = false

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                SectionHeader("Resilience", overline: "Recovery time")
                SourceBadge("Experimental", tint: StrandPalette.restColor)
            }
            if let snapshot, let readout = snapshot.readout(selected) {
                Button { showDetail = true } label: { ResilienceHeroCard(readout: readout, showsChevron: true) }
                    .buttonStyle(.plain)
                chips(snapshot)
            } else {
                ComingSoon(what: "Reading your recovery time…", symbol: "arrow.uturn.backward")
            }
            Button { showMethod = true } label: {
                HStack(spacing: NoopMetrics.space2) {
                    Image(systemName: "function")
                    Text("How recovery time is worked out")
                }
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.accent)
            }
            .buttonStyle(.plain)
        }
        .task(id: repo.refreshSeq) { snapshot = await ResilienceLoader.load(repo: repo) }
        .sheet(isPresented: $showDetail) {
            if let readout = snapshot?.readout(selected) {
                ResilienceDetail(readout: readout) { showDetail = false }
            }
        }
        .sheet(isPresented: $showMethod) { ResilienceMethodSheet { showMethod = false } }
    }

    private func chips(_ snapshot: ResilienceSnapshot) -> some View {
        HStack(spacing: NoopMetrics.space2) {
            ForEach(ResilienceEngine.Signal.allCases, id: \.self) { signal in
                if let readout = snapshot.readout(signal) {
                    Button { selected = signal } label: { chip(readout, isSelected: signal == selected) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func chip(_ readout: ResilienceReadout, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            Text(ResilienceFormat.name(readout.signal))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(ResilienceFormat.provenance(readout.signal))
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(ResilienceFormat.chipValue(readout))
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(NoopMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.surfaceRaised,
                    in: RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
            .strokeBorder(isSelected ? StrandPalette.accent : StrandPalette.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Hero

/// The headline for one signal: collecting, no measurable carry-over, or τ with its range on a band.
private struct ResilienceHeroCard: View {
    let readout: ResilienceReadout
    var showsChevron = false

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack {
                    Text(ResilienceFormat.name(readout.signal)).strandOverline()
                    Spacer(minLength: 0)
                    if showsChevron {
                        Image(systemName: "chevron.right")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                if let e = readout.result?.estimate {
                    if e.hasMemory { estimate(e) } else { noMemory }
                } else {
                    collecting
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func estimate(_ e: ResilienceEngine.Estimate) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text("Recovery time").strandOverline()
            Text(ResilienceFormat.headline(e))
                .font(StrandFont.number(40))
                .foregroundStyle(StrandPalette.textPrimary)
            Text(ResilienceFormat.range(e))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
            ResilienceBand(estimate: e)
            Text("The ticks are population averages at ages 40 and 90, for context: not a score.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var noMemory: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text("No measurable carry-over")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Your day-to-day swings here do not carry from one day to the next strongly enough to time a recovery. This can change as more days come in.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var collecting: some View {
        let observed = min(readout.observedDays, ResilienceEngine.minObservedDays)
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text("\(observed) of \(ResilienceEngine.minObservedDays) days observed")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            ProgressView(value: Double(observed), total: Double(ResilienceEngine.minObservedDays))
                .tint(StrandPalette.accent)
            Text("Recovery time needs 90 days with a reading in the last 180.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// τ and its 90 % range on a log-scaled day axis, with the cohort ticks drawn faintly behind.
private struct ResilienceBand: View {
    let estimate: ResilienceEngine.Estimate

    var body: some View {
        Chart {
            ForEach(ResilienceFormat.cohortTicks, id: \.age) { tick in
                RuleMark(x: .value("Days", tick.days))
                    .foregroundStyle(StrandPalette.hairlineStrong)
                    .lineStyle(StrokeStyle(lineWidth: NoopMetrics.hairlineWidth, dash: [3, 3]))
                    .annotation(position: .top, spacing: NoopMetrics.space1) {
                        Text(verbatim: "\(tick.age)")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
            }
            RuleMark(xStart: .value("Days", estimate.tauLow), xEnd: .value("Days", estimate.tauHigh),
                     y: .value("Range", 0))
                .foregroundStyle(StrandPalette.accent.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 10, lineCap: .round))
            PointMark(x: .value("Days", estimate.tau), y: .value("Range", 0))
                .foregroundStyle(StrandPalette.accent)
                .symbolSize(90)
        }
        .chartXScale(domain: ResilienceEngine.tauFloor...ResilienceEngine.tauCeiling, type: .log)
        .chartXAxis {
            AxisMarks(values: [1, 3, 7, 14, 30, 60, 180]) { value in
                AxisGridLine().foregroundStyle(StrandPalette.hairline)
                AxisValueLabel {
                    if let d = value.as(Double.self) {
                        Text(verbatim: "\(Int(d))")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
        .chartYAxis(.hidden)
        .chartYScale(domain: -1...1)
        .frame(height: 64)
        .accessibilityLabel(Text(ResilienceFormat.range(estimate)))
    }
}

// MARK: - Detail

private struct ResilienceDetail: View {
    let readout: ResilienceReadout
    let onClose: () -> Void

    @State private var trend: [ResilienceTrendPoint]?
    @State private var showMethod = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    ResilienceHeroCard(readout: readout)
                    if let e = readout.result?.estimate {
                        settles(e)
                    }
                    knocks
                    if readout.result?.estimate != nil {
                        trendSection
                        swingSection
                    }
                    observedLine
                    Button { showMethod = true } label: {
                        HStack(spacing: NoopMetrics.space2) {
                            Image(systemName: "function")
                            Text("How recovery time is worked out")
                        }
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.accent)
                    }
                    .buttonStyle(.plain)
                }
                .padding(NoopMetrics.screenPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("Resilience")
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
        // Keyed on the readout: a refresh while the sheet is open hands down a new one, and the trend
        // must end at that readout's headline, not the one the sheet opened with.
        .task(id: readout) {
            trend = nil
            trend = await ResilienceLoader.trend(readout)
        }
        .sheet(isPresented: $showMethod) { ResilienceMethodSheet { showMethod = false } }
        #if os(macOS)
        .frame(minWidth: NoopMetrics.detailSheetMinWidth, minHeight: NoopMetrics.detailSheetMinHeight)
        #endif
    }

    // 1. The measured autocorrelation and the curve fitted to it.
    private func settles(_ e: ResilienceEngine.Estimate) -> some View {
        let points = e.acf.enumerated().compactMap { k, c in c.map { (lag: k + 1, c: $0) } }
        let curve = stride(from: 1.0, through: Double(ResilienceEngine.maxLag), by: 0.5).map {
            (lag: $0, c: e.fitted(atLag: $0))
        }
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("How your body settles", overline: "Evidence")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    Chart {
                        RuleMark(y: .value("Carry-over", 0))
                            .foregroundStyle(StrandPalette.hairlineStrong)
                        ForEach(points, id: \.lag) { p in
                            PointMark(x: .value("Days later", p.lag), y: .value("Carry-over", p.c))
                                .foregroundStyle(StrandPalette.textSecondary)
                                .symbolSize(24)
                        }
                        if e.hasMemory {
                            ForEach(curve, id: \.lag) { p in
                                LineMark(x: .value("Days later", p.lag), y: .value("Carry-over", p.c))
                                    .foregroundStyle(StrandPalette.accent)
                            }
                        }
                    }
                    .chartXAxisLabel { Text("Days later") }
                    .frame(height: 180)
                    Text(e.hasMemory
                         ? ResilienceFormat.fitCaption(e)
                         : String(localized: "Each dot is how much of a day's deviation is still there that many days later. None of it carries over measurably yet."))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // 2. The most recent knocks, newest first.
    private var knocks: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Your last knocks", overline: "6 months")
            let recent = Array(readout.knocks.suffix(3).reversed())
            if recent.isEmpty {
                NoopCard {
                    Text("No knocks in this window: nothing moved this signal more than 2 SD from its usual level for two days running.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ForEach(recent, id: \.startDay) { knock in knockCard(knock) }
            }
        }
    }

    private func knockCard(_ k: ResilienceEngine.Knock) -> some View {
        let curve: [(t: Double, z: Double)] = stride(from: 0.0, through: Double(ResilienceEngine.knockHorizonDays),
                                                    by: 0.5).compactMap { t in k.fittedReturn(atDay: t).map { (t: t, z: $0) } }
        return NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(ResilienceFormat.knockTitle(k, signal: readout.signal))
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: NoopMetrics.space2)
                    Text(ResilienceLoader.date(k.peakDay), format: .dateTime.month(.abbreviated).day())
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Chart {
                    RuleMark(y: .value("SD", ResilienceEngine.baselineBand))
                        .foregroundStyle(StrandPalette.hairlineStrong)
                        .lineStyle(StrokeStyle(lineWidth: NoopMetrics.hairlineWidth, dash: [4, 4]))
                    RuleMark(y: .value("SD", 0))
                        .foregroundStyle(StrandPalette.hairline)
                    ForEach(curve, id: \.t) { p in
                        LineMark(x: .value("Days since the peak", p.t), y: .value("SD", p.z))
                            .foregroundStyle(StrandPalette.accent)
                    }
                    ForEach(k.path, id: \.dayIndex) { p in
                        PointMark(x: .value("Days since the peak", p.dayIndex), y: .value("SD", p.value))
                            .foregroundStyle(StrandPalette.textSecondary)
                            .symbolSize(22)
                    }
                }
                .chartXScale(domain: 0...ResilienceEngine.knockHorizonDays)
                .chartXAxisLabel { Text("Days since the peak") }
                .frame(height: 120)
                Text(ResilienceFormat.knockReturn(k))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // 3. τ over the last year, with its range.
    private var trendSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Trend", overline: "12 months")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    if let trend {
                        let shown = trend.filter(\.estimate.hasMemory)
                        if shown.count >= 2 {
                            Chart {
                                ForEach(shown) { p in
                                    AreaMark(x: .value("Date", p.date),
                                             yStart: .value("Days", p.estimate.tauLow),
                                             yEnd: .value("Days", p.estimate.tauHigh))
                                        .foregroundStyle(StrandPalette.accent.opacity(0.18))
                                    LineMark(x: .value("Date", p.date), y: .value("Days", p.estimate.tau))
                                        .foregroundStyle(StrandPalette.accent)
                                }
                            }
                            .chartYScale(domain: ResilienceEngine.tauFloor...ResilienceEngine.tauCeiling, type: .log)
                            .chartYAxis {
                                AxisMarks(values: [1, 3, 7, 14, 30, 60, 180]) { value in
                                    AxisGridLine().foregroundStyle(StrandPalette.hairline)
                                    AxisValueLabel {
                                        if let d = value.as(Double.self) {
                                            Text(verbatim: "\(Int(d))").font(StrandFont.caption)
                                        }
                                    }
                                }
                            }
                            .frame(height: 180)
                            Text("Recovery time in days, each point read from the 180 days before it. The band is its 90 % range.")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Not enough history for a trend yet.")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    // 4. The size of the day-to-day swings: the second hallmark.
    private var swingSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Day-to-day swing", overline: "12 months")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    if let e = readout.result?.estimate {
                        Text(ResilienceFormat.sigma(e.sigma, signal: readout.signal))
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    if let trend, trend.count >= 2 {
                        Chart {
                            ForEach(trend) { p in
                                LineMark(x: .value("Date", p.date),
                                         y: .value("Swing", ResilienceFormat.sigmaValue(p.estimate.sigma,
                                                                                         signal: readout.signal)))
                                    .foregroundStyle(StrandPalette.restColor)
                            }
                        }
                        .frame(height: 120)
                    }
                    Text("How far a typical day strays from your usual level, once your weekly rhythm and any slow drift are removed. In large cohorts it grows with age alongside recovery time.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // 5. What the readout rests on.
    private var observedLine: some View {
        Text("\(readout.observedDays) of \(ResilienceEngine.windowDays) days observed for this signal.")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
    }
}

// MARK: - Method

private struct ResilienceMethodSheet: View {
    let onClose: () -> Void

    private static let references = [
        "Pyrkov TV et al., Longitudinal analysis of blood markers reveals progressive loss of resilience and predicts human lifespan limit, Nat Commun 2021;12:2765 (doi 10.1038/s41467-021-23014-1)",
        "Pyrkov TV et al., Quantitative characterization of biological age and frailty based on locomotor activity records, Aging 2018 (PMC6224248)",
        "Pyrkov TV et al., GeroSense, Aging 2021 (doi 10.18632/aging.202816)",
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    NoopCard {
                        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                            paragraph("Resilience asks how quickly your body settles back after something knocks it off its usual state: a hard week, a short night, travel or an illness.")
                            paragraph("Each day is compared with your usual level after your weekly rhythm and any slow drift are removed. How long a deviation lingers is measured by correlating each day with the days after it, and fitted with an exponential decay. Its time constant is the recovery time.")
                            paragraph("The model is the one Pyrkov and colleagues used on blood counts and on daily step counts from wristband wearers. In large cohorts the recovery time lengthens with age, from about two weeks at 40 to more than eight weeks at 90.")
                            paragraph("Those are population averages. A recovery time from one person's six months has not been validated and is noisy, so it is always shown with its 90 % range. It is not an age, and it feeds no other score.")
                            paragraph("A short history makes the raw fit read short. The headline corrects for that by simulating histories with known recovery times over your own days; the range holds every recovery time consistent with what was measured.")
                            paragraph("Steps is the signal the study used. Resting heart rate and HRV apply the same method and are NOOP extensions.")
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
            .navigationTitle("How recovery time is worked out")
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

// MARK: - Formatting (internal for tests)

enum ResilienceFormat {

    /// Pyrkov 2021's cohort recovery times: about two weeks at 40, beyond eight weeks at 90.
    static let cohortTicks: [(age: Int, days: Double)] = [(40, 14), (90, 56)]

    static func name(_ signal: ResilienceEngine.Signal) -> String {
        switch signal {
        case .steps:     return String(localized: "Steps")
        case .restingHR: return String(localized: "Resting HR")
        case .hrv:       return String(localized: "HRV")
        }
    }

    static func provenance(_ signal: ResilienceEngine.Signal) -> String {
        signal.isPublished ? String(localized: "Published") : String(localized: "Extension")
    }

    /// Whole days, never below one.
    static func days(_ value: Double) -> Int { max(1, Int(value.rounded())) }

    static func headline(_ e: ResilienceEngine.Estimate) -> String {
        let n = days(e.tau)
        return n == 1 ? String(localized: "≈ 1 day") : String(localized: "≈ \(n) days")
    }

    /// The 90 % range; an upper bound at the ceiling means nothing longer can be ruled out.
    static func range(_ e: ResilienceEngine.Estimate) -> String {
        let low = days(e.tauLow)
        if e.tauHigh >= ResilienceEngine.tauCeiling - 0.5 {
            return String(localized: "90 % range: \(low) days or longer")
        }
        return String(localized: "90 % range: \(low)–\(days(e.tauHigh)) days")
    }

    static func chipValue(_ readout: ResilienceReadout) -> String {
        guard let e = readout.result?.estimate else {
            return String(localized: "\(min(readout.observedDays, ResilienceEngine.minObservedDays))/\(ResilienceEngine.minObservedDays) days")
        }
        guard e.hasMemory else { return String(localized: "No carry-over") }
        return String(localized: "≈ \(days(e.tau)) d (\(days(e.tauLow))–\(days(e.tauHigh)))")
    }

    static func fitCaption(_ e: ResilienceEngine.Estimate) -> String {
        String(localized: "Each dot is how much of a day's deviation is still there that many days later. The line is the best fit to these dots (\(days(e.tauFit)) days); the headline corrects that fit for how short one person's history is.")
    }

    /// σ in the signal's own terms: a typical percentage swing for the log signals, bpm for resting HR.
    static func sigmaValue(_ sigma: Double, signal: ResilienceEngine.Signal) -> Double {
        signal == .restingHR ? sigma : (exp(sigma) - 1) * 100
    }

    static func sigma(_ sigma: Double, signal: ResilienceEngine.Signal) -> String {
        let v = sigmaValue(sigma, signal: signal)
        return signal == .restingHR
            ? String(localized: "Typical swing ± \(String(format: "%.1f", v)) bpm")
            : String(localized: "Typical swing ± \(Int(v.rounded())) %")
    }

    static func knockTitle(_ k: ResilienceEngine.Knock, signal: ResilienceEngine.Signal) -> String {
        let up = k.peakDeviation > 0
        switch signal {
        case .steps:     return up ? String(localized: "More active than usual") : String(localized: "Less active than usual")
        case .restingHR: return up ? String(localized: "Resting HR above usual") : String(localized: "Resting HR below usual")
        case .hrv:       return up ? String(localized: "HRV above usual") : String(localized: "HRV below usual")
        }
    }

    static func knockReturn(_ k: ResilienceEngine.Knock) -> String {
        let peak = String(format: "%.1f", abs(k.peakDeviation))
        guard let back = k.daysToBaseline else {
            return String(localized: "Peaked at \(peak) SD. Not back in your usual range yet.")
        }
        let half = k.halfLifeDays.map { String(format: "%.1f", $0) }
        switch (back == 1, half) {
        case (true, nil):       return String(localized: "Peaked at \(peak) SD, back in your usual range after 1 day.")
        case (false, nil):      return String(localized: "Peaked at \(peak) SD, back in your usual range after \(back) days.")
        case (true, let h?):    return String(localized: "Peaked at \(peak) SD, back in your usual range after 1 day. Half-life ≈ \(h) days.")
        case (false, let h?):   return String(localized: "Peaked at \(peak) SD, back in your usual range after \(back) days. Half-life ≈ \(h) days.")
        }
    }
}
