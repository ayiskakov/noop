import Foundation

// VitalityEngine.swift — a transparent 0–100 "Vitality" wellness score + a "Body Age in years".
//
// INDEPENDENT implementation of the published, peer-reviewed method WHOOP's "Healthspan / WHOOP Age" also
// uses (NOT medical advice; a wellness comparison, never a clinical biological age): map each wearable-
// measurable input to its published ALL-CAUSE-MORTALITY hazard ratio relative to a population reference,
// sum the log-hazards with an overlap correction (the inputs are correlated, so the naive sum overstates),
// and convert that combined hazard into a "years of aging" offset using the Gompertz mortality-rate
// doubling time (mortality roughly doubles every ~8 years, so 1 doubling of hazard ≈ 8 years of age).
//
// Body Age = chronological age + Δage. An average-for-their-age person nets ~0 and reads at their own age;
// healthier-than-average reads younger, less healthy reads older. Presented with a ±band and a hard
// "wellness trend, not a biological/clinical age" disclaimer, gated on a minimum number of inputs.
//
// Per-factor hazard ratios are taken from large cohorts / meta-analyses (UK Biobank, FRIEND, pooled
// step- and activity-mortality meta-analyses, sleep-regularity and HRV cohorts). They are deliberately
// CONSERVATIVE and the model is clamped, because this is a wellness estimate, not a diagnosis.
//
// ── DOMAIN GROUPING (why the log-hazards are not simply added up) ──────────────────────────────────
//
// The drivers are not independent measurements: steps, moderate-zone minutes, vigorous-zone minutes and
// strength minutes are four views of ONE latent construct (how much you move), just as VO₂max and resting
// heart rate are two views of cardiorespiratory fitness. Adding four correlated activity terms at full
// weight would hand an active person roughly four times the benefit the evidence supports — the same
// double-counting `FitnessAgeEngine.physicalActivityIndexFromStrain` refuses when it maps strain to the
// HUNT intensity×duration PRODUCT rather than re-deriving both factors.
//
// So each factor is assigned a DOMAIN, and a domain's terms are summed then divided by √n (the standard
// effective-independent-signals correction: n equally-correlated measures of one construct carry about
// √n measurements' worth of independent information, not n). The cross-domain `overlapShrink` then
// applies as before. A single-factor domain is unchanged by this (√1 = 1).
public enum VitalityEngine {

    // Gompertz: mortality-rate doubling time ≈ 8 years → ln(hazard) per year of age = ln(2)/8.
    public static let lnHazardPerYear = 0.6931471805599453 / 8.0   // ≈ 0.0866
    /// Correlated DOMAINS (fitness, activity and sleep all move together) → shrink the summed per-domain
    /// log-hazards so we don't multiply the same underlying signal several times. 0.75 is a deliberately
    /// gentle shrink. Within-domain correlation is handled separately by the √n rule (see the header).
    static let overlapShrink = 0.75
    /// Body Age is clamped to a sane band; Vitality maps Δage linearly around 50 (= "at your age").
    static let minBodyAge = 20.0, maxBodyAge = 90.0
    static let vitalityPerYear = 2.5   // each year younger than your age = +2.5 Vitality points

    /// Which latent construct a factor measures. Factors sharing a domain are shrunk against each other
    /// (√n) before the cross-domain shrink, because they are largely the same signal read twice.
    public enum Domain: String, Equatable, Sendable, CaseIterable {
        case fitness      // VO₂max, resting heart rate
        case activity     // steps, moderate-zone minutes, vigorous-zone minutes, strength minutes
        case sleep        // duration, regularity
        case autonomic    // HRV
        case body         // fat-free mass index
    }

