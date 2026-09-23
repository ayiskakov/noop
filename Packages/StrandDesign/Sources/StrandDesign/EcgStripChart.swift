#if !os(watchOS)
import SwiftUI

// MARK: - EcgStripChart (#891 — gated R16 ECG review)
//
// Draws one window of a WHOOP 5/MG R16 waveform as a dense min/max strip, with a seconds grid and an
// optional contact band beneath it.
//
// UNVALIDATED INSTRUMENTATION. This view renders a shape and labels nothing. There is no amplitude axis
// because there is no calibration to put on one — `docs/PROTOCOL_ECG.md` is explicit that the front
// end's configuration does not establish volts per count — and there is deliberately no heart rate, no
// interval and no rhythm annotation anywhere in it.
//
// The view takes COLUMNS, not samples. Reducing a waveform to pixel columns is arithmetic with a
// correctness property (a narrow deflection must survive it), so it lives in `StrandAnalytics.EcgStrip`
// where `swift test` covers it; this file owns only layout and colour. The `Column` type below is
// declared locally rather than imported because StrandDesign has no package dependencies and must keep
// none — the caller maps across, which is one `map` at the call site.

/// One pixel column's vertical extent, in the waveform's own units.
public struct EcgStripColumn: Equatable, Sendable {
    public let min: Double
    public let max: Double
    public init(min: Double, max: Double) {
        self.min = min
        self.max = max
    }
}

public struct EcgStripChart: View {

    /// The window's columns, left to right. One per horizontal pixel-ish unit; the view stretches them
    /// to its width, so fewer columns than pixels renders as a visibly sparser trace rather than as a
    /// gap — which is the honest rendering of a recording that holds less data than the space given it.
    public var columns: [EcgStripColumn]
    /// Column indices after which the trace must BREAK. A gap is a stretch the strap recorded nothing
    /// for; joining across it would draw a line the data does not support.
    public var breakAfter: Set<Int>
    /// The vertical extent to map `columns` onto. Supplied rather than derived so a caller can hold the
    /// scale steady while scrolling, instead of having the trace resize under the user at every step.
    public var range: (min: Double, max: Double)
    /// Seconds the window covers, for the vertical grid. Zero draws no grid.
    public var seconds: Double
    /// The slower contact/lead-state entries under this window, or `[]` for none. Rendered as the strap's
    /// own flag — never as a quality score, which `docs/PROTOCOL_ECG.md` says these codes are not.
    public var contactFlags: [Bool]
    public var height: CGFloat

    public init(columns: [EcgStripColumn], breakAfter: Set<Int> = [],
                range: (min: Double, max: Double), seconds: Double,
                contactFlags: [Bool] = [], height: CGFloat = 200) {
        self.columns = columns
        self.breakAfter = breakAfter
        self.range = range
        self.seconds = seconds
        self.contactFlags = contactFlags
        self.height = height
    }

    /// Height of the contact band under the trace, when there is one to draw.
    private static let contactBandHeight: CGFloat = 10
    /// Seconds between major gridlines. One second is a WIRE FACT — the strap emits one record per
    /// second — which is exactly why the grid is drawn in seconds and not in the millimetres of ECG
    /// paper: paper gridlines would imply a calibrated sweep speed and amplitude that nothing here has.
    private static let majorGridSeconds: Double = 1.0
    /// Minor divisions per major. Five, so a major second reads as five 200 ms divisions.
    private static let minorGridDivisions = 5

