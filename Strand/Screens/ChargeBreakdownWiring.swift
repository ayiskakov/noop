import Foundation
import StrandAnalytics
import WhoopStore

// MARK: - Charge breakdown wiring (pure, testable)
//
// The fold-and-score wiring behind the "What shaped it" sheet, lifted out of the two views that had
// byte-identical private copies of it (TodayView.chargeBreakdown / CoupledView.chargeBreakdown). They
// differed only in which row they display and where their sleep-performance number comes from, both of
// which are inputs, so one function serves both.
//
// Extracted so it can be TESTED. Living inside a `View` struct as a private method meant the only way to
// exercise it was to render the view, so the iOS side of this path had no test at all while the Android
// twin did. Kotlin twin: `TodayScoring.recoveryChargeDrivers`.
//
// Pure: no SwiftUI state, no I/O, no store access. Nothing here invents a number. The drivers come from
// `RecoveryScorer.chargeDrivers` and the tier is SURFACED from `ScoreConfidence.charge` against the same
// folded HRV baseline the drivers scored with, so the header and the rows agree by construction.
enum ChargeBreakdownWiring {

    /// The ordered Charge driver rows for `row` plus its confidence tier, or nil when the night cannot honestly
    /// score (missing HRV or resting HR, or an HRV baseline that is not yet usable) so the sheet hides rather
    /// than showing fabricated rows.
    ///
    /// W03-030: the rows describe the stored Charge. When the engine still holds the drivers it scored the day
    /// with (`engineDrivers`, the rows the Intelligence screen shows), they are returned as they are. Otherwise
    /// each baseline is folded as the engine folds it since efa0bdcb: over the nights strictly BEFORE the day,
    /// from the HRV recalibration epoch for HRV and the Charge-wide epoch for resting HR and respiration. A
    /// whole-history fold included the night itself and every later one, so the sheet scored against a
    /// different baseline than the headline. Not mirrored: the engine's per-brand era cut on respiration,
    /// which is 0 on a WHOOP-only history.
    ///
    /// `sleepPerfPercent` is the Rest score on a 0-100 scale, divided by 100 here to match `AnalyticsEngine`'s
    /// `sleepPerf` form, so the Sleep row scores against the headline's own input.
    static func breakdown(days: [DailyMetric],
                          row: DailyMetric,
                          sleepPerfPercent: Double?,
                          hrvBaselineEpoch: Double = 0,
                          recoveryBaselineEpoch: Double = 0,
                          engineDrivers: [ChargeDriver]? = nil) -> (drivers: [ChargeDriver], confidence: ScoreConfidence)? {
        guard let hrv = row.avgHrv, let rhr = row.restingHr else { return nil }
        let keys = days.map(\.day)
        func prior(_ values: [Double?], _ cfg: MetricCfg, _ epoch: Double) -> BaselineState {
            Baselines.priorFold(values, dayKeys: keys, cfg: cfg, baselineEpoch: epoch).state(before: row.day)
        }
        let hrvBase = prior(days.map(\.avgHrv), Baselines.hrvCfg, hrvBaselineEpoch)
        guard hrvBase.usable else { return nil }
        let confidence = ScoreConfidence.charge(recovery: row.recovery, hrvBaseline: hrvBase)
        if let engineDrivers, !engineDrivers.isEmpty { return (engineDrivers, confidence) }
        let rhrBase = prior(days.map { $0.restingHr.map(Double.init) }, Baselines.restingHRCfg, recoveryBaselineEpoch)
        let respBase = prior(days.map(\.respRateBpm), Baselines.respCfg, recoveryBaselineEpoch)
        let drivers = RecoveryScorer.chargeDrivers(
            hrv: hrv, rhr: Double(rhr), resp: row.respRateBpm,
            hrvBaseline: hrvBase,
            rhrBaseline: rhrBase.usable ? rhrBase : nil,
            respBaseline: respBase.usable ? respBase : nil,
            sleepPerf: sleepPerfPercent.map { $0 / 100.0 },
            skinTempDev: row.skinTempDevC)
        return (drivers, confidence)
    }
}
