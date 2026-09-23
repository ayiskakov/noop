import Foundation
import StrandAnalytics
import WhoopStore

// HealthspanPipeline.swift — turns stored history into the daily Healthspan points (Body Age, Pace of
// Aging, and what each driver is worth in years).
//
// ── ONE RESOLVER, EVERY WINDOW ────────────────────────────────────────────────────────────────────
//
// Body Age reads the last 182 days (WHOOP's six months), the pace compares the last 30 against them, and
// the pace's margin reads the six non-overlapping 30-day windows between. All of them come from
// `healthspanInputs(history:endDay:windowDays:…)`: two builders would let the Body Age and the pace that
// projects it describe differently-shaped people.
//
// ── ONE STORED POINT PER DAY, ONE FUNNEL ─────────────────────────────────────────────────────────
//
// Each unlocked day gets one set of points: the headline (`body_age`, `vitality`), the pace
// (`pace_of_aging`, its margin, the projected Body Age) and, per driver, its years, value, target and
// last-30-day value (`hs_years_<key>` …). A screen showing a driver's years reads the SAME row the
// headline was summed from, so the breakdown cannot disagree with the number it explains. Nothing is
// recomputed on a screen.
//
// ── MODEL VERSION ─────────────────────────────────────────────────────────────────────────────────
//
// The stored rows outlive the model that wrote them. A `healthspan_model` marker row records which model
// the stored history came from; when it is older than `HealthspanSeries.modelVersion`, the whole
// Healthspan history is cleared and re-derived under the current model in one pass, so the trend chart
// never splices two models together at the upgrade date. The pass is idempotent: re-running it produces
// the same rows, and the marker is written only after the rows are.

/// The metricSeries keys the Healthspan pipeline writes, in one place for writer and readers alike.
enum HealthspanSeries {
    /// Bumped whenever a change would make stored history disagree with a fresh computation.
    /// 1 = the Saturday-keyed weekly population-referent model; 2 = the target-referent daily model.
    static let modelVersion = 2.0
    static let modelKey = "healthspan_model"
    /// The marker row's day: a fixed key outside any real history, so it never shows up in a chart.
    static let modelDay = "1970-01-01"

    static let bodyAge = "body_age"
    static let vitality = "vitality"
    static let pace = "pace_of_aging"
    static let paceMargin = "pace_of_aging_margin"
    static let projectedBodyAge = "body_age_projected"

    /// Every driver key `VitalityEngine.contributions` can produce.
    static let drivers = ["rhr", "vo2max", "sleep", "consistency", "steps",
                          "moderate", "vigorous", "strength", "leanmass"]
    static func years(_ driver: String) -> String { "hs_years_\(driver)" }
    static func value(_ driver: String) -> String { "hs_value_\(driver)" }
    static func target(_ driver: String) -> String { "hs_target_\(driver)" }
    static func recent(_ driver: String) -> String { "hs_recent_\(driver)" }

    /// Every key a day's points can carry — what a recomputation clears before it writes.
    static let allKeys: [String] = [bodyAge, vitality, pace, paceMargin, projectedBodyAge]
        + drivers.flatMap { [years($0), value($0), target($0), recent($0)] }

    /// Per-day heart-rate-reserve zone minutes (Karvonen 50–80 % and ≥ 80 % HRR), the unit the zone
    /// targets are stated in. Written by the day scan; the old %HRmax `zone_min_2_3` / `zone_min_4_5`
    /// rows are left as they are and no longer read here.
    static let zoneModerate = "zone_min_hrr_1_3"
    static let zoneVigorous = "zone_min_hrr_4_5"
    static let strength = "strength_min"

    /// Days re-derived on a model upgrade. The trend chart shows six months; two years keeps Trends'
    /// longer Body Age history without re-deriving a decade of imported data on first launch.
    static let rederiveDays = 730
    /// Days recomputed on an ordinary pass: long enough to pick up late-arriving imports and re-scored
    /// nights, short enough to be cheap.
    static let refreshDays = 7
}

