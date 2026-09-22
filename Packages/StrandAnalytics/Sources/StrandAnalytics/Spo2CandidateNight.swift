import Foundation
import WhoopProtocol

// MARK: - Nightly SpO2 candidate statistics (#103/#112)

/// One run of consecutive below-threshold in-band `@82` readings inside a night.
///
/// `spanSeconds` is measured between the FIRST and LAST reading in the run, not multiplied out of the
/// sample count. The R18 stream is documented as "roughly one packet per second"
/// (`docs/PROTOCOL_SENSORS.md`), which is not a cadence guarantee — so a run of one reading has a span of
/// zero seconds, because one reading is all that was observed. Turning `samples` into seconds would state
/// a duration nothing measured.
public struct Spo2DesatEvent: Equatable, Sendable {
    /// Unix seconds of the first below-threshold reading in the run.
    public let start: Int
    /// Unix seconds of the last below-threshold reading in the run.
    public let end: Int
    /// The lowest in-band reading in the run.
    public let nadir: Int
    /// How many readings the run rests on.
    public let samples: Int

    public init(start: Int, end: Int, nadir: Int, samples: Int) {
        self.start = start; self.end = end; self.nadir = nadir; self.samples = samples
    }

    /// Observed span, first reading to last. Zero for a single-reading run — see the type's note.
    public var spanSeconds: Int { max(0, end - start) }
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
public struct Spo2CandidateNight: Equatable, Sendable {
    /// Unrounded mean of the in-band readings. Stored unrounded so a sub-1 % night-to-night move survives
    /// to the series; every display rounds it at the edge.
    public let mean: Double
    public let minimum: Int
    public let maximum: Int
    /// In-band readings the whole night rests on. A mean over 11 readings and a mean over 1100 are not the
    /// same evidence, so this travels with it everywhere.
    public let samples: Int
    /// The threshold `events` were cut at, carried so a surface can name it instead of assuming one.
    public let threshold: Int
    /// Below-threshold runs, ascending by `start`.
    public let events: [Spo2DesatEvent]

    public init(mean: Double, minimum: Int, maximum: Int, samples: Int,
                threshold: Int, events: [Spo2DesatEvent]) {
        self.mean = mean; self.minimum = minimum; self.maximum = maximum
        self.samples = samples; self.threshold = threshold; self.events = events
    }

    /// The shipped display value — round-half-away-from-zero, matching what `nightlySpo2CandidateMean`
    /// has always returned. Every in-band value is positive, so no platform-divergence risk.
    public var meanRounded: Int { Int(mean.rounded()) }

    /// Readings below `threshold`. Derived from `events`, so it cannot disagree with them.
    public var samplesBelowThreshold: Int { events.reduce(0) { $0 + $1.samples } }

    /// Summed observed span of the below-threshold runs. See `Spo2DesatEvent.spanSeconds`: this is time
    /// BETWEEN readings, so it under-reports rather than inventing a cadence, and it is zero for a night
    /// whose only dips were single readings.
    public var secondsBelowThreshold: Int { events.reduce(0) { $0 + $1.spanSeconds } }

    /// The deepest reading of the night's dips, or nil when nothing went below the threshold. This is
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
    /// flagged run a clinical desaturation event. Carried on the result (`Spo2CandidateNight.threshold`)
    /// so a surface names the number it was cut at rather than assuming this one.
    public static let spo2CandidateDipThreshold = 90

    /// Below-threshold readings further apart than this start a NEW event. The stream is roughly 1 Hz but
    /// gaps are ordinary (off-wrist, a window not yet offloaded), and bridging one would report a single
    /// dip spanning a gap nothing was measured across.
    public static let spo2CandidateEventGapSeconds = 30

