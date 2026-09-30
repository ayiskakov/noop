import Foundation
import WhoopProtocol

// MARK: - Nightly SpO2 candidate statistics (#103/#112)

/// One below-threshold `@82` measurement window inside a night.
///
/// The strap does not report this byte every second. It measures in windows (30 records every 1200 s
/// while the band scores the wearer asleep, on the straps measured so far; `docs/PROTOCOL_SENSORS.md`
/// §R18), and inside one window its value is a rolling figure that moves a few points and can blip for a
/// single second. So the window is the measurement, and a dip is a window whose value sits below the
/// threshold — not a second that did (W03-003).
///
/// `spanSeconds` is measured between the FIRST and LAST in-band second of the window, not multiplied out
/// of the sample count. The R18 stream is documented as "roughly one packet per second", which is not a
/// cadence guarantee — so a window with one in-band second has a span of zero seconds, because one second
/// is all that was observed. Turning `samples` into seconds would state a duration nothing measured.
public struct Spo2DesatEvent: Equatable, Sendable {
    /// Unix seconds of the window's first in-band second.
    public let start: Int
    /// Unix seconds of the window's last in-band second.
    public let end: Int
    /// The window's value: its median in-band reading (see `Spo2CandidateWindow.value`).
    public let nadir: Int
    /// How many in-band seconds the window rests on.
    public let samples: Int

    public init(start: Int, end: Int, nadir: Int, samples: Int) {
        self.start = start; self.end = end; self.nadir = nadir; self.samples = samples
    }

    /// Observed span, first in-band second to last. Zero for a one-second window — see the type's note.
    public var spanSeconds: Int { max(0, end - start) }
}

/// Why a reading was, or was not, allowed to stand for its 30 seconds (W03-007).
///
/// Defined by what the strap REPORTED during the reading — how many of its seconds carried a value, and
/// whether those values agree — never by whether the value is low. A reading that is low, steady and well
/// covered stays a low reading: a filter tuned on the outcome would hide exactly the nights it exists for.
public enum Spo2CandidateReadingQuality: Equatable, Sendable {
    /// Enough in-band seconds, and most of them agree with the reading's middle value.
    case reliable
    /// Fewer than `AnalyticsEngine.spo2CandidateMinCoverage` of the reading's measured seconds carried an
    /// in-band value (the rest were the strap's own non-percentage codes), or fewer in-band seconds than
    /// the floor (`AnalyticsEngine.spo2CandidateMinReadingSeconds`) to judge at all.
    case lowCoverage
    /// Enough seconds, but too few of them sit near the middle value: the reading swept across the band
    /// instead of settling on a figure.
    case unsettled
    /// Codes only: the strap measured and produced no in-band second at all.
    case noValue
}

/// One `@82` measurement window: a run of nonzero seconds, no two further apart than
/// `AnalyticsEngine.spo2CandidateWindowGapSeconds` and spanning less than
/// `AnalyticsEngine.spo2CandidateWindowMaxSpanSeconds`.
///
/// A nonzero byte means the strap was measuring that second. On one MG this is exact: the byte is nonzero
/// in precisely the seconds its optical status words at `@77`/`@79` leave their idle values, with no
/// exception either way over 588,883 records. A window can therefore hold only failure codes (sub-70 or
/// bit-7 values) and no in-band reading at all; it still counts as ATTEMPTED.
struct Spo2CandidateWindow {
    /// Every nonzero second of the window, codes included: the seconds the strap spent measuring.
    var measuredSeconds = 0
    /// The window's in-band seconds, ascending by timestamp. Empty for a window of failure codes only.
    var inBand: [(ts: Int, value: Int)] = []

    /// The window's value: its median in-band reading, taking the LOWER of the two middle readings when
    /// the count is even, so the value is always one the strap actually reported. The median rather than
    /// the mean or the minimum because the strap's figure is a rolling value: a one-second blip of 18
    /// points between steady neighbours is not a physiological change, and must neither become the
    /// window's value nor drag it. nil for a window with no in-band second.
    var value: Int? {
        guard !inBand.isEmpty else { return nil }
        let sorted = inBand.map(\.value).sorted()
        return sorted[(sorted.count - 1) / 2]
    }