/// Everything the resolver reads, keyed by day index (`PaceOfAgingEngine.dayIndex`).
struct HealthspanHistory {
    var days: [Int: DailyMetric] = [:]
    var zones: [Int: (moderate: Double, vigorous: Double)] = [:]
    var strength: [Int: Double] = [:]
    /// `SleepRegularity.dailyAgreement`, keyed by the earlier sleep day of each pair.
    var sriAgreement: [Int: Double] = [:]
    var vo2max: [Int: (value: Double, source: VitalityEngine.VO2maxSource)] = [:]
    var leanMass: [Int: Double] = [:]
    var weight: [Int: Double] = [:]
}

extension IntelligenceEngine {

    /// Observed days out of a window before an activity dose is claimed at all. Below this, one logged day
    /// would become a whole week's dose.
    nonisolated static let healthspanMinActivityDays = 4

    /// Scale an activity dose observed on `observedDays` of a window up to a week.
    ///
    /// A window rarely has every day observed, and the targets are stated per week — so the observed days
    /// are averaged and scaled, the same treatment the sleep and step means get. Nil below
    /// `healthspanMinActivityDays`, because scaling one day by seven is not a measurement.
    nonisolated static func healthspanScaledDose(total: Double, observedDays: Int, windowDays: Int) -> Double? {
        guard observedDays >= healthspanMinActivityDays, observedDays > 0, windowDays > 0 else { return nil }
        return total / Double(observedDays) * Double(windowDays)
    }