    /// THE resolver for a night's `@82` candidate readings — mean, range, and below-threshold runs — over
    /// the detected in-bed `sessions`. nil when no in-band reading fell inside any span, which is the same
    /// "no answer" `nightlySpo2CandidateMean` has always returned.
    ///
    /// Gated to `spo2CandidateInBand`, session-bounded inclusively on both ends (unchanged from the mean
    /// this replaces), and it reads `aux` in TIMESTAMP ORDER rather than arrival order: the event runs
    /// depend on adjacency, and `v18AuxSamples` ordering is a property of that query, not of this input.
    ///
    /// DIAGNOSTIC ONLY. Nothing scores this and it never writes `spo2Pct`.
    public static func nightlySpo2CandidateNight(
        _ sessions: [SleepSession],
        aux: [V18AuxSample],
        threshold: Int = AnalyticsEngine.spo2CandidateDipThreshold,
        eventGapSeconds: Int = AnalyticsEngine.spo2CandidateEventGapSeconds
    ) -> Spo2CandidateNight? {
        guard !sessions.isEmpty, !aux.isEmpty else { return nil }
        var inBand: [(ts: Int, value: Int)] = []
        for a in aux {
            guard let v = a.auxByte82, spo2CandidateInBand.contains(v) else { continue }
            guard sessions.contains(where: { $0.start <= a.ts && a.ts <= $0.end }) else { continue }
            inBand.append((ts: a.ts, value: v))
        }
        guard !inBand.isEmpty else { return nil }
        inBand.sort { $0.ts < $1.ts }

        let sum = inBand.reduce(0) { $0 + $1.value }
        // `minimum`/`maximum` are safe to force: `inBand` is non-empty by the guard above.
        let minimum = inBand.map(\.value).min()!
        let maximum = inBand.map(\.value).max()!

        var events: [Spo2DesatEvent] = []
        var runStart: Int?, runEnd = 0, runNadir = 0, runSamples = 0
        func closeRun() {
            guard let s = runStart else { return }
            events.append(Spo2DesatEvent(start: s, end: runEnd, nadir: runNadir, samples: runSamples))
            runStart = nil
        }
        for r in inBand {
            guard r.value < threshold else { closeRun(); continue }
            if let _ = runStart, r.ts - runEnd <= max(0, eventGapSeconds) {
                runEnd = r.ts; runNadir = min(runNadir, r.value); runSamples += 1
            } else {
                // A gap wider than the budget ends the previous run and opens a new one.
                closeRun()
                runStart = r.ts; runEnd = r.ts; runNadir = r.value; runSamples = 1
            }
        }
        closeRun()

        return Spo2CandidateNight(mean: Double(sum) / Double(inBand.count),
                                  minimum: minimum, maximum: maximum, samples: inBand.count,
                                  threshold: threshold, events: events)
    }
}

// MARK: - The stored series (#103)

/// The metricSeries keys one night's candidate result is stored under, and the funnel that reads them
/// back as one night.
///
/// WHY THE KEYS ARE CONSTANTS. `V18AuxSlot.decoderKey` exists because a key spelled once in the writer
/// and again in the reader can drift apart while each side still looks right — and neither the compiler
/// (the lookup is optional) nor a runtime check (absence is a legal state) says a word. These four keys
/// are read exactly that way, so they are spelled ONCE here and used by both ends.
///
/// `meanKey` predates this and already has readers spelling it literally; its value is unchanged, so the
/// constant and those literals cannot disagree about what is stored.
public enum Spo2CandidateSeries {
    /// The night's UNROUNDED mean. Every display rounds it at the edge.
    public static let meanKey = "spo2_candidate"
    /// The lowest in-band reading of the night.
    public static let minimumKey = "spo2_candidate_min"
    /// How many below-threshold RUNS the night held. 0 is written, not omitted.
    public static let dipsKey = "spo2_candidate_dips"
    /// Summed observed span of those runs, in seconds. Legitimately 0 when every dip was one reading —
    /// see `Spo2DesatEvent.spanSeconds`.
    public static let dipSecondsKey = "spo2_candidate_dip_seconds"
    /// In-band readings the night's figures rest on.
    public static let samplesKey = "spo2_candidate_samples"

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

        public init(day: String, mean: Double, minimum: Int?, dips: Int?,
                    dipSeconds: Int?, samples: Int?) {
            self.day = day; self.mean = mean; self.minimum = minimum
            self.dips = dips; self.dipSeconds = dipSeconds; self.samples = samples
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
                              samples: [String: Double] = [:]) -> Night? {
        guard let day = mean.keys.max(), let m = mean[day] else { return nil }
        func int(_ d: [String: Double]) -> Int? { d[day].map { Int($0.rounded()) } }
        return Night(day: day, mean: m, minimum: int(minimum), dips: int(dips),
                     dipSeconds: int(dipSeconds), samples: int(samples))
    }
}