    /// W03-007: whether the value may stand for the reading. Integer arithmetic throughout, so the
    /// verdict cannot differ between platforms or depend on how a fraction rounds.
    ///
    /// Coverage first: when most of a reading's measured seconds are codes, its in-band seconds are the
    /// fragments between them, and on the owner's loose-strap nights those fragments carried every false
    /// dip. Then agreement: a reading whose seconds are mostly within
    /// `spo2CandidateAgreementTolerance` of its median has settled on a figure. That test, rather than a
    /// cap on the reading's spread, is what tolerates the settling ramp a clean reading can open with
    /// (four seconds climbing into a steady value) while still refusing a reading that sweeps the band.
    ///
    /// Both tests are ratios, and a ratio cannot judge a fragment: one in-band second of one measured is
    /// full coverage and full agreement. `minimumSeconds` is the floor below which a reading is too short
    /// to stand for anything (W03-013).
    func quality(minimumSeconds: Int = AnalyticsEngine.spo2CandidateMinReadingSeconds) -> Spo2CandidateReadingQuality {
        guard let median = value else { return .noValue }
        let n = inBand.count
        guard n >= minimumSeconds else { return .lowCoverage }
        let cover = AnalyticsEngine.spo2CandidateMinCoverage
        guard n * cover.denominator >= measuredSeconds * cover.numerator else { return .lowCoverage }
        let tol = AnalyticsEngine.spo2CandidateAgreementTolerance
        let near = inBand.filter { abs($0.value - median) <= tol }.count
        let agree = AnalyticsEngine.spo2CandidateMinAgreement
        guard near * agree.denominator >= n * agree.numerator else { return .unsettled }
        return .reliable
    }
}

/// Everything one night's in-band `@82` readings support, resolved ONCE.
///
/// WHY ONE TYPE. The nightly mean already had four readers (the Today tile, `VitalSignsSummary`, the
/// Metric Explorer fallback and the strap-log diagnostic) and the stats added beside it would have had
/// the same. AGENTS.md's rule is that two readouts of one fact must not be able to disagree, and its
/// preferred defence is one gated funnel every surface resolves through rather than a count of call
/// sites. So this is the funnel: `mean` is unrounded here and rounded at the display edge, the rounded
/// value is derived (`meanRounded`) rather than stored a second time, and the below-threshold totals are
/// derived from `events` rather than tallied independently — none of the three can drift from the others
/// because none of them is a separate copy.
///
/// NOT A BLOOD-OXYGEN READING. `@82` is an unvalidated candidate: `docs/PROTOCOL_SENSORS.md` §R18 calls
/// it a "sleep-adjacent raw byte", and the cross-device evidence is split (an 8-night check tracked the
/// WHOOP app at corr +0.99, while two nights on the original #103 strap moved the opposite way). Nothing
/// here may write `spo2Pct` or feed a downstream gate.
///
/// PER WINDOW, NOT PER SECOND (W03-003). Every figure below is resolved over measurement windows (see
/// `Spo2DesatEvent`): the mean averages the windows' values, the minimum and maximum are the lowest and
/// highest window values, and a dip is a window below the threshold. Per-second figures turned a one-second
/// blip inside a steady window into the night's "low" and into a dip no window showed.
///
/// RELIABLE READINGS ONLY (W03-007). A reading counts only when the strap reported enough of its seconds
/// as values and those values agree (`Spo2CandidateReadingQuality`). On a loose-strap night most readings
/// come back mixed with the strap's own codes, and their fragments supplied every false dip; they are
/// counted as low quality and left out, so the night states what it measured instead of averaging noise.
public struct Spo2CandidateNight: Equatable, Sendable {
    /// Unrounded mean of the reliable readings' values. Stored unrounded so a sub-1 % night-to-night move
    /// survives to the series; every display rounds it at the edge. nil when the strap attempted readings
    /// but none was reliable (W03-007): the night is then reported as having no reliable reading rather
    /// than averaged from readings that failed the check.
    public let mean: Double?
    /// The lowest and highest reliable reading values; nil exactly when `mean` is.
    public let minimum: Int?
    public let maximum: Int?
    /// In-band SECONDS inside the reliable readings. Kept for the stored series, whose meaning it has
    /// always had; the evidence a night rests on is `windows`, because the seconds inside one reading are
    /// one rolling measurement, not independent readings.
    public let samples: Int
    /// Reliable readings: the measurements every figure above rests on.
    public let windows: Int
    /// Every reading the strap measured in, failed and low-quality ones included.
    public let windowsAttempted: Int
    /// Readings with an in-band value that failed the quality check, split by reason (W03-007). A reading
    /// of codes only is in neither: it had no value to leave out.
    public let windowsLowCoverage: Int
    public let windowsUnsettled: Int
    /// The threshold `events` were cut at, carried so a surface can name it instead of assuming one.
    public let threshold: Int
    /// Reliable readings below the threshold, ascending by `start`.
    public let events: [Spo2DesatEvent]

