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

/// One `@82` measurement window: a run of nonzero seconds, no two further apart than
/// `AnalyticsEngine.spo2CandidateWindowGapSeconds` and spanning less than
/// `AnalyticsEngine.spo2CandidateWindowMaxSpanSeconds`.
///
/// A nonzero byte means the strap was measuring that second. On one MG this is exact: the byte is nonzero
/// in precisely the seconds its optical status words at `@77`/`@79` leave their idle values, with no
/// exception either way over 588,883 records. A window can therefore hold only failure codes (sub-70 or
/// bit-7 values) and no in-band reading at all; it still counts as ATTEMPTED.
struct Spo2CandidateWindow {
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
public struct Spo2CandidateNight: Equatable, Sendable {
    /// Unrounded mean of the window values. Stored unrounded so a sub-1 % night-to-night move survives to
    /// the series; every display rounds it at the edge.
    public let mean: Double
    /// The lowest and highest window values.
    public let minimum: Int
    public let maximum: Int
    /// In-band SECONDS the night's windows hold. Kept for the stored series, whose meaning it has always
    /// had; the evidence a night rests on is `windows`, because the seconds inside one window are one
    /// rolling measurement, not independent readings.
    public let samples: Int
    /// Windows with at least one in-band second: the measurements the figures rest on.
    public let windows: Int
    /// Every window the strap measured in, including those that reported only failure codes.
    public let windowsAttempted: Int
    /// The threshold `events` were cut at, carried so a surface can name it instead of assuming one.
    public let threshold: Int
    /// Below-threshold windows, ascending by `start`.
    public let events: [Spo2DesatEvent]

    public init(mean: Double, minimum: Int, maximum: Int, samples: Int, windows: Int,
                windowsAttempted: Int, threshold: Int, events: [Spo2DesatEvent]) {
        self.mean = mean; self.minimum = minimum; self.maximum = maximum
        self.samples = samples; self.windows = windows; self.windowsAttempted = windowsAttempted
        self.threshold = threshold; self.events = events
    }

    /// The shipped display value — round-half-away-from-zero, matching what `nightlySpo2CandidateMean`
    /// has always returned. Every in-band value is positive, so no platform-divergence risk.
    public var meanRounded: Int { Int(mean.rounded()) }

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

    /// THE resolver for a night's `@82` candidate readings — mean, range, below-threshold windows and the
    /// window counts — over the detected in-bed `sessions`. nil when no in-band reading fell inside any
    /// span, which is the same "no answer" `nightlySpo2CandidateMean` has always returned.
    ///
    /// Session-bounded inclusively on both ends (unchanged from the mean this replaces). A window is a run
    /// of NONZERO seconds, codes included, so a window of failure codes still counts as attempted; only
    /// `spo2CandidateInBand` seconds contribute a value. It reads `aux` in TIMESTAMP ORDER rather than
    /// arrival order: windows depend on adjacency, and `v18AuxSamples` ordering is a property of that
    /// query, not of this input.
    ///
    /// DIAGNOSTIC ONLY. Nothing scores this and it never writes `spo2Pct`.
    public static func nightlySpo2CandidateNight(
        _ sessions: [SleepSession],
        aux: [V18AuxSample],
        threshold: Int = AnalyticsEngine.spo2CandidateDipThreshold,
        windowGapSeconds: Int = AnalyticsEngine.spo2CandidateWindowGapSeconds
    ) -> Spo2CandidateNight? {
        guard !sessions.isEmpty, !aux.isEmpty else { return nil }
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
            if spo2CandidateInBand.contains(m.value) {
                windows[windows.count - 1].inBand.append(m)
            }
        }

        let valued = windows.compactMap { w in w.value.map { (window: w, value: $0) } }
        guard !valued.isEmpty else { return nil }
        let values = valued.map(\.value)

        let events = valued.filter { $0.value < threshold }.map { v in
            // A valued window has at least one in-band second, so `first`/`last` exist.
            Spo2DesatEvent(start: v.window.inBand.first!.ts, end: v.window.inBand.last!.ts,
                           nadir: v.value, samples: v.window.inBand.count)
        }

