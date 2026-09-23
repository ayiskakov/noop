import Foundation
import StrandAnalytics
import WhoopStore

// ResilienceLoader.swift — the one funnel the Experimental Resilience section reads.
//
// Every Resilience readout (the hero, the three signal chips, the knocks, the trend and σ charts) comes
// from ONE `ResilienceSnapshot`, built here from `repo.dailyMetrics` and the pure `ResilienceEngine`.
// Nothing is persisted: the computation is cheap enough to redo on each refresh, and Resilience feeds no
// other score, so there is no stored row for a second reader to disagree with.
//
// The rolling trend is computed on demand (the detail screen asks for it), but its newest point is the
// snapshot's own headline result, passed through rather than recomputed, so the chart's last point and
// the hero cannot disagree.

/// The Settings toggle's key. Default OFF: the section is Experimental.
enum ResiliencePrefs {
    static let enabledKey = "noop.resilienceEnabled"
}

/// One signal's current readout.
struct ResilienceReadout: Equatable, Sendable {
    let signal: ResilienceEngine.Signal
    /// The window's last day (a `PaceOfAgingEngine.dayIndex`).
    let endDay: Int
    /// Nil only when the window holds no usable day at all.
    let result: ResilienceEngine.Result?
    /// Knocks in the same window, oldest first.
    let knocks: [ResilienceEngine.Knock]
    /// Every reading the loader holds for this signal, so the trend reads the same days.
    let series: [ResilienceEngine.DayValue]

    /// Observed days in the window (0 with no data).
    var observedDays: Int { result?.observedDays ?? 0 }
}

struct ResilienceSnapshot: Sendable {
    let readouts: [ResilienceReadout]

    func readout(_ signal: ResilienceEngine.Signal) -> ResilienceReadout? {
        readouts.first { $0.signal == signal }
    }
}

/// One point of the rolling trend.
struct ResilienceTrendPoint: Sendable, Identifiable {
    let endDay: Int
    let estimate: ResilienceEngine.Estimate
    var id: Int { endDay }
    var date: Date { ResilienceLoader.date(endDay) }
}

enum ResilienceLoader {

    /// How far back the trend reaches, and the spacing of its points, days.
    static let trendDays = 364
    static let trendStepDays = 14

    /// Loads the three signals' current readouts.
    @MainActor
    static func load(repo: Repository, now: Date = Date()) async -> ResilienceSnapshot {
        let today = todayIndex(now)
        let span = ResilienceEngine.windowDays + ResilienceEngine.knockBaselineDays + trendDays
        let fmt = IntelligenceEngine.healthspanDayFormatter()
        let days = await repo.dailyMetrics(fromDay: IntelligenceEngine.healthspanDayKey(today - span, fmt),
                                           toDay: IntelligenceEngine.healthspanDayKey(today, fmt))
        return await Task.detached(priority: .userInitiated) {
            snapshot(days: days, today: today)
        }.value
    }

    /// The pure half of `load`.
    nonisolated static func snapshot(days: [DailyMetric], today: Int) -> ResilienceSnapshot {
        let readouts = ResilienceEngine.Signal.allCases.map { signal -> ResilienceReadout in
            let values = series(days, signal: signal)
            let end = endDay(signal, today: today)
            return ResilienceReadout(signal: signal, endDay: end,
                                     result: ResilienceEngine.analyze(series: values, signal: signal, endDay: end),
                                     knocks: ResilienceEngine.knocks(series: values, signal: signal, endDay: end),
                                     series: values)
        }
        return ResilienceSnapshot(readouts: readouts)
    }

    /// The rolling trend for one readout: one estimate every `trendStepDays` over `trendDays`, oldest
    /// first. The newest point is the readout's own result. Windows still collecting are left out.
    static func trend(_ readout: ResilienceReadout) async -> [ResilienceTrendPoint] {
        let earlier = trendEndDays(readout.endDay).dropLast()
        let computed = await withTaskGroup(of: ResilienceTrendPoint?.self) { group in
            for end in earlier {
                group.addTask(priority: .userInitiated) {
                    ResilienceEngine.analyze(series: readout.series, signal: readout.signal, endDay: end)?
                        .estimate.map { ResilienceTrendPoint(endDay: end, estimate: $0) }
                }
            }
            var out: [ResilienceTrendPoint] = []
            for await point in group { if let point { out.append(point) } }
            return out
        }
        var points = computed.sorted { $0.endDay < $1.endDay }
        if let head = readout.result?.estimate {
            points.append(ResilienceTrendPoint(endDay: readout.endDay, estimate: head))
        }
        return points
    }

    /// The trend's window end days, oldest first, ending exactly at `endDay`.
    nonisolated static func trendEndDays(_ endDay: Int) -> [Int] {
        Array(stride(from: endDay, through: endDay - trendDays, by: -trendStepDays).reversed())
    }

    /// A signal's raw daily readings. Days without a reading are left out (missing, never zero).
    nonisolated static func series(_ days: [DailyMetric],
                                   signal: ResilienceEngine.Signal) -> [ResilienceEngine.DayValue] {
        days.compactMap { d in
            guard let index = PaceOfAgingEngine.dayIndex(d.day) else { return nil }
            let raw: Double?
            switch signal {
            case .steps:     raw = d.steps.map(Double.init)
            case .restingHR: raw = d.restingHr.map(Double.init)
            case .hrv:       raw = d.avgHrv
            }
            return raw.map { ResilienceEngine.DayValue(dayIndex: index, value: $0) }
        }
    }

    /// The last day a signal's window covers. Today's step total is still counting, so steps end
    /// yesterday; last night's resting HR and HRV are complete by morning, so those end today.
    nonisolated static func endDay(_ signal: ResilienceEngine.Signal, today: Int) -> Int {
        signal == .steps ? today - 1 : today
    }

    /// Today's day index, from the local calendar date.
    nonisolated static func todayIndex(_ now: Date) -> Int {
        PaceOfAgingEngine.dayIndex(Repository.localDayKey(now)) ?? Int(now.timeIntervalSince1970 / 86_400)
    }

    /// Local noon on a day index's calendar date. Day indices come from the local calendar date, so the
    /// label must be built in the local zone too: noon UTC is already the next day from UTC+12 onwards.
    nonisolated static func date(_ dayIndex: Int, calendar: Calendar = .current) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        var parts = utc.dateComponents([.year, .month, .day],
                                       from: Date(timeIntervalSince1970: Double(dayIndex) * 86_400))
        parts.hour = 12
        return calendar.date(from: parts) ?? Date(timeIntervalSince1970: (Double(dayIndex) + 0.5) * 86_400)
    }
}