    public init(mean: Double?, minimum: Int?, maximum: Int?, samples: Int, windows: Int,
                windowsAttempted: Int, windowsLowCoverage: Int = 0, windowsUnsettled: Int = 0,
                threshold: Int, events: [Spo2DesatEvent]) {
        self.mean = mean; self.minimum = minimum; self.maximum = maximum
        self.samples = samples; self.windows = windows; self.windowsAttempted = windowsAttempted
        self.windowsLowCoverage = windowsLowCoverage; self.windowsUnsettled = windowsUnsettled
        self.threshold = threshold; self.events = events
    }

    /// The shipped display value — round-half-away-from-zero, matching what `nightlySpo2CandidateMean`
    /// has always returned. Every in-band value is positive, so no platform-divergence risk.
    public var meanRounded: Int? { mean.map { Int($0.rounded()) } }

    /// Readings that had a value and were left out as low quality. Derived, so it cannot disagree with
    /// the two reasons it sums.
    public var windowsLowQuality: Int { windowsLowCoverage + windowsUnsettled }

    /// In-band seconds the dip readings hold — every in-band second of each below-threshold window, not
    /// only the seconds that were themselves below it: the reading is the unit, and a second inside it is
    /// not a separate observation. Derived from `events`, so it cannot disagree with them.
    public var dipSamples: Int { events.reduce(0) { $0 + $1.samples } }

    /// Summed observed span of the dip readings. See `Spo2DesatEvent.spanSeconds`: this is time BETWEEN
    /// in-band seconds, so it under-reports rather than inventing a cadence, and it is zero for a night
    /// whose only dips were readings of one in-band second. It is how long the dip READINGS were measured,
    /// not how long the value stayed below the threshold.
    public var dipSpanSeconds: Int { events.reduce(0) { $0 + $1.spanSeconds } }

    /// The lowest below-threshold window value, or nil when no window went below the threshold. This is
    /// `minimum` whenever any event exists; kept separate so a surface can say "no dips" without having
    /// to infer it from a minimum that may sit above the threshold.
    public var nadir: Int? { events.map(\.nadir).min() }
}

extension AnalyticsEngine {

    /// The in-band window the decoder itself applies when it emits `spo2_candidate_82`: sub-70 nonzero
    /// values are diagnostic codes and bit-7 values are saturation sentinels, so neither is a percentage
    /// of anything. Shared by every statistic below so the gate is stated once.
    public static let spo2CandidateInBand = 70...100