    /// The wearable inputs Vitality reads. All optional — the score uses whatever is present (≥ minFactors).
    public struct Inputs: Equatable, Sendable {
        public var chronoAge: Double
        public var restingHR: Double?          // bpm
        public var vo2max: Double?             // ml/kg/min (e.g. from FitnessAgeEngine)
        public var expectedVO2max: Double?     // age/sex-expected ml/kg/min (the reference for vo2max)
        public var sleepHours: Double?         // mean nightly sleep
        public var sleepConsistency: Double?   // 0–1 regularity (1 = perfectly regular)
        public var rmssd: Double?              // ms, nocturnal HRV
        public var rmssdNorm: Double?          // age/sex-normative RMSSD (the reference)
        public var steps: Double?              // mean daily steps
        /// Weekly minutes in HR zones 2–3 — the MODERATE-intensity dose (see `moderateTargetMinPerWeek`).
        public var moderateMinPerWeek: Double?
        /// Weekly minutes in HR zones 4–5 — the VIGOROUS-intensity dose.
        public var vigorousMinPerWeek: Double?
        /// Weekly minutes of muscle-strengthening activity.
        public var strengthMinPerWeek: Double?
        /// Whole-body lean (fat-free) mass in kg — with `heightCm` this forms the fat-free mass index.
        public var leanMassKg: Double?
        public var heightCm: Double?
        /// "male" | "female" | anything else — only used to pick the FFMI cutoff (see `ffmiCutoff`).
        public var sex: String?

        public init(chronoAge: Double, restingHR: Double? = nil, vo2max: Double? = nil,
                    expectedVO2max: Double? = nil, sleepHours: Double? = nil,
                    sleepConsistency: Double? = nil, rmssd: Double? = nil,
                    rmssdNorm: Double? = nil, steps: Double? = nil,
                    moderateMinPerWeek: Double? = nil, vigorousMinPerWeek: Double? = nil,
                    strengthMinPerWeek: Double? = nil, leanMassKg: Double? = nil,
                    heightCm: Double? = nil, sex: String? = nil) {
            self.chronoAge = chronoAge; self.restingHR = restingHR; self.vo2max = vo2max
            self.expectedVO2max = expectedVO2max; self.sleepHours = sleepHours
            self.sleepConsistency = sleepConsistency; self.rmssd = rmssd
            self.rmssdNorm = rmssdNorm; self.steps = steps
            self.moderateMinPerWeek = moderateMinPerWeek; self.vigorousMinPerWeek = vigorousMinPerWeek
            self.strengthMinPerWeek = strengthMinPerWeek; self.leanMassKg = leanMassKg
            self.heightCm = heightCm; self.sex = sex
        }
    }

    /// One factor's contribution: what it measured, what the reference is, and its signed log-hazard vs
    /// that reference (positive = ages you, negative = protective).
    public struct Contribution: Equatable, Sendable {
        public let key: String
        public let label: String
        public let domain: Domain
        /// RAW log-hazard vs this factor's reference, BEFORE any domain or cross-domain shrink.
        public let lnHazard: Double
        /// The measured value this factor was scored from, in `unit`.
        public let value: Double
        /// The reference value that contributes exactly zero, in `unit`.
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
        public let vitality: Double        // 0–100 (50 = typical for your age)
        public let bodyAge: Double         // years, clamped
        public let chronoAge: Double
        public let deltaYears: Double      // chronoAge − bodyAge (positive = younger than your age)
        public let bandYears: Double
        /// The per-factor breakdown WITH `deltaYears` filled — the single funnel a UI breakdown must read,
        /// so the rows and the headline can never disagree.
        public let contributions: [Contribution]
        public let factorsUsed: Int
        /// The summed, fully-shrunk log-hazard the Body Age was derived from. `PaceOfAgingEngine` reads
        /// this: it is the quantity whose drift over time IS the pace of aging.
        public let lnHazardSum: Double
        /// True when a factor whose evidence chain is weaker than the rest was used (currently only the
        /// fat-free mass index — see `ffmiLnHazard`). A UI should soften its claim accordingly.
        public let lowerConfidence: Bool

        public init(vitality: Double, bodyAge: Double, chronoAge: Double, deltaYears: Double,
                    bandYears: Double, contributions: [Contribution], factorsUsed: Int,
                    lnHazardSum: Double = 0, lowerConfidence: Bool = false) {
            self.vitality = vitality; self.bodyAge = bodyAge; self.chronoAge = chronoAge
            self.deltaYears = deltaYears; self.bandYears = bandYears
            self.contributions = contributions; self.factorsUsed = factorsUsed
            self.lnHazardSum = lnHazardSum; self.lowerConfidence = lowerConfidence
        }
    }

