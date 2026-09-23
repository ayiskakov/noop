import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopProtocol

/// The gated review screen for WHOOP 5/MG R16 ECG recordings (#891).
///
/// ## What this screen is, and the line it does not cross
///
/// It shows the SHAPE of what the strap recorded and nothing derived from it. No heart rate, no
/// interval, no rhythm classification, no voltage, no "normal" or "abnormal". That is not caution for
/// its own sake — `ECG_FEATURE_NOTES.md` §5 records that beat-to-beat accuracy against the strap's own
/// optical heart rate was never established (r ≈ 0.43 at best, and WORSE with a better detector), for a
/// structural reason rather than a fixable one: wrist single-lead ECG needs stillness, stillness means
/// the heart rate barely moves, and anything that moves it properly destroys the trace with motion
/// artifact. A number on this screen would be the withdrawn #194 PPG→HR estimate all over again.
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
                Text("This is an unvalidated sensor waveform decoded from your own strap. NOOP is not a medical device and this is not an ECG test. It cannot detect, diagnose, rule out, or monitor any heart condition. No heart rate or rhythm is shown, because nothing here has been validated to produce one. If you have symptoms or a concern about your heart, talk to a doctor.")
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

                scrubber(recording)
                controls
                if !recording.isComplete { incompleteNotice(recording) }
                factsRow(recording)
            }
        }
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

    /// The recording's facts, each stated as what it is. Note what is absent: no heart rate, and no
    /// word-label for the quality code — see the type doc.
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
    }

    private func window(_ recording: EcgStrip.Recording) -> Window {
        let from = recording.startTs + windowStart
        let to = from + windowSeconds - 1
        let visible = records.filter { $0.ts >= from && $0.ts <= to }
        let seconds = max(1, min(windowSeconds, recording.endTs - from + 1))
        guard !visible.isEmpty else {
            return Window(columns: [], breaks: [], range: (-1, 1), seconds: seconds, contactFlags: [])
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
                      contactFlags: visible.flatMap(\.contactFlags))
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
        records = await model.repo.ecgRecords(for: recording)
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
