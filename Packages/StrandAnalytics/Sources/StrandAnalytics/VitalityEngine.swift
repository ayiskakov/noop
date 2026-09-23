import Foundation

// VitalityEngine.swift — Body Age in years, plus a 0–100 "Vitality" wellness score derived from it.
//
// INDEPENDENT implementation of the method WHOOP publishes for its Healthspan feature (WHOOP Age; see
// "The WHOOP Healthspan Feature" white paper, rev. 2025-09-04). NOT medical advice: a wellness comparison,
// never a clinical biological age. Each wearable-measurable driver is mapped to a published all-cause-
// mortality hazard ratio, the log-hazards are summed with an overlap correction, and the combined hazard
// is turned into years with the effective-age transform of Spiegelhalter (BMC Med Inform Decis Mak 2016;
// 16:104): 10 · ln(HR) years, i.e. mortality risk roughly e-folds every ten years of age.
//
// ── THE REFERENT: MEETING HEALTH TARGETS ────────────────────────────────────────────────────────────
//
// Every driver contributes exactly zero when it sits on its HEALTH TARGET (WHOOP's anchor), not when it
// sits on the population average. Body Age = age + Σ years, so a person meeting every target reads at
// their own age, and an average adult reads several years older (the white paper's Table 2 puts an
// average 30-year-old man near +6 and woman near +7.5). The targets are listed per driver below, and each
// curve carries its citation in its doc comment.
//
// HRV is deliberately NOT a driver. It is not in WHOOP's nine, its mortality association does not survive
// Mendelian randomisation (UK Biobank, Commun Biol 2023, PMID 37803156) and it is U-shaped in older
// adults (Jarczok, Neurosci Biobehav Rev 2022). A screen may show it as context; it never moves Body Age.
//
// ── DOMAIN GROUPING (why the log-hazards are not simply added up) ──────────────────────────────────
//
// The drivers are not independent measurements: steps, zone 1–3 minutes, zone 4–5 minutes and strength
// minutes are four views of ONE latent construct (how much you move), just as VO₂max and resting heart
// rate are two views of cardiorespiratory fitness. So each factor is assigned a DOMAIN, and a domain's
// terms are summed then divided by √n (n equally-correlated measures of one construct carry about √n
// measurements' worth of independent information, not n). The cross-domain `overlapShrink` then applies.
//
// A strap-derived VO₂max is a stronger case still: it is computed largely FROM resting heart rate, so the
// two are one measurement read twice. When both are present and the VO₂max is strap-derived, the fitness
// domain is divided by n rather than √n — the two fold into their mean, one term. An EXTERNAL VO₂max (a
// lab test, an Apple Watch or treadmill estimate) is an independent reading and keeps the √n rule.
public enum VitalityEngine {

    /// Effective-age transform: 10 · ln(HR) years (Spiegelhalter 2016), so ln(hazard) per year is 0.1.
    /// `PaceOfAgingEngine` reads the same constant, so the two cannot rescale differently.
    public static let lnHazardPerYear = 0.1
    /// Correlated DOMAINS (fitness, activity and sleep all move together) → shrink the summed per-domain
    /// log-hazards so the same underlying signal is not multiplied several times. Within-domain
    /// correlation is handled separately by the √n rule (see the header).
    ///
    /// This is the one calibrated constant. WHOOP corrects overlap with structural-equation factors it
    /// does not publish; its Table 2 does publish the outcome — an average 30-year-old man reads about
    /// +6 years and a woman about +7.5. 0.9 reproduces both for the `average-us-30-male` /
    /// `average-us-30-female` oracle people (+5.9 / +7.4), where 0.75 read +4.9 / +6.2.
    static let overlapShrink = 0.9
    /// Body Age is clamped to a sane band; Vitality maps Δage linearly around 50 (= "meeting targets").
    static let minBodyAge = 15.0, maxBodyAge = 100.0
    static let vitalityPerYear = 2.5   // each year younger than your age = +2.5 Vitality points

    /// Which latent construct a factor measures. Factors sharing a domain are shrunk against each other
    /// before the cross-domain shrink, because they are largely the same signal read twice.
    public enum Domain: String, Equatable, Sendable, CaseIterable {
        case fitness      // VO₂max, resting heart rate
        case activity     // steps, zone 1–3 minutes, zone 4–5 minutes, strength minutes
        case sleep        // duration, regularity
        case body         // lean-mass percentage
    }