    /// Default cut for a "dip". 90 % is the ordinary convention for flagging a desaturation, adopted here
    /// as a DISPLAY threshold only — `@82` is not a validated SpO2 percentage, so this does not make a
    /// flagged reading a clinical desaturation event. Carried on the result (`Spo2CandidateNight.threshold`)
    /// so a surface names the number it was cut at rather than assuming this one.
    public static let spo2CandidateDipThreshold = 90

    /// Nonzero seconds further apart than this belong to DIFFERENT measurement windows. On the straps
    /// measured so far a window is 30 consecutive records and the next starts 1200 s after the last began,
    /// so this neither splits one window over a few missing records nor merges two windows; and bridging a
    /// longer gap would report one measurement across a stretch nothing was measured in.
    public static let spo2CandidateWindowGapSeconds = 30

    /// No window spans this many seconds or more: a nonzero second this far after its window's first one
    /// opens the next window. It exists for a strap or firmware that reports the byte continuously, which
    /// would otherwise collapse a whole night into ONE window with one median and hide a real ten-minute
    /// dip; such a stream is resolved in readings of under a minute instead. It is twice the observed
    /// 30-record window so a window stretched by a stepped or skipped timestamp (a relaunch's SET_CLOCK
    /// steps the strap clock by a few seconds) stays whole: splitting off its last second would turn that
    /// second into a reading of its own, which is the blip-becomes-a-dip failure this type removes.
    public static let spo2CandidateWindowMaxSpanSeconds = 60

    /// W03-007: the smallest share of a reading's MEASURED seconds (codes included) that must carry an
    /// in-band value, as an exact fraction. Two thirds, so a reading rests on a clear majority of its own
    /// seconds. From one MG's 192 in-session readings: on its well-fitted nights a reading reaches this in
    /// 80–100 % of cases, and the night's figures barely move anywhere between one half and four fifths —
    /// so the value is not doing fine work. No published source gives a coverage rule for this byte;
    /// validated wrist oximeters discard 15–50 % of overnight data by their own quality indices.
    public static let spo2CandidateMinCoverage = (numerator: 2, denominator: 3)

    /// W03-013: the fewest in-band seconds a reading needs before the two ratios can judge it. Ten, a
    /// third of the strap's 30-record reading. On the owner's 15 backups 302 of 303 distinct readings
    /// have 30 measured seconds and every reliable one has 20 or more in-band seconds, so the floor moves
    /// no real reading; it exists for a reading a session edge cuts to a few seconds.
    public static let spo2CandidateMinReadingSeconds = 10

    /// W03-007: how far, in points, an in-band second may sit from its reading's median and still agree
    /// with it. On the same MG, 70 of 74 clean readings (no code, 28+ in-band seconds) never step more
    /// than 2 points between consecutive seconds.
    public static let spo2CandidateAgreementTolerance = 2

    /// W03-007: the smallest share of a reading's in-band seconds that must agree with its median, as an
    /// exact fraction. Three fifths: loose enough for a clean reading's settling ramp and its genuine
    /// few-point swings, strict enough to refuse a reading that sweeps from the 70s to 100 in seconds.
    public static let spo2CandidateMinAgreement = (numerator: 3, denominator: 5)

    /// The night's `@82` readings, in timestamp order, over the detected in-bed `sessions`: every window
    /// the strap measured in, each carrying its measured seconds, its in-band seconds and its quality.
    /// The ONE place readings are cut from the stream, so the night's figures and its trace cannot be cut
    /// two ways.
    static func spo2CandidateWindows(
        _ sessions: [SleepSession],
        aux: [V18AuxSample],
        windowGapSeconds: Int = AnalyticsEngine.spo2CandidateWindowGapSeconds
    ) -> [Spo2CandidateWindow] {
        guard !sessions.isEmpty, !aux.isEmpty else { return [] }
        var measured: [(ts: Int, value: Int)] = []
        for a in aux {
            guard let v = a.auxByte82, v != 0 else { continue }
            guard sessions.contains(where: { $0.start <= a.ts && a.ts <= $0.end }) else { continue }
            measured.append((ts: a.ts, value: v))
        }
        measured.sort { $0.ts < $1.ts }

        var windows: [Spo2CandidateWindow] = []
        var lastTs: Int?, windowStart = 0
        for m in measured {
            if let last = lastTs, m.ts - last <= max(0, windowGapSeconds),
               m.ts - windowStart < spo2CandidateWindowMaxSpanSeconds {
                // Same window.
            } else {
                windows.append(Spo2CandidateWindow())
                windowStart = m.ts
            }
            lastTs = m.ts
            windows[windows.count - 1].measuredSeconds += 1
            if spo2CandidateInBand.contains(m.value) {
                windows[windows.count - 1].inBand.append(m)
            }
        }
        return windows
    }