    nonisolated static func healthspanMedian(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted(), n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    nonisolated static func healthspanMean(_ xs: [Double]) -> Double? {
        xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
    }

    /// Scored days (a night with a resting HR) in the `VitalityEngine.unlockWindowDays` ending `endDay`.
    nonisolated static func healthspanScoredDays(_ history: HealthspanHistory, endDay: Int) -> Int {
        (0..<VitalityEngine.unlockWindowDays).filter { history.days[endDay - $0]?.restingHr != nil }.count
    }

    /// The Body Age inputs for the `windowDays` ending on `endDay` (inclusive).
    ///
    /// A day counts as OBSERVED for activity when it banked a zone reading, i.e. the strap saw its heart
    /// rate. On such a day, no strength entry means genuinely no strength training — absent and zero are
    /// different facts, and only a day that was watched can tell them apart.
    nonisolated static func healthspanInputs(history: HealthspanHistory, endDay: Int, windowDays: Int,
                                             age: Double, sex: String,
                                             profileWeightKg: Double?) -> VitalityEngine.Inputs {
        let span = (endDay - windowDays + 1)...endDay
        let days = span.compactMap { history.days[$0] }
        let rhrs = days.compactMap { $0.restingHr }.map(Double.init)
        let nights = days.compactMap { $0.totalSleepMin }.map { $0 / 60.0 }.filter { $0 > 0 }
        let steps = days.compactMap { $0.steps }.map(Double.init)

        let observed = span.filter { history.zones[$0] != nil }
        let moderate = observed.reduce(0.0) { $0 + (history.zones[$1]?.moderate ?? 0) }
        let vigorous = observed.reduce(0.0) { $0 + (history.zones[$1]?.vigorous ?? 0) }
        let strength = observed.reduce(0.0) { $0 + (history.strength[$1] ?? 0) }

        // Pairs whose earlier sleep day starts the evening before the window's first day, through the
        // last night that ends inside it.
        let sri = SleepRegularity.index(agreement: history.sriAgreement,
                                        fromDay: span.lowerBound - 1, toDay: span.upperBound - 1)

        // An external VO₂max is independent evidence and wins when the window has one.
        let vo2 = span.compactMap { history.vo2max[$0] }
        let external = vo2.filter { $0.source == .external }.map(\.value)
        let strap = vo2.filter { $0.source == .strap }.map(\.value)

        let lean = healthspanMean(span.compactMap { history.leanMass[$0] })
        let weight = healthspanMean(span.compactMap { history.weight[$0] }) ?? profileWeightKg

        return VitalityEngine.Inputs(
            chronoAge: age, sex: sex,
            restingHR: healthspanMedian(rhrs),
            vo2max: healthspanMean(external) ?? healthspanMean(strap),
            vo2maxSource: external.isEmpty ? .strap : .external,
            sleepHours: healthspanMean(nights),
            sleepRegularity: sri,
            steps: healthspanMean(steps),
            moderateMinPerWeek: healthspanScaledDose(total: moderate, observedDays: observed.count, windowDays: 7),
            vigorousMinPerWeek: healthspanScaledDose(total: vigorous, observedDays: observed.count, windowDays: 7),
            strengthMinPerWeek: healthspanScaledDose(total: strength, observedDays: observed.count, windowDays: 7),
            leanMassKg: lean,
            weightKg: lean == nil ? nil : weight)
    }

    /// The day's Healthspan points, or empty while Healthspan is locked (fewer than 21 scored days in the
    /// last 31, or under 18) or the six-month window cannot be scored.
    nonisolated static func healthspanPoints(history: HealthspanHistory, endDay: Int, dayKey: String,
                                             age: Double, sex: String,
                                             profileWeightKg: Double?) -> [MetricPoint] {
        let scored = healthspanScoredDays(history, endDay: endDay)
        guard VitalityEngine.unlockStatus(scoredDaysInWindow: scored, age: age).unlocked else { return [] }
        func inputs(_ end: Int, _ window: Int) -> VitalityEngine.Inputs {
            healthspanInputs(history: history, endDay: end, windowDays: window, age: age, sex: sex,
                             profileWeightKg: profileWeightKg)
        }
        let baseline = inputs(endDay, PaceOfAgingEngine.baselineWindowDays)
        guard let body = VitalityEngine.compute(baseline) else { return [] }
        let recent = inputs(endDay, PaceOfAgingEngine.projectionRecentDays)
        // The six non-overlapping monthly windows of the half-year, each only when it holds enough scored
        // days to be a habit rather than a handful of nights.
        let monthly = (0..<6).compactMap { k -> VitalityEngine.Inputs? in
            let end = endDay - k * PaceOfAgingEngine.projectionRecentDays
            let scoredInWindow = (0..<PaceOfAgingEngine.projectionRecentDays)
                .filter { history.days[end - $0]?.restingHr != nil }.count
            return scoredInWindow >= PaceOfAgingEngine.minWindowDays
                ? inputs(end, PaceOfAgingEngine.projectionRecentDays) : nil
        }

        var out = [MetricPoint(day: dayKey, key: HealthspanSeries.bodyAge, value: body.bodyAge),
                   MetricPoint(day: dayKey, key: HealthspanSeries.vitality, value: body.vitality)]
        for c in body.contributions {
            out.append(MetricPoint(day: dayKey, key: HealthspanSeries.years(c.key), value: c.deltaYears ?? 0))
            out.append(MetricPoint(day: dayKey, key: HealthspanSeries.value(c.key), value: c.value))
            out.append(MetricPoint(day: dayKey, key: HealthspanSeries.target(c.key), value: c.target))
        }
        for c in VitalityEngine.contributions(recent) {
            out.append(MetricPoint(day: dayKey, key: HealthspanSeries.recent(c.key), value: c.value))
        }
        if let p = PaceOfAgingEngine.project(baseline: baseline, recent: recent, monthlyWindows: monthly) {
            out.append(MetricPoint(day: dayKey, key: HealthspanSeries.pace, value: p.pace))
            // The margin travels WITH the pace, keyed to the same day. A pace read back without it cannot
            // tell a real change from noise, and a dial that cannot tell will state a direction the data
            // does not support.
            out.append(MetricPoint(day: dayKey, key: HealthspanSeries.paceMargin, value: p.paceMargin))
            out.append(MetricPoint(day: dayKey, key: HealthspanSeries.projectedBodyAge, value: p.projectedBodyAge))
        }
        return out
    }

    /// Points for every day in `fromDay...toDay`.
    nonisolated static func healthspanPoints(history: HealthspanHistory, fromDay: Int, toDay: Int,
                                             age: Double, sex: String,
                                             profileWeightKg: Double?) -> [MetricPoint] {
        guard fromDay <= toDay else { return [] }
        let fmt = healthspanDayFormatter()
        return (fromDay...toDay).flatMap { day in
            healthspanPoints(history: history, endDay: day, dayKey: healthspanDayKey(day, fmt),
                             age: age, sex: sex, profileWeightKg: profileWeightKg)
        }
    }

    nonisolated static func healthspanDayFormatter() -> DateFormatter {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt
    }

    /// The "yyyy-MM-dd" key of a day index — the inverse of `PaceOfAgingEngine.dayIndex`.
    nonisolated static func healthspanDayKey(_ index: Int, _ fmt: DateFormatter) -> String {
        fmt.string(from: Date(timeIntervalSince1970: TimeInterval(index) * 86_400))
    }

    /// Per-day zone doses from the two stored heart-rate-reserve series, keyed by day index. A day with
    /// either series present is observed; the other side of a pair defaults to 0, since the day scan
    /// writes both or neither.
    nonisolated static func healthspanZones(moderate: [MetricPoint], vigorous: [MetricPoint])
        -> [Int: (moderate: Double, vigorous: Double)] {
        var out: [Int: (moderate: Double, vigorous: Double)] = [:]
        for p in moderate { if let i = PaceOfAgingEngine.dayIndex(p.day) { out[i] = (p.value, out[i]?.vigorous ?? 0) } }
        for p in vigorous { if let i = PaceOfAgingEngine.dayIndex(p.day) { out[i] = (out[i]?.moderate ?? 0, p.value) } }
        return out
    }

    /// `(day, value)` points as a day-index dictionary, the last value winning on a duplicate day.
    nonisolated static func healthspanByIndex(_ points: [(day: String, value: Double)]) -> [Int: Double] {
        var out: [Int: Double] = [:]
        for p in points { if let i = PaceOfAgingEngine.dayIndex(p.day) { out[i] = p.value } }
        return out
    }

    /// Load the history the resolver needs and write the Healthspan points for this device.
    ///
    /// `fresh` carries this pass's just-scored days and zone/strength minutes, which win over their
    /// persisted copies (the persist of this pass may not be readable yet on every path). Re-derives the
    /// whole history once when the stored model marker is older than `HealthspanSeries.modelVersion`;
    /// otherwise refreshes the last `HealthspanSeries.refreshDays`.
    static func recomputeHealthspan(store: WhoopStore, repo: Repository, computedId: String,
                                    newestDay: String, age: Double, sex: String, profileWeightKg: Double?,
                                    freshDays: [DailyMetric],
                                    freshZones: [String: (moderate: Double, vigorous: Double)],
                                    freshStrength: [String: Double],
                                    tzOffset: Int) async {
        guard let newest = PaceOfAgingEngine.dayIndex(newestDay) else { return }
        let marker = (try? await store.metricSeries(deviceId: computedId, key: HealthspanSeries.modelKey,
                                                    from: HealthspanSeries.modelDay,
                                                    to: HealthspanSeries.modelDay))?.last?.value ?? 0
        let rederive = marker < HealthspanSeries.modelVersion
        let outputDays = rederive ? HealthspanSeries.rederiveDays : HealthspanSeries.refreshDays
        // The oldest window read is the six-month baseline of the oldest output day, plus the evening
        // before its first night (the regularity pair).
        let readDays = outputDays + PaceOfAgingEngine.baselineWindowDays + 1
        let fmt = healthspanDayFormatter()
        let fromKey = Self.healthspanDayKey(newest - readDays, fmt)

        var history = HealthspanHistory()
        for d in await repo.dailyMetrics(fromDay: fromKey, toDay: newestDay) {
            if let i = PaceOfAgingEngine.dayIndex(d.day) { history.days[i] = d }
        }
        for d in freshDays { if let i = PaceOfAgingEngine.dayIndex(d.day) { history.days[i] = d } }

        let storedModerate = (try? await store.metricSeries(deviceId: computedId, key: HealthspanSeries.zoneModerate,
                                                            from: fromKey, to: newestDay)) ?? []
        let storedVigorous = (try? await store.metricSeries(deviceId: computedId, key: HealthspanSeries.zoneVigorous,
                                                            from: fromKey, to: newestDay)) ?? []
        history.zones = Self.healthspanZones(moderate: storedModerate, vigorous: storedVigorous)
        for (day, dose) in freshZones { if let i = PaceOfAgingEngine.dayIndex(day) { history.zones[i] = dose } }

        let storedStrength = (try? await store.metricSeries(deviceId: computedId, key: HealthspanSeries.strength,
                                                            from: fromKey, to: newestDay)) ?? []
        history.strength = Self.healthspanByIndex(storedStrength.map { ($0.day, $0.value) })
        for (day, minutes) in freshStrength { if let i = PaceOfAgingEngine.dayIndex(day) { history.strength[i] = minutes } }

        // VO₂max: the strap's own weekly estimate, or an imported reading, which is independent evidence.
        for (i, v) in Self.healthspanByIndex(await repo.exploreSeries(key: "vo2max_est", source: "my-whoop",
                                                                     days: readDays + 2)) {
            history.vo2max[i] = (v, .strap)
        }
        for (i, v) in Self.healthspanByIndex(await repo.exploreSeries(key: "vo2max", source: "apple-health",
                                                                     days: readDays + 2)) where v > 0 {
            history.vo2max[i] = (v, .external)
        }
        history.leanMass = Self.healthspanByIndex(await repo.exploreSeries(key: "lean_mass", source: "apple-health",
                                                                          days: readDays + 2)).filter { $0.value > 0 }
        history.weight = Self.healthspanByIndex(await repo.exploreSeries(key: "weight", source: "apple-health",
                                                                        days: readDays + 2)).filter { $0.value > 0 }

        let sessions = await repo.allSleepSessions(days: readDays + 2).compactMap {
            SleepRegularity.session(startTs: $0.effectiveStartTs, endTs: $0.endTs, stagesJSON: $0.stagesJSON)
        }
        let profileWeight = profileWeightKg
        let first = newest - outputDays + 1
        // The heavy part — SRI epochs and one engine run per window per day — off the main actor.
        let points = await Task.detached(priority: .utility) { [history] in
            var h = history
            h.sriAgreement = SleepRegularity.dailyAgreement(sessions: sessions, tzOffsetSec: tzOffset)
            return Self.healthspanPoints(history: h, fromDay: first, toDay: newest,
                                         age: age, sex: sex, profileWeightKg: profileWeight)
        }.value

        let fromOut = rederive ? "0000-01-01" : Self.healthspanDayKey(first, fmt)
        // A re-derivation also clears the model-1 rows: they were keyed to Saturdays, so the new daily
        // points would not overwrite all of them, and a stale Saturday would splice the old model back in.
        let written = (try? await store.replaceMetricSeries(points, deviceId: computedId,
                                                            keys: HealthspanSeries.allKeys,
                                                            from: fromOut, to: "9999-12-31")) != nil
        // Marked only once the rows landed: a failed write leaves the marker old, so the next pass retries.
        if rederive, written {
            _ = try? await store.upsertMetricSeries(
                [MetricPoint(day: HealthspanSeries.modelDay, key: HealthspanSeries.modelKey,
                             value: HealthspanSeries.modelVersion)], deviceId: computedId)
        }
    }
}