    /// Where a VO₂max reading came from — decides whether it folds into resting HR (see the header).
    public enum VO2maxSource: String, Equatable, Sendable {
        /// Estimated from the strap's own heart-rate data, so largely a function of resting HR.
        case strap
        /// Measured or estimated independently of the strap (a lab test, an imported watch estimate).
        case external
    }

    /// The wearable inputs Body Age reads. All optional — the score uses whatever is present
    /// (≥ `minFactors`).
    public struct Inputs: Equatable, Sendable {
        public var chronoAge: Double
        /// "male" | "female" | anything else — picks the sex-specific targets (anything else → male).
        public var sex: String?
        /// Sleeping resting heart rate, bpm.
        public var restingHR: Double?
        /// ml/kg/min.
        public var vo2max: Double?
        public var vo2maxSource: VO2maxSource
        /// Mean nightly sleep, hours.
        public var sleepHours: Double?
        /// Sleep Regularity Index, −100…100 (100 = identical timing every day). See `SleepRegularity`.
        public var sleepRegularity: Double?
        /// Mean daily steps.
        public var steps: Double?
        /// Weekly minutes in heart-rate-reserve zones 1–3 (50–80 % HRR).
        public var moderateMinPerWeek: Double?
        /// Weekly minutes in heart-rate-reserve zones 4–5 (≥ 80 % HRR).
        public var vigorousMinPerWeek: Double?
        /// Weekly minutes of muscle-strengthening activity.
        public var strengthMinPerWeek: Double?
        /// Whole-body lean (fat-free) mass, kg — with `weightKg` this forms the lean-mass percentage.
        public var leanMassKg: Double?
        public var weightKg: Double?

        public init(chronoAge: Double, sex: String? = nil, restingHR: Double? = nil,
                    vo2max: Double? = nil, vo2maxSource: VO2maxSource = .strap,
                    sleepHours: Double? = nil, sleepRegularity: Double? = nil, steps: Double? = nil,
                    moderateMinPerWeek: Double? = nil, vigorousMinPerWeek: Double? = nil,
                    strengthMinPerWeek: Double? = nil, leanMassKg: Double? = nil,
                    weightKg: Double? = nil) {
            self.chronoAge = chronoAge; self.sex = sex; self.restingHR = restingHR
            self.vo2max = vo2max; self.vo2maxSource = vo2maxSource
            self.sleepHours = sleepHours; self.sleepRegularity = sleepRegularity; self.steps = steps
            self.moderateMinPerWeek = moderateMinPerWeek; self.vigorousMinPerWeek = vigorousMinPerWeek
            self.strengthMinPerWeek = strengthMinPerWeek; self.leanMassKg = leanMassKg
            self.weightKg = weightKg
        }

        /// The same inputs with every driver whose contribution key is NOT in `keys` removed. Used to
        /// compare two windows over the SAME factor set (see `PaceOfAgingEngine.project`).
        public func restricted(to keys: Set<String>) -> Inputs {
            var i = self
            if !keys.contains("rhr") { i.restingHR = nil }
            if !keys.contains("vo2max") { i.vo2max = nil }
            if !keys.contains("sleep") { i.sleepHours = nil }
            if !keys.contains("consistency") { i.sleepRegularity = nil }
            if !keys.contains("steps") { i.steps = nil }
            if !keys.contains("moderate") { i.moderateMinPerWeek = nil }
            if !keys.contains("vigorous") { i.vigorousMinPerWeek = nil }
            if !keys.contains("strength") { i.strengthMinPerWeek = nil }
            if !keys.contains("leanmass") { i.leanMassKg = nil }
            return i
        }
    }

    /// One factor's contribution: what it measured, what the target is, and its signed log-hazard vs
    /// that target (positive = ages you, negative = protective).
    public struct Contribution: Equatable, Sendable {
        public let key: String
        public let label: String
        public let domain: Domain
        /// Log-hazard vs this factor's target, BEFORE any domain or cross-domain shrink.
        public let lnHazard: Double
        /// The measured value this factor was scored from, in `unit`.
        public let value: Double
        /// The health target that contributes exactly zero, in `unit`.
        public let target: Double
        public let unit: String
        /// This factor's SHARE of the Body Age offset, in years (positive = adds to Body Age). Nil in the
        /// raw list `contributions(_:)` returns, and filled in by `compute` — only there is the domain
        /// shrink known. The filled shares sum to the UNCLAMPED Δage exactly, so a breakdown built from
        /// `Result.contributions` always reconciles with the headline it explains.
        public let deltaYears: Double?

