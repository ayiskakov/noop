import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Blood Oxygen · strap estimate (#103)
//
// WHY THIS CARD EXISTS. The `@82` candidate reached exactly one surface: a single rounded integer in the
// Blood Oxygen tile, shown only when no calibrated import existed. Everything else the night contained
// was banked and never shown — so a wearer whose night averaged 96 % with a run down to 77 % saw "96 %",
// the same thing a flat night shows, and the strap log's own census said "nothing banked from the offload
// for: spo2" (it counts the WHOOP 4.0 red/IR table, which a 5/MG structurally never fills). The honest
// reading of that combination is "NOOP is not collecting this", which is what a 5/MG owner concluded.
//
// This card is the other half of the fix: the figures the mean cannot carry — the night's low, its dips,
// and how many readings the whole thing rests on. Nothing here is a blood-oxygen measurement: `@82` is an
// unvalidated candidate (`docs/PROTOCOL_SENSORS.md` §R18 calls it a "sleep-adjacent raw byte", and the
// cross-device evidence is split), so every figure sits under the same "unverified" framing the tile uses
// and none of it is written to `spo2Pct` or fed to a score.
//
// ONE NIGHT, ONE FUNNEL. The four figures are read from four separate metricSeries rows, and a card that
// resolved each one itself could pair last night's mean with an older night's low the moment one row
// lagged a scoring pass — the failure AGENTS.md's "two readouts of one fact" rule is about. So the night
// is resolved by `Spo2CandidateSeries.latest` (pure, in the package, CI-tested) and this view only
// formats what it returns. It also STAMPS the night it is describing, because the Blood Oxygen tile
// resolves its own day through a staleness-bounded carry: the two can legitimately be showing different
// nights, and the only wrong answer is not saying which.

/// The night's SpO₂ strap-estimate figures: mean, low, dips and the reading count behind them, plus a
/// 14-night trend of the mean. Renders nothing at all unless the experimental candidate toggle is ON and
/// at least one night has been scored — an empty card would be a claim about the strap.
struct Spo2EstimateCard: View {
    /// The resolved night, or nil when nothing has been scored. Resolved by the caller through
    /// `Spo2CandidateSeries.latest` so the card cannot pick a different night than the one it was given.
    let night: Spo2CandidateSeries.Night?
    /// Nightly means, oldest → newest, for the sparkline under the average. Unrounded.
    let meanTrend: [Double]
    /// The threshold the dips were cut at, named rather than assumed. Carried from
    /// `AnalyticsEngine.spo2CandidateDipThreshold` by the caller.
    let dipThreshold: Int

    var body: some View {
        if let night {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Blood Oxygen", overline: "Strap estimate",
                              trailing: Self.nightLabel(night.day))
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 120), spacing: NoopMetrics.gap)],
                    alignment: .leading,
                    spacing: NoopMetrics.gap
                ) {
                    StatTile(label: "Average",
                             value: "\(night.meanRounded)%",
                             caption: String(localized: "strap estimate (unverified)"),
                             accent: StrandPalette.metricCyan,
                             sparkline: Self.spark(meanTrend),
                             sparkColor: StrandPalette.metricCyan)
                    StatTile(label: "Low",
                             value: night.minimum.map { "\($0)%" } ?? "—",
                             caption: lowCaption(night),
                             accent: StrandPalette.metricCyan)
                    StatTile(label: "Dips",
                             value: night.dips.map(String.init) ?? "—",
                             caption: dipsCaption(night),
                             accent: StrandPalette.metricCyan)
                    StatTile(label: "Readings",
                             value: night.samples.map(String.init) ?? "—",
                             caption: String(localized: "in-band, this night"),
                             accent: StrandPalette.textPrimary)
                }
                Text("Your strap reports this every second while it scores a night. It is the band's own unverified figure, not a calibrated blood-oxygen measurement, and NOOP never feeds it into recovery or any other score.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Captions

    /// The threshold as a display string, interpolated into the captions below as `%@`.
    ///
    /// Pre-formatted rather than interpolated as a number with a literal "%" after it, because that would
    /// put a bare percent sign into every catalog key ("dipped below %lld%%") — a format specifier's
    /// escape hatch sitting next to a real specifier, in ten languages, for no gain. `%@` is one
    /// placeholder with nothing to escape.
    private var thresholdLabel: String { "\(dipThreshold)%" }

    /// The Low tile's caption names the threshold so the number above it is readable without knowing the
    /// project's convention. When the night never went below it, say so — that IS the finding.
    private func lowCaption(_ night: Spo2CandidateSeries.Night) -> String {
        guard night.minimum != nil else { return "" }
        // `dipped == nil` is a night scored before the dip keys shipped: unknown, so claim nothing.
        guard let dipped = night.dipped else { return "" }
        return dipped
            ? String(localized: "dipped below \(thresholdLabel)")
            : String(localized: "stayed above \(thresholdLabel)")
    }

    /// The Dips tile's caption. The seconds are measured BETWEEN readings (see
    /// `Spo2DesatEvent.spanSeconds`), so a night whose only dips were single readings legitimately has
    /// zero seconds — and captioning that "0 s below" beside a dip count of 2 would read as a
    /// contradiction. So the duration is shown only when there is one to show, and the count stands alone
    /// otherwise, which is exactly what was measured.
    private func dipsCaption(_ night: Spo2CandidateSeries.Night) -> String {
        guard let dips = night.dips else { return "" }
        guard dips > 0 else { return String(localized: "none below \(thresholdLabel)") }
        guard let secs = night.dipSeconds, secs > 0 else {
            return String(localized: "momentary, below \(thresholdLabel)")
        }
        return String(localized: "\(secs)s below \(thresholdLabel)")
    }

    /// "Night of 21 Sep" — the night this card's figures came from, stamped because the Blood Oxygen tile
    /// resolves its own day through a carry and the two can honestly differ.
    static func nightLabel(_ day: String) -> String {
        guard let date = dayKeyFormatter.date(from: day) else { return day }
        return String(localized: "Night of \(nightStampFormatter.string(from: date))")
    }

    /// A sparkline needs at least two points; fewer draws nothing rather than a single dot.
    static func spark(_ series: [Double]) -> [Double]? {
        let tail = Array(series.suffix(14))
        return tail.count >= 2 ? tail : nil
    }

    /// Parses the `YYYY-MM-DD` series key. POSIX + UTC: a day KEY is a label, not an instant, so it must
    /// not be re-interpreted through the device locale or calendar.
    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// Renders that parsed day for a reader, in THEIR locale — the parse above is machine-side, this is
    /// the display side, and they are deliberately two formatters.
    private static let nightStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM")
        f.locale = AppLanguage.activeLocale
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}