    /// THE resolver for a night's `@82` candidate readings — mean, range, below-threshold readings and
    /// the reading counts — over the detected in-bed `sessions`. nil when the strap measured nothing
    /// inside any span. A night whose readings all failed (codes only, or low quality) is NOT nil: it is
    /// a night with no reliable reading, which a surface must be able to say (W03-007).
    ///
    /// Session-bounded inclusively on both ends (unchanged from the mean this replaces). A window is a run
    /// of NONZERO seconds, codes included, so a window of failure codes still counts as attempted; only
    /// `spo2CandidateInBand` seconds contribute a value, and only reliable readings contribute a figure.
    /// It reads `aux` in TIMESTAMP ORDER rather than arrival order: windows depend on adjacency, and
    /// `v18AuxSamples` ordering is a property of that query, not of this input.
    ///
    /// DIAGNOSTIC ONLY. Nothing scores this and it never writes `spo2Pct`.
    public static func nightlySpo2CandidateNight(
        _ sessions: [SleepSession],
        aux: [V18AuxSample],
        threshold: Int = AnalyticsEngine.spo2CandidateDipThreshold,
        windowGapSeconds: Int = AnalyticsEngine.spo2CandidateWindowGapSeconds,
        minimumSeconds: Int = AnalyticsEngine.spo2CandidateMinReadingSeconds
    ) -> Spo2CandidateNight? {
        let windows = spo2CandidateWindows(sessions, aux: aux, windowGapSeconds: windowGapSeconds)
        guard !windows.isEmpty else { return nil }
        let quality = windows.map { $0.quality(minimumSeconds: minimumSeconds) }
        // `value` is non-nil for every reliable window: `quality` returns `.noValue` first otherwise.
        let reliable = zip(windows, quality).filter { $0.1 == .reliable }
            .map { (window: $0.0, value: $0.0.value!) }
        let values = reliable.map(\.value)

        let events = reliable.filter { $0.value < threshold }.map { v in
            // A reliable window has at least one in-band second, so `first`/`last` exist.
            Spo2DesatEvent(start: v.window.inBand.first!.ts, end: v.window.inBand.last!.ts,
                           nadir: v.value, samples: v.window.inBand.count)
        }

        return Spo2CandidateNight(mean: values.isEmpty ? nil : Double(values.reduce(0, +)) / Double(values.count),
                                  minimum: values.min(), maximum: values.max(),
                                  samples: reliable.reduce(0) { $0 + $1.window.inBand.count },
                                  windows: reliable.count, windowsAttempted: windows.count,
                                  windowsLowCoverage: quality.filter { $0 == .lowCoverage }.count,
                                  windowsUnsettled: quality.filter { $0 == .unsettled }.count,
                                  threshold: threshold, events: events)
    }

    /// The in-band seconds of the night's RELIABLE readings, ascending by timestamp: what a chart of the
    /// night may plot beside the figures `nightlySpo2CandidateNight` states. Given the same sessions and
    /// samples it is cut by the same windows and the same verdict, so the chart cannot draw a low the
    /// figures left out (W03-007). A caller that passes different sessions (a chart of one session where
    /// the figures cover the day's) can see a reading straddling the session edge cut, and judged,
    /// differently.
    public static func spo2CandidateReliableSeconds(
        _ sessions: [SleepSession],
        aux: [V18AuxSample]
    ) -> [(ts: Int, value: Int)] {
        spo2CandidateWindows(sessions, aux: aux).filter { $0.quality() == .reliable }.flatMap(\.inBand)
    }
}