        public init(key: String, label: String, domain: Domain, lnHazard: Double,
                    value: Double, target: Double, unit: String, deltaYears: Double? = nil) {
            self.key = key; self.label = label; self.domain = domain; self.lnHazard = lnHazard
            self.value = value; self.target = target; self.unit = unit; self.deltaYears = deltaYears
        }

        /// The same contribution with its Body Age share filled in.
        func withDeltaYears(_ years: Double) -> Contribution {
            Contribution(key: key, label: label, domain: domain, lnHazard: lnHazard,
                         value: value, target: target, unit: unit, deltaYears: years)
        }
    }

    public struct Result: Equatable, Sendable {
        public let vitality: Double        // 0–100 (50 = meeting every target)
        public let bodyAge: Double         // years, clamped
        public let chronoAge: Double
        public let deltaYears: Double      // chronoAge − bodyAge (positive = younger than your age)
        public let bandYears: Double
        /// The per-factor breakdown WITH `deltaYears` filled — the single funnel a UI breakdown must read,
        /// so the rows and the headline can never disagree.
        public let contributions: [Contribution]
        public let factorsUsed: Int
        /// The summed, fully-shrunk log-hazard the Body Age was derived from (unclamped).
        public let lnHazardSum: Double
        /// True when a factor whose evidence chain is weaker than the rest was used (currently only lean
        /// mass — see `leanMassLnHazard`). A UI should soften its claim accordingly.
        public let lowerConfidence: Bool
        /// The driver whose target would take the most years off, when any driver is costing at least
        /// `minLeverYears`. Reaching its target removes exactly its `deltaYears` (the shrink is linear).
        public let biggestLever: Contribution?

        public init(vitality: Double, bodyAge: Double, chronoAge: Double, deltaYears: Double,
                    bandYears: Double, contributions: [Contribution], factorsUsed: Int,
                    lnHazardSum: Double = 0, lowerConfidence: Bool = false,
                    biggestLever: Contribution? = nil) {
            self.vitality = vitality; self.bodyAge = bodyAge; self.chronoAge = chronoAge
            self.deltaYears = deltaYears; self.bandYears = bandYears
            self.contributions = contributions; self.factorsUsed = factorsUsed
            self.lnHazardSum = lnHazardSum; self.lowerConfidence = lowerConfidence
            self.biggestLever = biggestLever
        }

        /// Body Age before the clamp: age + Σ shares. The quantity a projection must difference, since a
        /// clamped value would hide a change at either end of the band.
        public var unclampedBodyAge: Double { chronoAge + lnHazardSum / VitalityEngine.lnHazardPerYear }
    }

