import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopProtocol

/// The gated review screen for WHOOP 5/MG R16 ECG recordings (#891).
///
/// ## What this screen is, and the line it does not cross
///
/// It shows the SHAPE of what the strap recorded, plus one derived figure: a heart rate counted from R
/// peaks (`EcgBeats`), with the peaks marked on the strip so the count can be checked by eye. No
/// interval analysis beyond R-R, no rhythm classification, no voltage, no "normal" or "abnormal". The
/// rate is shown only from records the strap itself rated quality 3, where it tracked the strap's
/// optical HR across 82–116 bpm (see `EcgBeats` for the comparison). It is experimental and feeds
/// nothing else.
///
/// The same rule governs what IS shown. The strap's own status codes appear as the raw codes they are,
/// because `docs/PROTOCOL_ECG.md` says the quality values are "partial observed outcomes, not an
/// exhaustive enum or a bad/good/excellent scale" — so rendering a 3 as "Excellent" would be this screen
/// inventing a vocabulary the wire does not have. Contact is reported as the strap's lead-state flag,
/// which is a presence indication and not an assessment of the signal.
///
/// ## Gating
///
/// Reached only from Test Centre, and only while the `noopWhoop5Ecg` Experimental toggle is on — the
/// same opt-in that unlocks the capture probe. Read-only throughout: this screen never writes to the
/// strap and sends no command.
struct EcgReviewView: View {
    @EnvironmentObject private var model: AppModel

    @State private var recordings: [EcgStrip.Recording] = []
    @State private var selected: EcgStrip.Recording?
    @State private var records: [EcgCandidateSample] = []
    /// Beats for the selected recording, nil while they are being found.
    @State private var beats: EcgBeats.Result?
    /// Measured rhythm facts for the selected recording; nil while loading or with too few beats.
    @State private var rhythm: EcgRhythmFacts?
    @State private var loading = true
    @State private var loadingWaveform = false
    /// Display-only baseline removal. ON by default because the captures need it — a ten-second window
    /// of real data spans tens of thousands of counts of wander against complexes a few thousand counts
    /// tall, so unfiltered the strip is a drifting ramp with the signal riding invisibly on it. Offered
    /// as a switch because the stored samples are the strap's own and the user is entitled to see them.
    @State private var filterEnabled = true
    /// Index of the first second shown in the strip.
    @State private var windowStart = 0
    /// Seconds shown at once.
    @State private var windowSeconds = 10

    /// Window lengths offered. Ten seconds is the default because it is enough to show several beats at
    /// a width where individual complexes stay distinct.
    private static let windowChoices = [5, 10, 30]

    /// Samples per second WITHIN a record, used only to place samples along the x-axis.
    ///
    /// This is an INFERENCE and the screen says so on its face. What is attested is that the strap emits
    /// one record per second and a full record declares 500 samples; `docs/PROTOCOL_ECG.md` is explicit
    /// that "buffer capacity is not a sample frequency". So the axis is built from the RECORD
    /// timestamps, which are wire facts, with each record's samples spread evenly across the second it
    /// covers. A record carrying fewer samples than 500 therefore spreads them across its whole second
    /// rather than leaving the rest of it blank — which is the honest rendering when the true acquisition
    /// times within a record are not known.
    private static let nominalSamplesPerSecond = 500.0