        // `min`/`max` are safe to force: `valued` is non-empty by the guard above.
        return Spo2CandidateNight(mean: Double(values.reduce(0, +)) / Double(values.count),
                                  minimum: values.min()!, maximum: values.max()!,
                                  samples: valued.reduce(0) { $0 + $1.window.inBand.count },
                                  windows: valued.count, windowsAttempted: windows.count,
                                  threshold: threshold, events: events)
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
public enum Spo2CandidateSeries {
    /// The night's UNROUNDED mean of its window values. Every display rounds it at the edge.
    public static let meanKey = "spo2_candidate"
    /// The lowest window value of the night.
    public static let minimumKey = "spo2_candidate_min"
    /// How many below-threshold READINGS (windows) the night held. 0 is written, not omitted.
    public static let dipsKey = "spo2_candidate_dips"
    /// Summed observed span of those readings, in seconds (`Spo2CandidateNight.dipSpanSeconds`): how long
    /// the dip readings were measured, not how long the value stayed below the threshold. Legitimately 0
    /// when every dip reading held one in-band second.
    public static let dipSecondsKey = "spo2_candidate_dip_seconds"
    /// In-band SECONDS inside the night's windows.
    public static let samplesKey = "spo2_candidate_samples"
    /// Windows with an in-band value: the measurements the night's figures rest on (W03-003).
    public static let windowsKey = "spo2_candidate_windows"
    /// Every window the strap measured in, failed ones included.
    public static let windowsAttemptedKey = "spo2_candidate_windows_attempted"

    /// One night as the series carry it. The companions are optional INDEPENDENTLY of the mean: a night
    /// scored before those keys shipped has a mean and nothing else, and a surface must be able to show
    /// the mean it does have rather than blanking the whole card.
    public struct Night: Equatable, Sendable {
        public let day: String
        public let mean: Double
        public let minimum: Int?
        public let dips: Int?
        public let dipSeconds: Int?
        public let samples: Int?
        /// nil on a night scored before the window keys shipped. Such a night's `minimum` and `dips` were
        /// resolved per second, so a surface that has no window count must not present them as per window.
        public let windows: Int?
        public let windowsAttempted: Int?

        public init(day: String, mean: Double, minimum: Int?, dips: Int?,
                    dipSeconds: Int?, samples: Int?, windows: Int? = nil, windowsAttempted: Int? = nil) {
            self.day = day; self.mean = mean; self.minimum = minimum
            self.dips = dips; self.dipSeconds = dipSeconds; self.samples = samples
            self.windows = windows; self.windowsAttempted = windowsAttempted
        }

        /// The displayed mean — the same rounding `Spo2CandidateNight.meanRounded` applies, so the card
        /// and the vital tile round one stored number the same way instead of two.
        public var meanRounded: Int { Int(mean.rounded()) }

        /// True when the night is known to have dipped. nil `dips` is UNKNOWN, not zero: a pre-keys night
        /// must not be captioned "no dips" on the strength of a row that was never written.
        public var dipped: Bool? { dips.map { $0 > 0 } }
    }

    /// THE funnel every candidate-stats surface resolves a night through.
    ///
    /// The mean decides which night exists at all — it is the one key that has always been written, so a
    /// night present in any companion series but not in the mean is a half-written night and is skipped
    /// rather than shown with a blank headline. `latest` picks the highest day key present, which is a
    /// plain lexicographic max because the keys are `YYYY-MM-DD`.
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
                              windowsAttempted: [String: Double] = [:]) -> Night? {
        guard let day = mean.keys.max(), let m = mean[day] else { return nil }
        func int(_ d: [String: Double]) -> Int? { d[day].map { Int($0.rounded()) } }
        return Night(day: day, mean: m, minimum: int(minimum), dips: int(dips),
                     dipSeconds: int(dipSeconds), samples: int(samples),
                     windows: int(windows), windowsAttempted: int(windowsAttempted))
    }
}