    /// Minimum distinct factors before a number is shown (honesty gate).
    public static let minFactors = 3
    public static let bandYears = 5.0
    /// Smallest share, in years, that is named as the biggest lever. Below it nothing is worth naming.
    public static let minLeverYears = 0.25

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }

    private static func isFemale(_ sex: String?) -> Bool { sex?.lowercased() == "female" }

    /// Linear interpolation over `(x, y)` anchors sorted by x, flat beyond both ends.
    static func interpolate(_ anchors: [(Double, Double)], _ x: Double) -> Double {
        guard let first = anchors.first, let last = anchors.last else { return 0 }
        if x <= first.0 { return first.1 }
        if x >= last.0 { return last.1 }
        for i in 1..<anchors.count where x <= anchors[i].0 {
            let (x0, y0) = anchors[i - 1], (x1, y1) = anchors[i]
            return y0 + (y1 - y0) * (x - x0) / (x1 - x0)
        }
        return last.1
    }

    // MARK: - Unlock gate

    /// Scored days (a night with a resting HR) required inside `unlockWindowDays` before Body Age is shown.
    public static let unlockMinScoredDays = 21
    public static let unlockWindowDays = 31
    /// Body Age is an adult model; WHOOP's gate is the same.
    public static let minAge = 18.0

    /// Whether Body Age may be shown yet, and how many more scored days that needs. `unlocked` requires
    /// both the scored-day count and an adult age; the countdown only counts days.
    public static func unlockStatus(scoredDaysInWindow: Int, age: Double)
        -> (unlocked: Bool, daysUntilUnlock: Int) {
        let remaining = max(0, unlockMinScoredDays - scoredDaysInWindow)
        return (remaining == 0 && age >= minAge, remaining)
    }

    // MARK: - Nocturnal HRV norm (context only — never scored)

    /// Nocturnal RMSSD ~50th-percentile by age (ms), piecewise-linear between decade anchors. Context for
    /// a screen showing HRV beside Body Age; HRV itself is not a driver (see the header).
    public static func rmssdNorm(forAge age: Double) -> Double {
        interpolate([(20, 47), (30, 40), (40, 33), (50, 29), (60, 25), (70, 22), (80, 20)], age)
    }

    /// Sleep regularity (0–1) from a window of nightly sleep durations (hours): 1 − coefficient of
    /// variation, clamped. Used by the Rest score's consistency term; Body Age scores the timing-based
    /// Sleep Regularity Index instead (`SleepRegularity`). Fewer than 3 nights → nil.
    public static func sleepConsistency(nightlyHours: [Double]) -> Double? {
        let xs = nightlyHours.filter { $0 > 0 }
        guard xs.count >= 3 else { return nil }
        let mean = xs.reduce(0, +) / Double(xs.count)
        guard mean > 0 else { return nil }
        let variance = xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(xs.count)
        let cv = variance.squareRoot() / mean
        return clamp(1 - cv, 0, 1)
    }

    // MARK: - Targets (WHOOP white paper, Table 1)

    /// Sleeping resting HR target, bpm: below 60 for men, below 64 for women.
    public static func restingHRTarget(sex: String?) -> Double { isFemale(sex) ? 64 : 60 }

    /// VO₂max target, ml/kg/min, by age and sex. Anchored on the white paper's 30-year-old targets
    /// (~44 men, ~38 women) and sloped with the FRIEND registry's decline per decade (Kaminsky, Mayo Clin
    /// Proc 2015), so the target keeps its percentile as someone ages.
    public static func vo2maxTarget(age: Double, sex: String?) -> Double {
        isFemale(sex)
            ? interpolate([(20, 40), (30, 38), (40, 35), (50, 31), (60, 27), (70, 24), (80, 21)], age)
            : interpolate([(20, 46), (30, 44), (40, 41), (50, 37), (60, 33), (70, 29), (80, 25)], age)
    }

    /// Nightly sleep target band, hours.
    public static let sleepTargetLow = 7.0, sleepTargetHigh = 9.0
    /// Sleep Regularity Index target.
    public static let sriTarget = 70.0
    /// Muscle-strengthening target, min/wk.
    public static let strengthTargetMinPerWeek = 40.0

    /// Zone 1–3 (%HRR) target, min/wk: 100 at 30 and younger, easing to 70 by 70 (the white paper's
    /// 70–100 min/wk range, age-declining).
    public static func moderateTarget(age: Double) -> Double { interpolate([(30, 100), (70, 70)], age) }

    /// Zone 4–5 (%HRR) target, min/wk: 10 at 30 and younger, easing to 7 by 70.
    public static func vigorousTarget(age: Double) -> Double { interpolate([(30, 10), (70, 7)], age) }

    /// Daily steps target: 8,000, or 5,600 from age 60 (white paper; Paluch, Lancet Public Health 2022,
    /// found the benefit plateaus lower in older adults).
    public static func stepsTarget(age: Double) -> Double { age >= 60 ? 5600 : 8000 }

    /// Lean-mass percentage target: 80 % for men and 67 % for women at 30, easing by 0.1 point a year
    /// after 30 (lean fraction falls with age even in healthy adults).
    public static func leanMassTarget(age: Double, sex: String?) -> Double {
        (isFemale(sex) ? 67.0 : 80.0) - 0.1 * max(0, age - 30)
    }

    // MARK: - Dose-response curves (log-hazard vs the target; 0 at the target)

    /// Resting HR: +12 % all-cause mortality per +10 bpm (Zhang, CMAJ 2016, PMID 26598376; Aune, NMCD
    /// 2017, PMID 28552551, literature range 1.09–1.17). Linear in both directions, clamped to 10 bpm
    /// below and 40 bpm above the target — the cohorts are thin outside that span.
    public static func restingHRLnHazard(bpm: Double, sex: String?) -> Double {
        let t = restingHRTarget(sex: sex)
        return log(1.12) * (clamp(bpm, t - 10, t + 40) - t) / 10
    }

    /// VO₂max: ~13 % lower mortality per MET (3.5 ml/kg/min) above the target, with no plateau inside the
    /// measured range (Kokkinos, JACC 2022, PMID 35926933; Lang, BJSM 2024, PMID 38599681; Mandsager,
    /// JAMA Netw Open 2018 found no upper limit of benefit). Clamped to ±6 METs for sanity only.
    public static func vo2maxLnHazard(vo2max: Double, target: Double) -> Double {
        log(0.87) * clamp((vo2max - target) / 3.5, -6, 6)
    }

    /// Sleep duration, asymmetric around the 7–9 h target band. Short sleep costs more per hour than long
    /// on device-measured data: HR 1.27 short vs 1.16 long (UK Biobank accelerometry, J Gerontol A 2023,
    /// doi 10.1093/gerona/glad108; direction consistent with Yin, JAHA 2017). Each is applied per hour
    /// outside the band, capped at three hours. Zero anywhere inside the band.
    public static func sleepDurationLnHazard(hours: Double) -> Double {
        if hours < sleepTargetLow { return log(1.27) * min(3, sleepTargetLow - hours) }
        if hours > sleepTargetHigh { return log(1.16) * min(3, hours - sleepTargetHigh) }
        return 0
    }

    /// How much of the duration term survives when the Sleep Regularity Index is also scored. In the
    /// device cohorts, regularity was the stronger predictor and duration's hazard shrank once regularity
    /// was adjusted for (Windred, SLEEP 2024), so counting both at full weight double-counts one habit.
    public static let durationWeightWithRegularity = 0.5

    /// Sleep Regularity Index, a hinge. Windred et al. (SLEEP 2024, doi 10.1093/sleep/zsad253; device,
    /// UK Biobank) found most of the hazard in the least-regular quintile: all-cause HR 0.80 for Q2 and
    /// 0.70 for Q5 versus Q1, flattening above the median (SRI ≈ 81); Cribb (eLife 2023) agrees. Anchored
    /// at SRI 55 (Q1 level, not extrapolated below), 70 (Q2 level) and 81 (plateau), then re-referenced
    /// so the 70 target is zero.
    public static func sriLnHazard(sri: Double) -> Double {
        let f: (Double) -> Double = { interpolate([(55, -log(0.70)), (70, log(0.80) - log(0.70)), (81, 0)], $0) }
        return f(sri) - f(sriTarget)
    }

    /// Zone 1–3 (%HRR) minutes. No moderate activity against meeting the target: HR 0.81 (Lee DH,
    /// Circulation 2022 — the conservative end of its 19–25 % range). Device-measured dose-response keeps
    /// improving past the guideline and flattens by ~2–3× it (Ekelund, BMJ 2019, doi 10.1136/bmj.l4570),
    /// so a further 10 % is credited linearly up to three times the target and nothing beyond.
    public static func moderateLnHazard(minPerWeek: Double, age: Double) -> Double {
        let t = moderateTarget(age: age)
        return interpolate([(0, -log(0.81)), (t, 0), (3 * t, log(0.90))], max(0, minPerWeek))
    }

    /// Zone 4–5 (%HRR) minutes. Device-measured vigorous activity (Ahmadi, Eur Heart J 2022, doi
    /// 10.1093/eurheartj/ehac572; Stamatakis, Nat Med 2022): 15 min/wk HR 0.82 and 54 min/wk HR 0.64
    /// versus none, flattening beyond. Interpolated on the log scale between those anchors, then
    /// re-referenced so the age target is zero.
    public static func vigorousLnHazard(minPerWeek: Double, age: Double) -> Double {
        let f: (Double) -> Double = { interpolate([(0, 0), (15, log(0.82)), (54, log(0.64))], $0) }
        return f(max(0, minPerWeek)) - f(vigorousTarget(age: age))
    }

    /// Muscle-strengthening minutes: none against the optimum carries HR 0.90 (Momma, BJSM 2022 — the
    /// conservative end of its 10–17 %), linear to zero at the 40 min/wk target. Benefit-only: the
    /// J-shape's upper limb is unresolved in the source, so volume above the target (and above two hours)
    /// neither adds benefit nor invents a harm.
    public static func strengthLnHazard(minPerWeek: Double) -> Double {
        interpolate([(0, -log(0.90)), (strengthTargetMinPerWeek, 0)], max(0, minPerWeek))
    }

    /// Daily steps. Paluch et al. (Lancet Public Health 2022, doi 10.1016/S2468-2667(21)00302-9) quartile
    /// medians 3,553 / 5,801 / 7,842 / 10,901 steps carried HR 1 / 0.60 / 0.55 / 0.53; Banach (EJPC 2023)
    /// finds the benefit starting near 3.5k. Interpolated on the log scale between those anchors, flat
    /// below the lowest (no extrapolation) and above the highest, then re-referenced so the target is zero.
    /// From 60 the same curve is compressed so its 8,000 point lands on the 5,600 target, because the
    /// plateau comes earlier in older adults.
    public static func stepsLnHazard(steps: Double, age: Double) -> Double {
        let scale = 8000 / stepsTarget(age: age)
        let f: (Double) -> Double = {
            interpolate([(3553, 0), (5801, log(0.60)), (7842, log(0.55)), (10901, log(0.53))], $0 * scale)
        }
        return f(max(0, steps)) - f(stepsTarget(age: age))
    }

    /// Lean-mass percentage, penalty-only. Low fat-free mass carried a pooled all-cause RR of 1.31–1.42
    /// (J Cachexia Sarcopenia Muscle 2026, doi 10.1002/jcsm.70331); the conservative 1.31 is applied at
    /// ten points below target, linearly, and not extrapolated further. Above target this returns 0 — the
    /// evidence is about low muscle being harmful, not extra muscle being protective.
    ///
    /// EVIDENCE-CHAIN CAVEAT, and the reason any result using this factor is flagged `lowerConfidence`:
    /// NOOP measures no body composition; lean mass is an imported bioimpedance estimate.
    public static func leanMassLnHazard(percent: Double, age: Double, sex: String?) -> Double {
        log(1.31) * clamp((leanMassTarget(age: age, sex: sex) - percent) / 10, 0, 1)
    }

    /// Lean mass as a percentage of body weight. Nil for a non-positive weight.
    public static func leanMassPercent(leanMassKg: Double, weightKg: Double) -> Double? {
        guard weightKg > 0, leanMassKg > 0 else { return nil }
        return leanMassKg / weightKg * 100
    }

    // MARK: - Scoring

    /// The per-factor log-hazard contributions present in `inputs`, each referenced to its health target.
    /// `deltaYears` is nil here — only `compute` knows the domain shrink needed to turn a raw log-hazard
    /// into a share of the Body Age offset. The duration term is already down-weighted when regularity is
    /// present (`durationWeightWithRegularity`).
    public static func contributions(_ inputs: Inputs) -> [Contribution] {
        let age = inputs.chronoAge, sex = inputs.sex
        var out: [Contribution] = []
        if let rhr = inputs.restingHR {
            out.append(Contribution(key: "rhr", label: "Resting heart rate", domain: .fitness,
                                    lnHazard: restingHRLnHazard(bpm: rhr, sex: sex),
                                    value: rhr, target: restingHRTarget(sex: sex), unit: "bpm"))
        }
        if let vo2 = inputs.vo2max {
            let t = vo2maxTarget(age: age, sex: sex)
            out.append(Contribution(key: "vo2max", label: "Cardio fitness", domain: .fitness,
                                    lnHazard: vo2maxLnHazard(vo2max: vo2, target: t),
                                    value: vo2, target: t, unit: "ml/kg/min"))
        }
        if let sh = inputs.sleepHours {
            let weight = inputs.sleepRegularity == nil ? 1 : durationWeightWithRegularity
            out.append(Contribution(key: "sleep", label: "Sleep duration", domain: .sleep,
                                    lnHazard: sleepDurationLnHazard(hours: sh) * weight,
                                    value: sh, target: sleepTargetLow, unit: "h"))
        }
        if let sri = inputs.sleepRegularity {
            out.append(Contribution(key: "consistency", label: "Sleep regularity", domain: .sleep,
                                    lnHazard: sriLnHazard(sri: sri),
                                    value: sri, target: sriTarget, unit: "SRI"))
        }
        if let s = inputs.steps {
            out.append(Contribution(key: "steps", label: "Daily steps", domain: .activity,
                                    lnHazard: stepsLnHazard(steps: s, age: age),
                                    value: s, target: stepsTarget(age: age), unit: "steps/day"))
        }
        if let m = inputs.moderateMinPerWeek {
            out.append(Contribution(key: "moderate", label: "Zones 1–3", domain: .activity,
                                    lnHazard: moderateLnHazard(minPerWeek: m, age: age),
                                    value: m, target: moderateTarget(age: age), unit: "min/wk"))
        }
        if let v = inputs.vigorousMinPerWeek {
            out.append(Contribution(key: "vigorous", label: "Zones 4–5", domain: .activity,
                                    lnHazard: vigorousLnHazard(minPerWeek: v, age: age),
                                    value: v, target: vigorousTarget(age: age), unit: "min/wk"))
        }
        if let st = inputs.strengthMinPerWeek {
            out.append(Contribution(key: "strength", label: "Strength training", domain: .activity,
                                    lnHazard: strengthLnHazard(minPerWeek: st),
                                    value: st, target: strengthTargetMinPerWeek, unit: "min/wk"))
        }
        if let lean = inputs.leanMassKg, let w = inputs.weightKg,
           let pct = leanMassPercent(leanMassKg: lean, weightKg: w) {
            out.append(Contribution(key: "leanmass", label: "Lean mass", domain: .body,
                                    lnHazard: leanMassLnHazard(percent: pct, age: age, sex: sex),
                                    value: pct, target: leanMassTarget(age: age, sex: sex), unit: "%"))
        }
        return out
    }

    /// The divisor a domain's summed log-hazards are shrunk by: √n, except a strap-derived VO₂max beside
    /// resting HR, which folds into their mean (n) because it is computed from resting HR.
    static func domainDivisor(_ domain: Domain, count: Int, vo2maxSource: VO2maxSource) -> Double {
        let n = Double(max(1, count))
        if domain == .fitness, count >= 2, vo2maxSource == .strap { return n }
        return n.squareRoot()
    }

    /// Full Body Age + Vitality. Returns nil until at least `minFactors` inputs are present.
    ///
    /// Each factor's log-hazard is shrunk within its domain (`domainDivisor`), the per-domain sums are
    /// added, and `overlapShrink` applies across domains. Every returned contribution carries its
    /// resulting share of the offset, and those shares sum to the UNCLAMPED Δage exactly — so a breakdown
    /// rendered from `Result.contributions` reconciles with `bodyAge` by construction.
    public static func compute(_ inputs: Inputs) -> Result? {
        guard inputs.chronoAge > 0 else { return nil }
        let contribs = contributions(inputs)
        guard contribs.count >= minFactors else { return nil }

        var countByDomain: [Domain: Int] = [:]
        for c in contribs { countByDomain[c.domain, default: 0] += 1 }
        let scored = contribs.map { c -> Contribution in
            let divisor = domainDivisor(c.domain, count: countByDomain[c.domain] ?? 1,
                                        vo2maxSource: inputs.vo2maxSource)
            return c.withDeltaYears((c.lnHazard / divisor) * overlapShrink / lnHazardPerYear)
        }
        let deltaAge = scored.reduce(0) { $0 + ($1.deltaYears ?? 0) }   // +ve = ages you
        let bodyAge = clamp(inputs.chronoAge + deltaAge, minBodyAge, maxBodyAge)
        let delta = inputs.chronoAge - bodyAge              // +ve = younger than your age
        let lever = scored.filter { ($0.deltaYears ?? 0) >= minLeverYears }
            .max { ($0.deltaYears ?? 0) < ($1.deltaYears ?? 0) }
        return Result(vitality: clamp(50 + delta * vitalityPerYear, 0, 100), bodyAge: bodyAge,
                      chronoAge: inputs.chronoAge, deltaYears: delta, bandYears: bandYears,
                      contributions: scored, factorsUsed: scored.count,
                      lnHazardSum: deltaAge * lnHazardPerYear,
                      lowerConfidence: scored.contains { $0.key == "leanmass" },
                      biggestLever: lever)
    }
}
