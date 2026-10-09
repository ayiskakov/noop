import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

/// W03-028: Rest is one number on every surface. The engine stores `sleep_performance` with the wearer's
/// personal need and consistency, and Today reads that stored series. The Sleep tab, the Sleep performance
/// series, Coupled and the Weekly Digest recomputed the composite with the population defaults instead,
/// so the same night read two different scores.
@MainActor
final class RestOneReadoutTests: XCTestCase {
    private let day = "2026-06-20"

    /// A scored night whose stored Rest (personal need and consistency) differs from the default composite.
    private func makeRepo(storedRest: Double?) async throws -> Repository {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertDailyMetrics([
            DailyMetric(day: day, totalSleepMin: 420, efficiency: 0.9, deepMin: 60, remMin: 90, lightMin: 270,
                        disturbances: nil, restingHr: 52, avgHrv: 60, recovery: 70, strain: 10, exerciseCount: nil),
        ], deviceId: "my-whoop-noop")
        if let storedRest {
            _ = try await store.upsertMetricSeries([MetricPoint(day: day, key: "sleep_performance", value: storedRest)],
                                                   deviceId: "my-whoop-noop")
        }
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        await repo.refresh()
        return repo
    }

    private func todayRest(_ repo: Repository) async -> Double? {
        await repo.exploreSeries(key: "sleep_performance", source: "my-whoop").first { $0.day == day }?.value
    }

    func testEverySurfaceShowsTheStoredRest() async throws {
        let repo = try await makeRepo(storedRest: 84.5)
        let defaultComposite = try XCTUnwrap(AnalyticsEngine.Rest.composite(daily: try XCTUnwrap(repo.days.first)))
        XCTAssertNotEqual(defaultComposite, 84.5, accuracy: 0.5, "the fixture must tell the two readouts apart")

        let today = await todayRest(repo)
        XCTAssertEqual(today, 84.5)
        XCTAssertEqual(repo.restScore(forDay: day), today, "the Sleep tab hero and Coupled")
        let series = SleepModel.performanceSeries(days: repo.days, restByDay: repo.restByDay)
        XCTAssertEqual(series.series, [84.5], "the Sleep performance series")
        let digest = WeeklyDigestSource.restByDay(from: repo.days, restByDay: repo.restByDay)
        XCTAssertEqual(digest[day], today, "the Weekly Digest")
    }

    /// A day whose Rest the engine has not projected yet still resolves, to the same placeholder on every
    /// surface (#614).
    func testADayWithNoStoredRestResolvesToOnePlaceholder() async throws {
        let repo = try await makeRepo(storedRest: nil)
        let today = await todayRest(repo)
        XCTAssertNotNil(today)
        XCTAssertEqual(repo.restScore(forDay: day), today)
        XCTAssertEqual(SleepModel.performanceSeries(days: repo.days, restByDay: repo.restByDay).series, [today!])
    }

    /// The refresh-time map and Today's read must not be able to disagree on any day.
    func testRestByDayMatchesTodaysSeries() async throws {
        let repo = try await makeRepo(storedRest: 84.5)
        let today = await repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
        XCTAssertEqual(repo.restByDay, Dictionary(uniqueKeysWithValues: today.map { ($0.day, $0.value) }))
    }
}