    /// Minimum distinct factors before we'll show a number (honesty gate).
    public static let minFactors = 3
    public static let bandYears = 5.0

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }

    /// Nocturnal RMSSD ~50th-percentile by age (ms), piecewise-linear between decade anchors (the WHOOP-
    /// window norms banked in the spec — never mixed with daytime clinical norms). The reference for the
    /// HRV factor: a person at the age norm contributes 0.
    public static func rmssdNorm(forAge age: Double) -> Double {
        let anchors: [(Double, Double)] = [(20, 47), (30, 40), (40, 33), (50, 29), (60, 25), (70, 22), (80, 20)]
        if age <= anchors[0].0 { return anchors[0].1 }
        if age >= anchors[anchors.count - 1].0 { return anchors[anchors.count - 1].1 }
        for i in 1..<anchors.count where age <= anchors[i].0 {
            let (a0, v0) = anchors[i - 1]; let (a1, v1) = anchors[i]
            return v0 + (v1 - v0) * (age - a0) / (a1 - a0)
        }
        return anchors[anchors.count - 1].1
    }

    /// Sleep regularity (0–1) from a window of nightly sleep durations (hours): 1 − coefficient of
    /// variation, clamped. A rough but honest on-device proxy for the Sleep Regularity Index when we only
    /// have durations, not full timing. Fewer than 3 nights → nil (not enough to judge).
    public static func sleepConsistency(nightlyHours: [Double]) -> Double? {
        let xs = nightlyHours.filter { $0 > 0 }
        guard xs.count >= 3 else { return nil }
        let mean = xs.reduce(0, +) / Double(xs.count)
        guard mean > 0 else { return nil }
        let variance = xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(xs.count)
        let cv = variance.squareRoot() / mean
        return clamp(1 - cv, 0, 1)
    }

    // MARK: - Activity dose-response references
    //
    // The aerobic and strength evidence is CATEGORICAL — published cohorts report "meeting the guideline
    // versus none", not a per-minute slope — so each curve below is anchored on the published categories
    // and linearly interpolated BETWEEN them. The target is the dose at which the benefit is already
    // realised, so meeting it contributes exactly zero and doing nothing carries the full published hazard.

    /// Weekly minutes in HR zones 2–3 at which the moderate-activity benefit is realised (the 2018 US
    /// guideline minimum, and the category the hazard ratio below was measured on).
    public static let moderateTargetMinPerWeek = 150.0
    /// Weekly minutes in HR zones 4–5 at which the vigorous-activity benefit is realised.
    public static let vigorousTargetMinPerWeek = 75.0
    /// Weekly minutes of muscle-strengthening at which the benefit is realised — the LOWER edge of the
    /// published 30–60 min/wk optimum band, so a user at target is genuinely at zero hazard.
    public static let strengthTargetMinPerWeek = 30.0

    /// Moderate-intensity (HR zones 2–3) log-hazard vs the 150 min/wk guideline.
    ///
    /// Lee DH et al., *Circulation* 2022;146:523-534 (Nurses' Health Study + Health Professionals
    /// Follow-up Study, 116,221 adults, 30 years, 47,596 deaths; MPA and VPA mutually adjusted). Meeting
    /// the MPA guideline (150–299 min/wk) versus none was associated with a "19% to 25% lower risk of
    /// all-cause, CVD, and non-CVD mortality"; the paper gives that as a RANGE across the three outcomes
    /// rather than one all-cause point estimate, so the CONSERVATIVE end (19%, HR 0.81) is used. Above the
    /// guideline, 300–599 min/wk carried a further "3% to 13%" lower mortality versus guideline-meeters —
    /// again the conservative end (3%) — and ≥600 min/wk "did not clearly show further lower … mortality
    /// or harm", so the curve is FLAT beyond 300 rather than continuing to reward volume.
    ///
    /// NOTE on zone choice: zones 2–3 (60–80% HRmax), NOT zones 1–3. Zone 1 is 50–60% of HRmax, below the
    /// ~64% HRmax floor the moderate-intensity category these hazard ratios were measured on begins at, so
    /// counting it would inflate the dose against a reference that never included it.
    public static func moderateLnHazard(minPerWeek: Double) -> Double {
        let m = max(0, minPerWeek)
        let none = -log(0.81)          // +0.2107 — no moderate activity, vs meeting the guideline
        let beyond = log(0.97)         // −0.0305 — 300–599 min/wk, vs meeting the guideline
        if m <= 0 { return none }
        if m < moderateTargetMinPerWeek { return none * (1 - m / moderateTargetMinPerWeek) }
        if m >= 300 { return beyond }
        return beyond * ((m - moderateTargetMinPerWeek) / (300 - moderateTargetMinPerWeek))
    }

    /// Vigorous-intensity (HR zones 4–5) log-hazard vs the 75 min/wk guideline.
    ///
    /// Same cohort (Lee DH et al., *Circulation* 2022): meeting the VPA guideline (75–149 min/wk) versus
    /// no VPA gave an all-cause hazard ratio of 0.81 (95% CI, 0.76–0.87) — here a DIRECT all-cause point
    /// estimate. 150–299 min/wk carried a further "2% to 4%" lower mortality versus guideline-meeters
    /// (conservative end, 2%), and ≥300 min/wk showed no clear further benefit or harm, so the curve is
    /// flat beyond 150.
    public static func vigorousLnHazard(minPerWeek: Double) -> Double {
        let m = max(0, minPerWeek)
        let none = -log(0.81)          // +0.2107 — no vigorous activity, vs meeting the guideline
        let beyond = log(0.98)         // −0.0202 — 150–299 min/wk, vs meeting the guideline
        if m <= 0 { return none }
        if m < vigorousTargetMinPerWeek { return none * (1 - m / vigorousTargetMinPerWeek) }
        if m >= 150 { return beyond }
        return beyond * ((m - vigorousTargetMinPerWeek) / (150 - vigorousTargetMinPerWeek))
    }

    /// Muscle-strengthening log-hazard vs the 30 min/wk optimum floor.
    ///
    /// Momma H et al., *Br J Sports Med* 2022;56(13):755-763 — systematic review and meta-analysis of 16
    /// prospective cohorts, independent of aerobic activity. Muscle-strengthening activities carried a
    /// "10-17% lower risk of all-cause mortality" with "J-shaped associations with the maximum risk
    /// reduction (approximately 10-20%) at approximately 30-60 min/week"; the CONSERVATIVE end (10%,
    /// HR 0.90) is used.
    ///
    /// The J-shape's UPPER limb is deliberately not modelled: the paper's own conclusion is that the
    /// influence of a higher volume "is unclear", so above 60 min/wk this returns 0 (benefit realised,
    /// no penalty) rather than inventing a harm the evidence does not confidently support.
    public static func strengthLnHazard(minPerWeek: Double) -> Double {
        let m = max(0, minPerWeek)
        let none = -log(0.90)          // +0.1054 — no strength training, vs the optimum band
        if m <= 0 { return none }
        if m < strengthTargetMinPerWeek { return none * (1 - m / strengthTargetMinPerWeek) }
        return 0
    }

    /// Fat-free mass index (kg/m²) below which muscle mass reads as REDUCED: 17 for men, 15 for women.
    /// ESPEN's proposed reference values, carried into the GLIM malnutrition criteria.
    public static func ffmiCutoff(sex: String?) -> Double {
        (sex?.lowercased() == "female") ? 15.0 : 17.0
    }

    /// Fat-free mass index log-hazard — BINARY, and it can only penalise, never reward.
    ///
    /// Pooled relative risk of all-cause mortality for LOW skeletal muscle mass index versus normal:
    /// 1.57 (95% CI, 1.25–1.96), from a systematic review and meta-analysis of 16 prospective cohorts
    /// (81,358 participants, 11,696 deaths; *PLOS ONE* 2023, 18(6):e0286745). The published evidence is
    /// about low muscle mass being harmful — there is no matching finding that extra muscle is protective
    /// — so above the cutoff this returns 0 rather than extrapolating a benefit.
    ///
    /// EVIDENCE-CHAIN CAVEAT, and the reason any result using this factor is flagged `lowerConfidence`:
    /// the hazard ratio comes from studies of APPENDICULAR skeletal muscle mass index, while the cutoff
    /// (ESPEN/GLIM) and our own input are WHOLE-BODY fat-free mass. The two indices are not the same
    /// measurement, and NOOP's lean mass is itself an imported bioimpedance estimate. This is the weakest
    /// of the nine drivers; it is optional, off unless a lean-mass reading exists, and softens the claim.
    public static func ffmiLnHazard(ffmi: Double, sex: String?) -> Double {
        ffmi < ffmiCutoff(sex: sex) ? log(1.57) : 0
    }

    /// Fat-free mass index (kg/m²) from whole-body lean mass and height. Nil for a non-positive height.
    public static func ffmi(leanMassKg: Double, heightCm: Double) -> Double? {
        let m = heightCm / 100.0
        guard m > 0 else { return nil }
        return leanMassKg / (m * m)
    }

    /// Compute the per-factor log-hazard contributions present in `inputs`, each referenced to a population
    /// value so an average person nets ~0. `deltaYears` is nil here — only `compute` knows the domain
    /// shrink needed to turn a raw log-hazard into a share of the Body Age offset.
    ///
    /// Published per-unit hazard ratios (conservative, clamped):
    ///   • Resting HR: +~10.5% all-cause mortality per +10 bpm (UK Biobank / meta-analyses). ref 65.
    ///   • VO₂max: ~14% per MET (3.5 ml/kg/min) vs the age/sex-expected value (FRIEND). fitter = protective.
    ///   • Sleep duration: U-shaped, optimum ~7.5 h; only deviation beyond ±0.5 h adds hazard (~12%/h).
    ///   • Sleep regularity: most-regular vs least ≈ HR 0.70 (UK Biobank SRI). ref 0.75 of the 0–1 range.
    ///   • HRV (RMSSD): ~16% per relative SD below the age norm (lower HRV = higher hazard).
    ///   • Steps: ~12% per 1,000 steps/day up to ~7k, diminishing to ~11k (pooled step-mortality meta).
    ///   • Moderate / vigorous / strength minutes and the fat-free mass index: see each helper above.
    public static func contributions(_ inputs: Inputs) -> [Contribution] {
        var out: [Contribution] = []
        if let rhr = inputs.restingHR {
            out.append(Contribution(key: "rhr", label: "Resting heart rate", domain: .fitness,
                                    lnHazard: ((rhr - 65) / 10) * 0.100,
                                    value: rhr, target: 65, unit: "bpm"))
        }
        if let vo2 = inputs.vo2max, let exp = inputs.expectedVO2max, exp > 0 {
            // (expected − vo2): if fitter than expected this is negative → protective.
            out.append(Contribution(key: "vo2max", label: "Cardio fitness", domain: .fitness,
                                    lnHazard: clamp((exp - vo2) / 3.5, -4, 4) * 0.130,
                                    value: vo2, target: exp, unit: "ml/kg/min"))
        }
        if let sh = inputs.sleepHours {
            let dev = max(0, abs(sh - 7.5) - 0.5)   // only deviation > ±0.5 h is a risk; optimum is neutral
            out.append(Contribution(key: "sleep", label: "Sleep duration", domain: .sleep,
                                    lnHazard: clamp(dev, 0, 3) * 0.110,
                                    value: sh, target: 7.5, unit: "h"))
        }
        if let c = inputs.sleepConsistency {
            out.append(Contribution(key: "consistency", label: "Sleep regularity", domain: .sleep,
                                    lnHazard: (0.75 - clamp(c, 0, 1)) * 0.450,
                                    value: c, target: 0.75, unit: ""))
        }
        if let h = inputs.rmssd, let norm = inputs.rmssdNorm, norm > 0 {
            out.append(Contribution(key: "hrv", label: "Heart-rate variability", domain: .autonomic,
                                    lnHazard: clamp((norm - h) / norm, -1, 1) * 0.160,
                                    value: h, target: norm, unit: "ms"))
        }
        if let s = inputs.steps {
            // Below ~7k each −1,000 steps adds hazard; protection caps near 11k (diminishing returns).
            let deficit = (7000 - clamp(s, 0, 11000)) / 1000
            out.append(Contribution(key: "steps", label: "Daily steps", domain: .activity,
                                    lnHazard: clamp(deficit, -4, 4) * 0.064,
                                    value: s, target: 7000, unit: "steps/day"))
        }
        if let m = inputs.moderateMinPerWeek {
            out.append(Contribution(key: "moderate", label: "Moderate cardio", domain: .activity,
                                    lnHazard: moderateLnHazard(minPerWeek: m),
                                    value: m, target: moderateTargetMinPerWeek, unit: "min/wk"))
        }
        if let v = inputs.vigorousMinPerWeek {
            out.append(Contribution(key: "vigorous", label: "Vigorous cardio", domain: .activity,
                                    lnHazard: vigorousLnHazard(minPerWeek: v),
                                    value: v, target: vigorousTargetMinPerWeek, unit: "min/wk"))
        }
        if let st = inputs.strengthMinPerWeek {
            out.append(Contribution(key: "strength", label: "Strength training", domain: .activity,
                                    lnHazard: strengthLnHazard(minPerWeek: st),
                                    value: st, target: strengthTargetMinPerWeek, unit: "min/wk"))
        }
        if let lean = inputs.leanMassKg, let hcm = inputs.heightCm,
           let index = ffmi(leanMassKg: lean, heightCm: hcm) {
            out.append(Contribution(key: "leanmass", label: "Lean mass", domain: .body,
                                    lnHazard: ffmiLnHazard(ffmi: index, sex: inputs.sex),
                                    value: index, target: ffmiCutoff(sex: inputs.sex), unit: "kg/m²"))
        }
        return out
    }

    /// Full Vitality + Body Age. Returns nil until at least `minFactors` inputs are present.
    ///
    /// Each factor's log-hazard is shrunk by √n over the factors sharing its domain (see the file header),
    /// the per-domain sums are added, and `overlapShrink` applies across domains. Every returned
    /// contribution carries its resulting share of the offset, and those shares sum to the UNCLAMPED Δage
    /// exactly — so a breakdown rendered from `Result.contributions` reconciles with `bodyAge` by
    /// construction rather than by a second, independent computation.
    public static func compute(_ inputs: Inputs) -> Result? {
        guard inputs.chronoAge > 0 else { return nil }
        let contribs = contributions(inputs)
        guard contribs.count >= minFactors else { return nil }

        var countByDomain: [Domain: Int] = [:]
        for c in contribs { countByDomain[c.domain, default: 0] += 1 }
        // One factor's share of Δage: its raw log-hazard, shrunk within its domain and then across
        // domains, divided by the Gompertz log-hazard per year. Summing these IS `deltaAge`.
        let scored = contribs.map { c -> Contribution in
            let n = Double(countByDomain[c.domain] ?? 1)
            let years = (c.lnHazard / n.squareRoot()) * overlapShrink / lnHazardPerYear
            return c.withDeltaYears(years)
        }
        let deltaAge = scored.reduce(0) { $0 + ($1.deltaYears ?? 0) }   // +ve = ages you
        let sumLn = deltaAge * lnHazardPerYear
        let bodyAge = clamp(inputs.chronoAge + deltaAge, minBodyAge, maxBodyAge)
        let delta = inputs.chronoAge - bodyAge              // +ve = younger than your age
        let vitality = clamp(50 + delta * vitalityPerYear, 0, 100)
        return Result(vitality: vitality, bodyAge: bodyAge, chronoAge: inputs.chronoAge,
                      deltaYears: delta, bandYears: bandYears, contributions: scored,
                      factorsUsed: scored.count, lnHazardSum: sumLn,
                      lowerConfidence: scored.contains { $0.key == "leanmass" })
    }
}