// MARK: - The stored series (#103)

/// The metricSeries keys one night's candidate result is stored under, and the funnel that reads them
/// back as one night.
///
/// WHY THE KEYS ARE CONSTANTS. `V18AuxSlot.decoderKey` exists because a key spelled once in the writer
/// and again in the reader can drift apart while each side still looks right — and neither the compiler
/// (the lookup is optional) nor a runtime check (absence is a legal state) says a word. These keys are
/// read exactly that way, so they are spelled ONCE here and used by both ends.
///
/// `meanKey` predates this and already has readers spelling it literally; its value is unchanged, so the
/// constant and those literals cannot disagree about what is stored.
///
/// PER-WINDOW SINCE W03-003. The mean, minimum, dips and dip span are resolved per measurement window on
/// every night that also carries `windowsKey`; a night without it was scored per second. The window keys
/// are therefore also the marker that tells a reader which of the two a stored night used.
///
/// QUALITY-GATED SINCE W03-007. A night that also carries `lowQualityKey` was resolved over reliable
/// readings only, and may legitimately have NO mean: the strap attempted readings and none passed. Such a
/// night is still a night (its counts say so), and it is the newest night a surface must show, not skip.
public enum Spo2CandidateSeries {
    /// The night's UNROUNDED mean of its reliable readings' values. Every display rounds it at the edge.
    /// Absent on a quality-gated night with no reliable reading.
    public static let meanKey = "spo2_candidate"
    /// The lowest reliable reading value of the night. Absent exactly when the mean is.
    public static let minimumKey = "spo2_candidate_min"
    /// How many below-threshold READINGS (windows) the night held. 0 is written, not omitted.
    public static let dipsKey = "spo2_candidate_dips"
    /// Summed observed span of those readings, in seconds (`Spo2CandidateNight.dipSpanSeconds`): how long
    /// the dip readings were measured, not how long the value stayed below the threshold. Legitimately 0
    /// when every dip reading held one in-band second.
    public static let dipSecondsKey = "spo2_candidate_dip_seconds"
    /// In-band SECONDS inside the night's reliable readings.
    public static let samplesKey = "spo2_candidate_samples"
    /// Reliable readings: the measurements the night's figures rest on (W03-003). Before W03-007 this
    /// counted every reading with an in-band value; a night carrying `lowQualityKey` counts reliable ones.
    public static let windowsKey = "spo2_candidate_windows"
    /// Every window the strap measured in, failed ones included.
    public static let windowsAttemptedKey = "spo2_candidate_windows_attempted"
    /// Readings that had a value and were left out as low quality (W03-007). 0 is written, not omitted:
    /// its presence is the marker that the night was quality-gated.
    public static let lowQualityKey = "spo2_candidate_windows_low_quality"

    /// One night as the series carry it. The companions are optional INDEPENDENTLY of the mean: a night
    /// scored before those keys shipped has a mean and nothing else, and a surface must be able to show
    /// the mean it does have rather than blanking the whole card.
    public struct Night: Equatable, Sendable {
        public let day: String
        /// nil only on a quality-gated night with no reliable reading (`hasNoReliableReading`).
        public let mean: Double?
        public let minimum: Int?
        public let dips: Int?
        public let dipSeconds: Int?
        public let samples: Int?
        /// nil on a night scored before the window keys shipped. Such a night's `minimum` and `dips` were
        /// resolved per second, so a surface that has no window count must not present them as per window.
        public let windows: Int?
        public let windowsAttempted: Int?
        /// Readings left out as low quality. nil on a night scored before W03-007, which was not gated.
        public let windowsLowQuality: Int?