    var body: some View {
        ScreenScaffold(
            title: "ECG recordings",
            subtitle: "Review the raw waveform your WHOOP MG recorded. Unvalidated — not a medical ECG."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                disclaimerCard
                if loading {
                    StrandCard { ProgressView().frame(maxWidth: .infinity) }
                } else if recordings.isEmpty {
                    emptyCard
                } else {
                    if let selected { stripCard(selected) }
                    if let rhythm, let beats, !loadingWaveform { rhythmCard(rhythm, beats: beats) }
                    recordingListCard
                }
            }
        }
        .task { await load() }
    }

    // MARK: - The disclaimer is the first thing on the screen, not the last

    private var disclaimerCard: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Label {
                    Text("Not a medical device")
                        .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(StrandPalette.statusWarning)
                }
                Text("This is an unvalidated sensor waveform decoded from your own strap. NOOP is not a medical device and this is not an ECG test. It cannot detect, diagnose, rule out, or monitor any heart condition. The heart rate shown is an experimental count of beats, not a rhythm analysis. If you have symptoms or a concern about your heart, talk to a doctor.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var emptyCard: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("No recordings yet")
                    .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                Text("Run the ECG probe from the Devices screen, holding your thumb and finger on both clasp indents with your other hand for the whole window. The strap records to its own flash, so the recording appears here after the next history sync — not straight away.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - The strip

    @ViewBuilder private func stripCard(_ recording: EcgStrip.Recording) -> some View {
        StrandCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text(Self.rangeLabel(recording))
                    .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)

                if loadingWaveform {
                    ProgressView().frame(maxWidth: .infinity, minHeight: NoopMetrics.chartHeight)
                } else {
                    let window = self.window(recording)
                    EcgStripChart(columns: window.columns.map {
                                      EcgStripColumn(min: $0.min, max: $0.max)
                                  },
                                  breakAfter: window.breaks,
                                  range: window.range,
                                  seconds: Double(window.seconds),
                                  contactFlags: window.contactFlags,
                                  markers: window.markers,
                                  height: NoopMetrics.chartHeight)
                    // The axis carries SECONDS, which are a wire fact (one record per second), and no
                    // amplitude axis at all, because there is no calibration to put on one.
                    HStack {
                        Text(Self.clock(recording.startTs + windowStart))
                        Spacer()
                        Text("Amplitude uncalibrated")
                        Spacer()
                        Text(Self.clock(recording.startTs + windowStart + window.seconds))
                    }
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }

                heartRateBlock
                scrubber(recording)
                controls
                if !recording.isComplete { incompleteNotice(recording) }
                factsRow(recording)
            }
        }
    }

    /// The one derived figure, and the evidence for it: beats are marked on the strip above.
    @ViewBuilder private var heartRateBlock: some View {
        if let beats, !loadingWaveform {
            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                if let rate = beats.heartRate, let rr = beats.medianRRMs {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Heart rate from ECG")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        Spacer()
                        Text("\(Int(rate.rounded())) bpm")
                            .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    }
                    Text("R-R median \(Int(rr.rounded())) ms · \(beats.beats.count) beats in \(beats.analysedSeconds) s of clean signal")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                } else {
                    Text("Not enough clean signal for a heart rate. The strap marked \(beats.analysedSeconds) s of this recording as clean.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Experimental. Counted from the R peaks (marked on the strip) only where the strap rated the signal clean. Not a medical measurement.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Rhythm details

    /// Measurements only. The section deliberately names no rhythm and no condition — see
    /// `EcgRhythmFacts` for why a "not detected" line is the one this screen must never print.
    private func rhythmCard(_ facts: EcgRhythmFacts, beats: EcgBeats.Result) -> some View {
        StrandCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("Rhythm details (experimental)")
                    .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                factRow("Heart rate", value: Text("\(Int(facts.heartRate.rounded())) bpm"),
                        detail: Text("range \(Int(facts.rateLow.rounded()))–\(Int(facts.rateHigh.rounded())) bpm"))
                factRow("Above \(Int(EcgRhythmFacts.highRate)) bpm", value: share(facts.fractionAboveHigh))
                factRow("Below \(Int(EcgRhythmFacts.lowRate)) bpm", value: share(facts.fractionBelowLow))
                factRow("Beat-to-beat variation", value: facts.rmssdMs.map {
                    Text("\(Int(facts.variationPercent.rounded()))% · RMSSD \(Int($0.rounded())) ms")
                } ?? Text("\(Int(facts.variationPercent.rounded()))%"))
                if facts.setAsideIntervals > 0 {
                    Text("\(facts.setAsideIntervals) intervals set aside as likely missed or extra beats.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    Text("R-R intervals")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    RRDotChart(intervals: beats.intervals.map(\.ms))
                        .frame(height: 120)
                    Text("One dot per beat: the gap since the previous beat, in order.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                factRow("Strap's own result", value: facts.strapResultCode.map {
                    Text("code \($0) (meaning not known)")
                } ?? Text("Did not finish"))
                Text("These are measurements, not a diagnosis. NOOP cannot detect or rule out AFib or any other heart condition. If you feel unwell or notice palpitations, see a doctor.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func factRow(_ label: LocalizedStringKey, value: Text, detail: Text? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            VStack(alignment: .trailing, spacing: NoopMetrics.spaceHalf) {
                value.font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
                if let detail { detail.font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary) }
            }
        }
    }

    /// A share of the recording, worded so none of it reads as a verdict.
    private func share(_ fraction: Double) -> Text {
        if fraction <= 0 { return Text("No") }
        if fraction >= 0.95 { return Text("Whole recording") }
        return Text("\(max(1, Int((fraction * 100).rounded())))% of the recording")
    }

    @ViewBuilder private func scrubber(_ recording: EcgStrip.Recording) -> some View {
        let maxStart = max(0, recording.durationSeconds - windowSeconds)
        if maxStart > 0 {
            Slider(value: Binding(
                get: { Double(min(windowStart, maxStart)) },
                set: { windowStart = Int($0.rounded()) }
            ), in: 0...Double(maxStart), step: 1)
            .accessibilityLabel(Text("Position in recording"))
            .accessibilityValue(Text("\(windowStart) of \(maxStart) seconds"))
        }
    }

    private var controls: some View {
        HStack(spacing: NoopMetrics.space3) {
            Picker("Window", selection: $windowSeconds) {
                // Localized, and spaced, for the same reason the stat lines below are: a unit glued to
                // a number reads wrong in the CJK locales, and "%lld s" is one catalog key for all three
                // choices rather than three hand-written ones.
                ForEach(Self.windowChoices, id: \.self) { Text("\($0) s").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 180)

            Toggle("Remove baseline drift", isOn: $filterEnabled)
                .font(StrandFont.caption)
                .toggleStyle(.switch)
        }
    }

    @ViewBuilder private func incompleteNotice(_ recording: EcgStrip.Recording) -> some View {
        // Shown when the rows hold fewer samples than the records declared. The user is looking at a
        // waveform with pieces missing, and a strip that did not say so would read as a complete one.
        Text("This recording is incomplete: \(recording.storedSamples) of \(recording.declaredSamples) samples were stored. The trace is drawn from what survived.")
            .font(StrandFont.caption).foregroundStyle(StrandPalette.statusWarning)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The recording's facts, each stated as what it is. Note what is absent: no word-label for the
    /// quality code — see the type doc.
    @ViewBuilder private func factsRow(_ recording: EcgStrip.Recording) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            Text("\(recording.durationSeconds) s · \(recording.recordCount) records · \(recording.storedSamples) samples")
            if recording.contactTotal > 0 {
                Text("Electrode contact: the strap reported its circuit closed for \(recording.contactClosed) of \(recording.contactTotal) intervals.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let progress = recording.peakProgress {
                Text(progress >= 100
                     ? "The strap's session counter reached completion."
                     : "The strap's session counter reached \(progress) before the recording ended.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
    }

    // MARK: - Recording list

    private var recordingListCard: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("RECORDINGS")
                    .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                ForEach(recordings) { recording in
                    Button {
                        Task { await select(recording) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                                Text(Self.rangeLabel(recording))
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Text("\(recording.durationSeconds) s · \(recording.storedSamples) samples")
                                    .font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                            Spacer()
                            if selected?.id == recording.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(StrandPalette.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if recording.id != recordings.last?.id {
                        Divider().overlay(StrandPalette.hairline)
                    }
                }
            }
        }
    }

    // MARK: - Windowing

    /// Everything the strip needs for the current window, resolved ONCE.
    ///
    /// One funnel rather than several computed properties reading the same state: the seconds label, the
    /// contact band and the trace all describe the same window, and resolving them separately is how two
    /// readouts of one fact come to disagree.
    private struct Window {
        let columns: [EcgStrip.Column]
        let breaks: Set<Int>
        let range: (min: Double, max: Double)
        let seconds: Int
        let contactFlags: [Bool]
        let markers: [Double]
    }

    private func window(_ recording: EcgStrip.Recording) -> Window {
        let from = recording.startTs + windowStart
        let to = from + windowSeconds - 1
        let visible = records.filter { $0.ts >= from && $0.ts <= to }
        let seconds = max(1, min(windowSeconds, recording.endTs - from + 1))
        guard !visible.isEmpty else {
            return Window(columns: [], breaks: [], range: (-1, 1), seconds: seconds, contactFlags: [], markers: [])
        }
        let (samples, gaps) = EcgStrip.concatenate(visible.map {
            (ts: $0.ts, samples: $0.samples.map(Double.init))
        })
        // Filtered PER SEGMENT so a gap never enters the filter: the step across one produces a large
        // transient that decays like a complex, at exactly the place the strap recorded nothing.
        let series = filterEnabled
            ? EcgStrip.filterSegments(samples, gapAfter: gaps,
                                      sampleRate: Self.nominalSamplesPerSecond)
            : samples
        // Column count is resolution, not layout: the view stretches whatever it is given to its own
        // width, and asking for more columns than the widest plausible strip only costs work.
        let columns = EcgStrip.envelope(series, columns: 900)
        // Gap positions are sample indices; map them onto column indices so the view breaks the trace in
        // the right place at any column count.
        let breaks = EcgStrip.breakColumns(gapAfter: gaps, sampleCount: series.count, columns: columns.count)
        return Window(columns: columns,
                      breaks: breaks,
                      range: EcgStrip.verticalRange(columns),
                      seconds: seconds,
                      contactFlags: visible.flatMap(\.contactFlags),
                      markers: EcgStrip.markerFractions(
                          beats: (beats?.beats ?? []).map { (ts: $0.recordTs, sample: $0.sample) },
                          records: visible.map { (ts: $0.ts, sampleCount: $0.samples.count) }))
    }

    // MARK: - Loading

    private func load() async {
        loading = true
        recordings = await model.repo.ecgRecordings()
        loading = false
        if let first = recordings.first { await select(first) }
    }

    private func select(_ recording: EcgStrip.Recording) async {
        selected = recording
        windowStart = 0
        loadingWaveform = true
        beats = nil
        rhythm = nil
        let loaded = await model.repo.ecgRecords(for: recording)
        records = loaded
        // Off the main actor: a long recording is hundreds of thousands of samples.
        let (found, facts) = await Task.detached(priority: .userInitiated) { () -> (EcgBeats.Result, EcgRhythmFacts?) in
            let found = EcgBeats.analyse(loaded)
            return (found, EcgRhythmFacts.from(found, records: loaded))
        }.value
        guard selected?.id == recording.id else { return }
        beats = found
        rhythm = facts
        loadingWaveform = false
    }

    // MARK: - Formatting

    static func rangeLabel(_ recording: EcgStrip.Recording) -> String {
        let start = Date(timeIntervalSince1970: TimeInterval(recording.startTs))
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f.string(from: start)
    }

    static func clock(_ ts: Int) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
}

/// R-R intervals as dots in beat order. A steady rhythm draws a flat band; the chart shows the spread
/// and leaves what it means to the reader.
private struct RRDotChart: View {
    let intervals: [Double]

    var body: some View {
        Canvas { ctx, size in
            guard intervals.count > 1, let lo = intervals.min(), let hi = intervals.max() else { return }
            let pad = max(20, (hi - lo) * 0.15)
            let bottom = lo - pad, span = hi - lo + 2 * pad
            let step = size.width / Double(intervals.count - 1)
            var grid = Path()
            for fraction in [0.25, 0.5, 0.75] {
                grid.move(to: CGPoint(x: 0, y: size.height * fraction))
                grid.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
            }
            ctx.stroke(grid, with: .color(StrandPalette.hairline), lineWidth: 0.5)
            let r = NoopMetrics.space1 / 1.5
            for (i, ms) in intervals.enumerated() {
                let x = Double(i) * step
                let y = size.height * (1 - (ms - bottom) / span)
                ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                         with: .color(StrandPalette.accent))
            }
            ctx.draw(Text("\(Int(hi.rounded())) ms").font(StrandFont.caption)
                        .foregroundColor(StrandPalette.textTertiary),
                     at: CGPoint(x: 0, y: 0), anchor: .topLeading)
            ctx.draw(Text("\(Int(lo.rounded())) ms").font(StrandFont.caption)
                        .foregroundColor(StrandPalette.textTertiary),
                     at: CGPoint(x: 0, y: size.height), anchor: .bottomLeading)
        }
        .background(StrandPalette.surfaceInset)
        .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.space1, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("R-R intervals"))
        .accessibilityValue(Text("\(intervals.count) intervals from \(Int((intervals.min() ?? 0).rounded())) to \(Int((intervals.max() ?? 0).rounded())) ms"))
    }
}