    public var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
            GeometryReader { geo in
                ZStack {
                    grid(size: geo.size)
                    trace(size: geo.size)
                }
            }
            .frame(height: height)
            .background(StrandPalette.surfaceInset)
            .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.space1, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: NoopMetrics.space1, style: .continuous)
                    .stroke(StrandPalette.hairline, lineWidth: 1))

            if !contactFlags.isEmpty { contactBand }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Waveform strip", bundle: .module))
        // Says what it is and what it is not. A waveform has no useful VoiceOver rendering as a shape,
        // so the accessible description is the honest summary rather than a described picture. A strip
        // drawn without a time scale announces none, rather than "0 seconds".
        .accessibilityValue(seconds > 0
            ? Text("\(Int(seconds.rounded())) seconds of unvalidated sensor waveform. Uncalibrated amplitude, no heart rate shown.",
                   bundle: .module)
            : Text("Unvalidated sensor waveform. Uncalibrated amplitude, no heart rate shown.", bundle: .module))
    }

    // MARK: - Grid

    private func grid(size: CGSize) -> some View {
        Canvas { ctx, s in
            guard seconds > 0, s.width > 0 else { return }
            let perSecond = s.width / seconds
            // A dense window would draw thousands of minor lines into a few hundred points. Below about
            // three points apart they stop being a grid and become a wash that hides the trace, so the
            // minor pass is skipped rather than drawn illegibly.
            let minorSpacing = perSecond / Double(Self.minorGridDivisions)
            if minorSpacing >= 3 {
                var minor = Path()
                var x = 0.0
                while x <= s.width {
                    minor.move(to: CGPoint(x: x, y: 0))
                    minor.addLine(to: CGPoint(x: x, y: s.height))
                    x += minorSpacing
                }
                ctx.stroke(minor, with: .color(StrandPalette.hairline.opacity(0.35)), lineWidth: 0.5)
            }
            if perSecond >= 6 {
                var major = Path()
                var x = 0.0
                while x <= s.width {
                    major.move(to: CGPoint(x: x, y: 0))
                    major.addLine(to: CGPoint(x: x, y: s.height))
                    x += perSecond * Self.majorGridSeconds
                }
                ctx.stroke(major, with: .color(StrandPalette.hairline.opacity(0.8)), lineWidth: 0.5)
            }
            // The horizontal midline is a drawing reference, NOT a zero volts line: the strip
            // self-scales to the window, so this sits at the middle of whatever range is on screen.
            var mid = Path()
            mid.move(to: CGPoint(x: 0, y: s.height / 2))
            mid.addLine(to: CGPoint(x: s.width, y: s.height / 2))
            ctx.stroke(mid, with: .color(StrandPalette.hairline.opacity(0.5)), lineWidth: 0.5)
        }
    }

    // MARK: - Trace

    private func trace(size: CGSize) -> some View {
        Canvas { ctx, s in
            guard !columns.isEmpty, s.width > 0, s.height > 0 else { return }
            let span = range.max - range.min
            guard span > 0 else { return }
            let step = s.width / Double(columns.count)
            // One vertical stroke per column, spanning that column's min..max. This is what makes a
            // dense waveform read correctly at any zoom: the column carries both extremes of every
            // sample it covers, so a narrow peak is drawn at full height rather than sampled away.
            var path = Path()
            for (i, col) in columns.enumerated() {
                let x = (Double(i) + 0.5) * step
                let yTop = s.height * (1 - (col.max - range.min) / span)
                let yBottom = s.height * (1 - (col.min - range.min) / span)
                path.move(to: CGPoint(x: x, y: yTop))
                // A column whose samples are all equal has zero height and would stroke nothing, so it
                // is drawn as a minimum-length tick — a flat stretch must still show as a line.
                path.addLine(to: CGPoint(x: x, y: Swift.max(yBottom, yTop + 0.5)))
                // Join to the next column unless a gap intervenes. Without the join a sparse window
                // renders as disconnected ticks; with it across a gap, the trace claims continuity the
                // strap never recorded.
                if i + 1 < columns.count, !breakAfter.contains(i) {
                    let next = columns[i + 1]
                    let nx = (Double(i) + 1.5) * step
                    let nyTop = s.height * (1 - (next.max - range.min) / span)
                    let nyBottom = s.height * (1 - (next.min - range.min) / span)
                    path.move(to: CGPoint(x: x, y: (yTop + yBottom) / 2))
                    path.addLine(to: CGPoint(x: nx, y: (nyTop + nyBottom) / 2))
                }
            }
            ctx.stroke(path, with: .color(StrandPalette.textPrimary),
                       style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
        }
    }

    // MARK: - Contact band

    private var contactBand: some View {
        GeometryReader { geo in
            Canvas { ctx, s in
                guard !contactFlags.isEmpty, s.width > 0 else { return }
                let step = s.width / Double(contactFlags.count)
                for (i, closed) in contactFlags.enumerated() {
                    let rect = CGRect(x: Double(i) * step, y: 0, width: step, height: s.height)
                    // Closed uses the chrome accent and open the tertiary text colour — deliberately a
                    // presence/absence pair rather than a good/bad one. The strap reports a lead-state
                    // flag; it does not grade the signal, and neither does this band.
                    ctx.fill(Path(rect), with: .color(closed
                        ? StrandPalette.accent.opacity(0.65)
                        : StrandPalette.textTertiary.opacity(0.28)))
                }
            }
            .frame(width: geo.size.width, height: Self.contactBandHeight)
            .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.spaceHalf, style: .continuous))
        }
        .frame(height: Self.contactBandHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Contact indicator", bundle: .module))
        .accessibilityValue(Text(
            "\(contactFlags.filter { $0 }.count) of \(contactFlags.count) intervals reported the electrode circuit closed.",
            bundle: .module))
    }
}
#endif