        public init(day: String, mean: Double?, minimum: Int?, dips: Int?,
                    dipSeconds: Int?, samples: Int?, windows: Int? = nil, windowsAttempted: Int? = nil,
                    windowsLowQuality: Int? = nil) {
            self.day = day; self.mean = mean; self.minimum = minimum
            self.dips = dips; self.dipSeconds = dipSeconds; self.samples = samples
            self.windows = windows; self.windowsAttempted = windowsAttempted
            self.windowsLowQuality = windowsLowQuality
        }

        /// The displayed mean — the same rounding `Spo2CandidateNight.meanRounded` applies, so the card
        /// and the vital tile round one stored number the same way instead of two.
        public var meanRounded: Int? { mean.map { Int($0.rounded()) } }

        /// True for a quality-gated night on which the strap attempted readings and none was reliable:
        /// the night to say "no reliable reading" about, rather than show a number for.
        public var hasNoReliableReading: Bool { mean == nil }

        /// What the reading count ("12 of 26") can honestly be captioned with. A reading the check left
        /// out and a reading of codes only are different facts: "passed the quality check" is true only
        /// when every attempted reading was reliable, and "left out as low quality" counts only readings
        /// that had a value to leave out (W03-007).
        public enum ReadingsNote: Equatable, Sendable {
            /// Scored before W03-007: the count is every reading with a value.
            case ungated
            /// This many readings with a value failed the check.
            case leftOut(Int)
            /// None failed the check, but some readings were codes only: the count is every reading
            /// with a value.
            case someWithoutValue
            /// Every attempted reading was reliable.
            case allPassed
        }

        /// Why a night has no reliable reading, when it has none (W03-010). The two causes are different
        /// facts and a surface must not blame one on the other: readings that had values and failed the
        /// quality check, against readings that were the strap's codes only and never had a value to check.
        public enum NoReliableReadingReason: Equatable, Sendable {
            /// At least one reading had in-band values and was left out as low quality.
            case lowQuality
            /// Every reading was codes only.
            case noValue
        }

        /// nil when the night has a reliable reading.
        public var noReliableReadingReason: NoReliableReadingReason? {
            guard hasNoReliableReading else { return nil }
            return (windowsLowQuality ?? 0) > 0 ? .lowQuality : .noValue
        }

        public var readingsNote: ReadingsNote {
            guard let left = windowsLowQuality else { return .ungated }
            if left > 0 { return .leftOut(left) }
            if let w = windows, let a = windowsAttempted, w < a { return .someWithoutValue }
            return .allPassed
        }

        /// True when the night is known to have dipped. nil `dips` is UNKNOWN, not zero: a pre-keys night
        /// must not be captioned "no dips" on the strength of a row that was never written.
        public var dipped: Bool? { dips.map { $0 > 0 } }
    }

    /// THE funnel every candidate-stats surface resolves a night through.
    ///
    /// A night exists when it has a mean, or when it is a quality-gated night with no reliable reading:
    /// `lowQualityKey` and `windowsAttemptedKey` present, and `windowsKey` 0 (W03-007). Any other night
    /// present only in a companion series is a half-written night and is skipped rather than shown with a
    /// blank headline. On a gated night with no reliable reading a mean row is IGNORED even if present:
    /// the writer deletes it, and a delete that failed, or a mean left under another computed id the
    /// reader unions, must not bring back an average the resolver refused to state. `latest` picks the
    /// highest day key present, which is a plain lexicographic max because the keys are `YYYY-MM-DD`.
    ///
    /// Passing the dictionaries in (rather than each surface reading its own) is the point: the mean, the
    /// minimum and the dip count on one card must describe ONE night, and a surface that resolved each
    /// key by itself could pair last night's mean with the previous night's minimum the moment one series
    /// lagged a scoring pass behind the other.
    public static func latest(mean: [String: Double],
                              minimum: [String: Double] = [:],
                              dips: [String: Double] = [:],
                              dipSeconds: [String: Double] = [:],
                              samples: [String: Double] = [:],
                              windows: [String: Double] = [:],
                              windowsAttempted: [String: Double] = [:],
                              lowQuality: [String: Double] = [:]) -> Night? {
        Read(mean: mean, minimum: minimum, dips: dips, dipSeconds: dipSeconds, samples: samples,
             windows: windows, windowsAttempted: windowsAttempted, lowQuality: lowQuality).latest
    }

