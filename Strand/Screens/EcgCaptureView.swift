import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopProtocol

/// The guided WHOOP MG ECG capture (#891): choose the wrist, get into position, watch the live trace,
/// finish. macOS and iOS.
///
/// ## What the screen draws, and the line it does not cross
///
/// The live trace is the strap's own filtered R17 stream (`LiveState.ecgLive`), paced for display by
/// `EcgLiveFeed`. Like `EcgReviewView`, it shows a shape and derives nothing from it: no heart rate, no
/// rhythm, no classification. The status line reads the strap's presence bit and its progress value,
/// both named for what the wire says (`docs/PROTOCOL_ECG.md`), never as a quality grade.
///
/// ## Commands
///
/// Start sends SELECT_WRIST, then the documented turn-on sequence (`BLEManager.ecgStartCapture`). The
/// screen always stops what it started: on Finish, when the strap's progress reaches 100, at the hard
/// cap, and when the screen goes away mid-capture. The full-resolution R16 record is banked on the strap
/// and arrives with the next sync, where `EcgReviewView` shows it.
///
/// Reached only while the Experimental ECG opt-in is on, from Test Centre and the Devices ECG menu.
struct EcgCaptureView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    @Environment(\.dismiss) private var dismiss

    /// The wearer's wrist, remembered on this device only. The strap may or may not keep its own copy
    /// (persistence is not established), so the capture re-sends this before every start.
    @AppStorage("noop.ecgWrist") private var wristRaw = Int(Whoop5Ecg.WristSelection.left.rawValue)
    /// The Experimental ECG opt-in. The Devices menu can still offer this screen with the opt-in off
    /// while a capture may be running, so Start has to check it too.
    @AppStorage(PuffinExperiment.ecgKey) private var ecgEnabled = false

    @State private var step: Step = .wrist
    @State private var startedAt: Date?
    @State private var finishReason: FinishReason?

    private enum Step { case wrist, prepare, recording, done }
    private enum FinishReason { case strapFinished, userFinished, timeLimit }

    /// Samples in the sweeping window: four records' worth.
    private static let windowSamples = 400
    /// Samples the vertical scale is taken over, longer than the window so the trace does not resize at
    /// every beat.
    private static let scaleSamples = 1_000
    /// Hard cap on one capture. The strap has its own timeout; this one keeps a forgotten screen from
    /// leaving the front end running.
    private static let maxDuration: TimeInterval = 90
    /// How long to wait for the first live record before saying so.
    private static let firstRecordPatience: TimeInterval = 12

    private var wrist: Whoop5Ecg.WristSelection {
        Whoop5Ecg.WristSelection(rawValue: UInt8(clamping: wristRaw)) ?? .left
    }

    /// The same gate the Devices menu and `BLEManager.ecgGatesAllow` apply, read here so Start is
    /// disabled rather than silently ignored.
    private var ready: Bool {
        ecgEnabled && live.connected && live.encryptedBond && model.isWhoop5MG
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.space5) {
                header
                switch step {
                case .wrist: wristStep
                case .prepare: prepareStep
                case .recording: recordingStep
                case .done: doneStep
                }
            }
            .padding(NoopMetrics.space5)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(StrandPalette.surfaceBase)
        .navigationTitle(Text("ECG"))
        .onDisappear { if step == .recording { model.ecgStopCapture(reportsResult: false) } }
        .onChangeCompat(of: live.ecgLive?.status?.progress) { progress in
            // 255 is "no session" on the wire; only a real 100 means the strap's own run completed.
            if step == .recording, progress == 100 { finish(.strapFinished) }
        }
        .onChangeCompat(of: live.connected) { connected in
            if !connected, step == .recording { step = .prepare }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text("Record an ECG")
                .font(StrandFont.title1)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Experimental. NOOP is not a medical device: this shows the waveform your strap records, with no heart rate, rhythm or diagnosis.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.statusWarning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Step 1: wrist

    private var wristStep: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            Text("Which wrist is your strap on?")
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("The strap records the heart's signal between your wrist and the finger on the clasp, so it needs to know which way round that is.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: NoopMetrics.space3) {
                wristChoice(.left, title: "Left wrist")
                wristChoice(.right, title: "Right wrist")
            }
            NoopButton("Continue", systemImage: "arrow.right", fullWidth: true) { step = .prepare }
        }
    }

    private func wristChoice(_ choice: Whoop5Ecg.WristSelection, title: LocalizedStringKey) -> some View {
        let selected = wrist == choice
        return Button {
            wristRaw = Int(choice.rawValue)
        } label: {
            VStack(spacing: NoopMetrics.space2) {
                Image(systemName: "hand.raised.fill")
                    .font(StrandFont.title1)
                    .scaleEffect(x: choice == .left ? -1 : 1, y: 1)
                Text(title).font(StrandFont.headline)
            }
            .foregroundStyle(selected ? StrandPalette.accent : StrandPalette.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, NoopMetrics.space5)
            .background(
                RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
                    .fill(selected ? StrandPalette.accentMuted : StrandPalette.surfaceRaised))
            .overlay(
                RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
                    .stroke(selected ? StrandPalette.accent : StrandPalette.hairline, lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Step 2: get into position

    private var prepareStep: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            Text("Get into position")
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    instruction(1, wrist == .left
                                ? "Wear the strap snugly on your left wrist, sensor against the skin."
                                : "Wear the strap snugly on your right wrist, sensor against the skin.")
                    instruction(2, "Sit down and rest both arms on a table.")
                    instruction(3, "Press a fingertip of your other hand on the clasp's two indents and keep it there until the recording ends.")
                    instruction(4, "Stay still and don't talk. A slightly damp fingertip and unplugged chargers give a cleaner trace.")
                }
            }
            if !ecgEnabled {
                Text("Turn on WHOOP MG ECG capture (experimental) in Test Centre to start a recording.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !ready {
                Text("Connect your WHOOP MG and let it finish pairing to start a recording.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            NoopButton("Start recording", systemImage: "waveform.path.ecg", fullWidth: true) { start() }
                .disabled(!ready)
            Button("Change wrist") { step = .wrist }
                .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
        }
    }

    private func instruction(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space3) {
            Text(verbatim: "\(number)")
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.accent)
                .frame(width: NoopMetrics.space5)
            Text(text)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Step 3: recording

    private var recordingStep: some View {
        TimelineView(.animation) { context in
            let now = context.date
            let feed = live.ecgLive
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                statusLine(feed: feed, now: now)
                trace(feed: feed, now: now)
                progress(feed: feed, now: now)
                if let outcome = live.ecgSession?.wristOutcome, outcome != .success {
                    Text("The strap did not accept the wrist setting. The recording continues, but the trace may be upside down.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                NoopButton("Finish", systemImage: "stop.fill", kind: .secondary, fullWidth: true) {
                    finish(.userFinished)
                }
            }
        }
        .task(id: startedAt) {
            // One timer per start: a new start changes the id and cancels the previous sleep.
            guard let started = startedAt else { return }
            try? await Task.sleep(nanoseconds: UInt64(Self.maxDuration * 1_000_000_000))
            if !Task.isCancelled, startedAt == started { finish(.timeLimit) }
        }
    }

    @ViewBuilder
    private func statusLine(feed: EcgLiveFeed?, now: Date) -> some View {
        let waitedTooLong = feed == nil && now.timeIntervalSince(startedAt ?? now) > Self.firstRecordPatience
        let (text, color): (LocalizedStringKey, Color) = {
            guard let feed else {
                return waitedTooLong
                    ? ("No live data yet. Check that the strap is connected and your finger is on the clasp.",
                       StrandPalette.statusWarning)
                    : ("Starting the ECG sensor…", StrandPalette.textSecondary)
            }
            return feed.status?.presence == true
                ? ("Recording. Keep still and keep your finger on the clasp.", StrandPalette.statusPositive)
                : ("Waiting for contact. Press your fingertip on the clasp.", StrandPalette.statusWarning)
        }()
        HStack(spacing: NoopMetrics.space2) {
            Circle().fill(color).frame(width: NoopMetrics.space2, height: NoopMetrics.space2)
            Text(text)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func trace(feed: EcgLiveFeed?, now: Date) -> some View {
        let window = feed?.window(endingAt: now, count: Self.windowSamples).map(Double.init) ?? []
        let scaleSource = feed?.window(endingAt: now, count: Self.scaleSamples).map(Double.init) ?? []
        // Display-only baseline removal, as in the review screen. Filtering the longer scale window and
        // taking its tail keeps the filter's start-up transient off the visible trace.
        let filtered = EcgStrip.highPass(scaleSource, sampleRate: EcgLiveFeed.playbackRate)
        let visible = Array(filtered.suffix(window.count))
        let columns = EcgStrip.envelope(visible, columns: 480)
        let range = EcgStrip.verticalRange(EcgStrip.envelope(filtered, columns: 480))
        return EcgStripChart(columns: columns.map { EcgStripColumn(min: $0.min, max: $0.max) },
                             range: range,
                             seconds: Double(Self.windowSamples) / EcgLiveFeed.playbackRate,
                             height: 220)
    }

    private func progress(feed: EcgLiveFeed?, now: Date) -> some View {
        let elapsed = Int(now.timeIntervalSince(feed?.firstArrival ?? now))
        let raw = feed?.status.map { Int($0.progress) } ?? EcgStrip.progressNoSession
        let strapProgress: Int? = raw <= 100 ? raw : nil
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack {
                Text("Strap progress")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                Text(Duration.seconds(elapsed).formatted(.time(pattern: .minuteSecond)))
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            ProgressView(value: Double(strapProgress ?? 0), total: 100)
                .tint(StrandPalette.accent)
        }
    }

    // MARK: - Step 4: done

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            Text("Recording finished")
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
            Group {
                if finishReason == .timeLimit {
                    Text("Stopped at the time limit. The strap saved what it recorded.")
                } else {
                    Text("The strap saved the recording.")
                }
            }
            .font(StrandFont.body)
            .foregroundStyle(StrandPalette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            Text("The full-resolution waveform comes over with the next sync. Open Review ECG recordings in Test Centre to see it.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            NoopButton("Record again", systemImage: "arrow.counterclockwise", fullWidth: true) {
                step = .prepare
            }
            Button("Done") { dismiss() }
                .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
        }
    }

    // MARK: - Actions

    private func start() {
        // Only a start that actually sent commands moves on. A refused gate leaves this step in place,
        // so the screen never shows an old trace or another session's frames as this recording.
        guard model.ecgStartCapture(wrist: wrist, reportsResult: false) else { return }
        finishReason = nil
        startedAt = Date()
        step = .recording
    }

    private func finish(_ reason: FinishReason) {
        guard step == .recording else { return }
        model.ecgStopCapture(reportsResult: false)
        finishReason = reason
        step = .done
    }
}
