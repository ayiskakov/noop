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
/// `EcgLiveFeed`. Unlike `EcgReviewView`, which counts beats in stored R16 records, it shows a shape and
/// derives nothing from it: no heart rate, no rhythm, no classification. The trace has no time grid, because the R17 rate is not measured
/// (`docs/PROTOCOL_ECG.md` §Hardware observations), and it breaks where record indices were skipped.
/// The status line says only whether data is arriving; the strap's presence flag and quality code are
/// shown beside it as the raw values they are, never as contact or a grade.
///
/// ## What the strap did
///
/// Every statement about the strap comes from ONE place, the session (`LiveState.ecgSession`,
/// `Whoop5EcgSession`), so this screen and the strap log cannot disagree. The session keeps apart what
/// the protocol doc says to keep apart: a refused or unanswered wrist, a refused start, an accepted start
/// with no data, records received, and how the stop went. The screen adds only why IT ended the
/// recording.
///
/// ## Commands
///
/// Start sends SELECT_WRIST; the turn-on sequence follows once the strap accepts it
/// (`BLEManager.ecgStartCapture`). A start waits until an earlier session has been stopped. The screen
/// stops what it started: on Finish, when the strap's progress value reaches 100, at the hard cap, when
/// live output or generation is refused, and when the screen goes away mid-recording.
///
/// Reached only while the Experimental ECG opt-in is on, from Test Centre and the Devices ECG menu.
struct EcgCaptureView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = NoopMotionState.shared

    /// The wearer's wrist, remembered on this device only, as its stable token ("left" / "right") rather
    /// than the wire argument, so a remapped argument can never flip a remembered choice. Empty until the
    /// user picks one: the wrist decides the lead orientation, so a first run pre-selects nothing.
    @AppStorage("noop.ecgWristSide") private var wristToken = ""
    /// The Experimental ECG opt-in. The Devices menu can still offer this screen with the opt-in off
    /// while a capture may be running, so Start has to check it too.
    @AppStorage(PuffinExperiment.ecgKey) private var ecgEnabled = false

    @State private var step: Step = .wrist
    @State private var startedAt: Date?
    @State private var finishReason: FinishReason?

    private enum Step { case wrist, prepare, recording, done }
    /// Why the SCREEN ended a recording. What the strap did is the session's to say.
    private enum FinishReason { case userFinished, progressReached100, timeLimit, leftScreen, startRefused, disconnected }

    /// Samples in the sweeping window: four records' worth.
    private static let windowSamples = 400
    /// Samples the vertical scale is taken over, longer than the window so the trace does not resize at
    /// every beat.
    private static let scaleSamples = 1_000
    /// Horizontal resolution of the strip.
    private static let columns = 480
    /// Hard cap on one capture. The strap has its own timeout; this one keeps a forgotten screen from
    /// leaving the front end running.
    private static let maxDuration: TimeInterval = 90
    /// How long to wait for the first live record before saying none has come.
    private static let firstRecordPatience: TimeInterval = 12
    /// Records arrive about once a second; this long without one is reported as a stall.
    private static let staleAfter: TimeInterval = 3

    private var wrist: Whoop5Ecg.WristSelection? { Whoop5Ecg.WristSelection(token: wristToken) }

    private var linkReady: Bool { live.connected && live.encryptedBond && model.isWhoop5MG }

    /// An earlier start has not been resolved. `BLEManager` refuses another start until it is
    /// (`docs/PROTOCOL_ECG.md` §Repeated ECG start); this is read here so the screen says why.
    private var earlierSessionPending: Bool {
        live.ecgSession?.isActive == true || live.ecgMayBeRunning
    }

    /// The same gates `BLEManager` applies, read here so Start is disabled rather than silently ignored.
    private var ready: Bool { ecgEnabled && linkReady && !earlierSessionPending }

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
        // A probe run started from the Devices dialog would otherwise raise its result sheet over this
        // screen when its window closes. Its verdict still goes to the strap log.
        .onAppear { model.ecgDetachProbeResult() }
        // Stop what was started, and show how it went if the screen comes back (an iOS tab switch keeps it).
        .onDisappear { if step == .recording { finish(.leftScreen) } }
        .onChangeCompat(of: live.ecgLive?.status?.progress) { progress in
            // 255 is "no session" on the wire. The termination contract of the progress value is
            // unresolved, so reaching 100 ends the recording and is reported as exactly that.
            if step == .recording, progress == 100 { finish(.progressReached100) }
        }
        .onChangeCompat(of: live.ecgSession) { session in
            guard step == .recording, let session else { return }
            if !session.startSent, session.phase == .ended {
                // The wrist was refused or went unanswered: nothing started, so there is nothing to stop.
                step = .done
            } else if session.phase == .started, session.records == 0,
                      session.startOutcomes.values.contains(where: { $0 != .success }) {
                // A refused turn-on request: stop whatever the others switched on.
                finish(.startRefused)
            }
        }
        .onChangeCompat(of: live.connected) { connected in
            // The session records that the link dropped before its stop; the done step says so.
            if !connected, step == .recording {
                finishReason = .disconnected
                step = .done
            }
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
                .disabled(wrist == nil)
        }
    }

    private func wristChoice(_ choice: Whoop5Ecg.WristSelection, title: LocalizedStringKey) -> some View {
        let selected = wrist == choice
        return Button {
            wristToken = choice.token
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
                    instruction(1, wrist == .right
                                ? "Wear the strap snugly on your right wrist, sensor against the skin."
                                : "Wear the strap snugly on your left wrist, sensor against the skin.")
                    instruction(2, "Sit down and rest both arms on a table.")
                    instruction(3, "Press a fingertip of your other hand on the clasp's two indents and keep it there until the recording ends.")
                    instruction(4, "Stay still and don't talk. A slightly damp fingertip and unplugged chargers give a cleaner trace.")
                }
            }
            if !ecgEnabled {
                warning("Turn on WHOOP MG ECG capture (experimental) in Test Centre to start a recording.")
            } else if !linkReady {
                warning("Connect your WHOOP MG and let it finish pairing to start a recording.")
            } else if live.ecgSession?.phase == .stopping {
                warning("Waiting for the strap to confirm the stop…")
            } else if earlierSessionPending {
                warning("An earlier ECG session may still be running on the strap. Stop it before recording again.")
                Button("Stop it") { model.ecgStopCapture(reportsResult: false) }
                    .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
            }
            NoopButton("Start recording", systemImage: "waveform.path.ecg", fullWidth: true) { start() }
                .disabled(!ready || wrist == nil)
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

    private func warning(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.statusWarning)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Step 3: recording

    private var recordingStep: some View {
        recordingClock
            .task(id: startedAt) {
                // One timer per start: a new start changes the id and cancels the previous sleep.
                guard let started = startedAt else { return }
                try? await Task.sleep(nanoseconds: UInt64(Self.maxDuration * 1_000_000_000))
                if !Task.isCancelled, startedAt == started { finish(.timeLimit) }
            }
    }

    /// The sweep's clock. Thirty frames a second is smooth for a sweep and halves the work of the display
    /// rate. Under Reduce Motion, Low Power Mode or NOOP's quiet-motion setting the trace is still the
    /// content of this screen, so it keeps updating, twice a second, instead of stopping.
    @ViewBuilder
    private var recordingClock: some View {
        if motion.poseStill(reduceMotion) {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in recordingContent(now: context.date) }
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in recordingContent(now: context.date) }
        }
    }

    private func recordingContent(now: Date) -> some View {
        let feed = live.ecgLive
        return VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            statusLine(session: live.ecgSession, feed: feed, now: now)
            trace(feed: feed, now: now)
            strapFlags(feed: feed)
            progress(feed: feed, now: now)
            NoopButton("Finish", systemImage: "stop.fill", kind: .secondary, fullWidth: true) {
                finish(.userFinished)
            }
        }
    }

    /// Whether data is arriving, and nothing more: silence is reported as silence, never as a missing
    /// finger, which the protocol doc says it does not establish.
    private func statusLine(session: Whoop5EcgSession?, feed: EcgLiveFeed?, now: Date) -> some View {
        let (text, color): (LocalizedStringKey, Color) = {
            if session?.phase == .selectingWrist {
                return ("Setting the wrist…", StrandPalette.textSecondary)
            }
            guard let last = feed?.lastArrival else {
                return now.timeIntervalSince(startedAt ?? now) > Self.firstRecordPatience
                    ? ("No live data has arrived yet.", StrandPalette.statusWarning)
                    : ("Starting the ECG sensor…", StrandPalette.textSecondary)
            }
            let silent = now.timeIntervalSince(last)
            if silent > Self.staleAfter {
                return ("No new data for \(Int(silent)) s.", StrandPalette.statusWarning)
            }
            return ("Receiving data. Keep still and keep your fingertip on the clasp.", StrandPalette.statusPositive)
        }()
        return HStack(spacing: NoopMetrics.space2) {
            Circle().fill(color).frame(width: NoopMetrics.space2, height: NoopMetrics.space2)
            Text(text)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func trace(feed: EcgLiveFeed?, now: Date) -> some View {
        let scale = feed?.window(endingAt: now, count: Self.scaleSamples).map(Double.init) ?? []
        let scaleGaps = feed?.gapsInWindow(endingAt: now, count: Self.scaleSamples) ?? []
        // Display-only baseline removal, as in the review screen, per unbroken stretch so a gap never
        // enters the filter. Filtering the longer scale window and taking its tail keeps the filter's
        // start-up transient off the visible trace.
        let filtered = EcgStrip.filterSegments(scale, gapAfter: scaleGaps, sampleRate: EcgLiveFeed.playbackRate)
        let visibleCount = min(Self.windowSamples, filtered.count)
        let offset = filtered.count - visibleCount
        let visible = Array(filtered.suffix(visibleCount))
        let visibleGaps = Set(scaleGaps.filter { $0 >= offset }.map { $0 - offset })
        let columns = EcgStrip.envelope(visible, columns: Self.columns)
        let range = EcgStrip.verticalRange(EcgStrip.envelope(filtered, columns: Self.columns))
        // `seconds: 0`: no time grid, since the R17 rate is not measured.
        return EcgStripChart(columns: columns.map { EcgStripColumn(min: $0.min, max: $0.max) },
                             breakAfter: EcgStrip.breakColumns(gapAfter: visibleGaps, sampleCount: visible.count,
                                                               columns: columns.count),
                             range: range,
                             seconds: 0,
                             height: 220)
    }

    /// The newest record's presence flag and quality code, as the raw values they are
    /// (`docs/PROTOCOL_ECG.md` §Packed status): presence is not electrode contact, and the quality codes
    /// are not a scale.
    @ViewBuilder
    private func strapFlags(feed: EcgLiveFeed?) -> some View {
        if let status = feed?.status {
            let quality = Int(status.quality)
            let text: LocalizedStringKey = status.presence
                ? "Presence flag on · quality code \(quality)"
                : "Presence flag off · quality code \(quality)"
            Text(text)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
        }
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
        let session = live.ecgSession
        let started = session?.startSent == true
        return VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            Text(started ? "Recording finished" : "Not started")
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
            ForEach(Array(doneLines(session).enumerated()), id: \.offset) { _, line in
                Text(line.text)
                    .font(StrandFont.body)
                    .foregroundStyle(line.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            NoopButton("Record again", systemImage: "arrow.counterclockwise", fullWidth: true) {
                step = .prepare
            }
            Button("Done") { dismiss() }
                .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
        }
    }

    /// Every line the done step shows, resolved in one place from the session plus the screen's own
    /// reason, in the order: what came of the start, why the screen stopped, the save request, the stop.
    private func doneLines(_ session: Whoop5EcgSession?) -> [(text: LocalizedStringKey, color: Color)] {
        guard let session else { return [] }
        var lines: [(text: LocalizedStringKey, color: Color)] = []
        let primary = StrandPalette.textPrimary
        let warn = StrandPalette.statusWarning

        switch session.summary {
        case .wristRefused(let outcome):
            lines.append(("The strap did not accept the wrist setting (\(outcome.token)). Nothing was recorded.", warn))
        case .wristUnanswered:
            lines.append(("The strap did not answer the wrist setting. Nothing was recorded.", warn))
        case .cancelled:
            lines.append(("Finished before the strap answered the wrist setting. Nothing was recorded.", primary))
        case .startRefused(let opcode, let outcome):
            lines.append(("The strap refused to start (\(Self.describe(opcode, outcome))).", warn))
        case .startUnanswered:
            lines.append(("The strap did not answer every start request, and no live data arrived.", warn))
        case .acceptedWithoutRecords:
            lines.append(("The strap accepted the start, but no live data arrived.", warn))
        case .recorded(let records):
            lines.append(("Live records received: \(records).", primary))
        }

        switch finishReason {
        case .timeLimit: lines.append(("Stopped at the \(Int(Self.maxDuration))-second limit.", primary))
        case .progressReached100: lines.append(("Stopped when the strap's progress reached 100.", primary))
        case .leftScreen: lines.append(("Stopped when you left this screen.", primary))
        case .userFinished, .startRefused, .disconnected, nil: break
        }

        if session.startSent {
            lines.append(session.saveAccepted
                ? ("The strap accepted the request to save the full-resolution recording. It comes over with the next sync; open Review ECG recordings in Test Centre to see it.", primary)
                : ("The strap did not confirm the request to save the full-resolution recording.", warn))
        }

        switch session.stopResult {
        case nil:
            lines.append(("Waiting for the strap to confirm the stop…", StrandPalette.textSecondary))
        case .unsent:
            lines.append(("The stop could not be sent, so the strap may still be recording. Reconnect, then use Stop ECG capture on the Devices screen.", warn))
        case .refused(let opcode, let outcome):
            lines.append(("The strap refused to stop (\(Self.describe(opcode, outcome))). It may still be recording.", warn))
        case .unanswered:
            lines.append(("The strap did not confirm every stop request. It may still be recording.", warn))
        case .notNeeded, .confirmed:
            break
        }
        return lines
    }

    /// "ECG Data Generation (MG) FAILURE(0)": the request and the strap's raw answer to it.
    private static func describe(_ opcode: UInt8, _ outcome: Whoop5EcgSession.Outcome) -> String {
        let name = WhoopCommand(rawValue: opcode)?.label ?? "\(opcode)"
        return "\(name) \(outcome.token)"
    }

    // MARK: - Actions

    private func start() {
        // Only a start that actually sent something moves on. A refused gate leaves this step in place,
        // so the screen never shows an old trace or another session's frames as this recording.
        guard let wrist, model.ecgStartCapture(wrist: wrist, reportsResult: false) else { return }
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