    /// Every candidate series as one value, loaded once by a surface and resolved through the rules above
    /// (W03-011, W03-018). Each surface used to load the keys it cared about and resolve the night its own
    /// way, and the ones that read only the mean kept showing an older night's average beside a card that
    /// said the newest night had no reliable reading. A surface now holds one `Read` and asks it for the
    /// night (`latest`, `night(on:)`) or for the means (`meanByDay`).
    public struct Read: Equatable, Sendable {
        public var mean: [String: Double]
        public var minimum: [String: Double]
        public var dips: [String: Double]
        public var dipSeconds: [String: Double]
        public var samples: [String: Double]
        public var windows: [String: Double]
        public var windowsAttempted: [String: Double]
        public var lowQuality: [String: Double]

        /// Every key a `Read` is built from, for the loader. Spelled from the constants above.
        public static let keys = [meanKey, minimumKey, dipsKey, dipSecondsKey, samplesKey, windowsKey,
                                  windowsAttemptedKey, lowQualityKey]

        public init(mean: [String: Double] = [:], minimum: [String: Double] = [:],
                    dips: [String: Double] = [:], dipSeconds: [String: Double] = [:],
                    samples: [String: Double] = [:], windows: [String: Double] = [:],
                    windowsAttempted: [String: Double] = [:], lowQuality: [String: Double] = [:]) {
            self.mean = mean; self.minimum = minimum; self.dips = dips; self.dipSeconds = dipSeconds
            self.samples = samples; self.windows = windows; self.windowsAttempted = windowsAttempted
            self.lowQuality = lowQuality
        }

        /// Built from a loader's `key → (day → value)` map, keyed by `keys`.
        public init(byKey: [String: [String: Double]]) {
            self.init(mean: byKey[meanKey] ?? [:], minimum: byKey[minimumKey] ?? [:],
                      dips: byKey[dipsKey] ?? [:], dipSeconds: byKey[dipSecondsKey] ?? [:],
                      samples: byKey[samplesKey] ?? [:], windows: byKey[windowsKey] ?? [:],
                      windowsAttempted: byKey[windowsAttemptedKey] ?? [:],
                      lowQuality: byKey[lowQualityKey] ?? [:])
        }

        /// A quality-gated night on which nothing was reliable.
        private func noReliableReading(_ day: String) -> Bool {
            lowQuality[day] != nil && windowsAttempted[day] != nil
                && windows[day].map { $0.rounded() == 0 } == true
        }

        /// The days that are nights at all (see `latest(mean:…)`).
        private var nightDays: Set<String> {
            Set(mean.keys).union(lowQuality.keys.filter(noReliableReading))
        }

        /// The newest night.
        public var latest: Night? { nightDays.max().flatMap(night(on:)) }

        /// The night of `day`, or nil when `day` is not a night.
        public func night(on day: String) -> Night? {
            guard nightDays.contains(day) else { return nil }
            func int(_ d: [String: Double]) -> Int? { d[day].map { Int($0.rounded()) } }
            let empty = noReliableReading(day)
            return Night(day: day, mean: empty ? nil : mean[day], minimum: empty ? nil : int(minimum),
                         dips: int(dips), dipSeconds: int(dipSeconds), samples: int(samples),
                         windows: int(windows), windowsAttempted: int(windowsAttempted),
                         windowsLowQuality: int(lowQuality))
        }

        /// Nightly means by day, with the mean of any night that has no reliable reading left out: what a
        /// trend, a sparkline or a per-day fallback may plot.
        public var meanByDay: [String: Double] { mean.filter { !noReliableReading($0.key) } }
    }
}
