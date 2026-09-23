import Foundation
import XCTest
@testable import StrandAnalytics

/// Pins `VitalityEngine`, `PaceOfAgingEngine.project` and `SleepRegularity` against a committed oracle
/// produced by compiling all three sources standalone (`swiftc -O`, `Tools/oracle-twins/
/// healthspan_v2_twin.swift`) and printing every case's inputs and outputs verbatim — the stored-data rule
/// in AGENTS.md: a helper whose output reaches a stored row or a score is verified by having RUN it over a
/// spread of cases, not by reading it. Body Age, the pace and each driver's years persist to
/// `metricSeries`, so a coefficient changing silently would rewrite history that is already on disk.
///
/// The v2 model replaced v1's oracle wholesale (a deliberate model change, not a drift): the referent
/// moved from "average for your age" to "meeting health targets", years moved from 8/ln2 · ln(HR) to
/// 10 · ln(HR), HRV stopped being scored, and sleep regularity became the timing-based SRI.
final class HealthspanOracleTests: XCTestCase {

    private func loadOracle() throws -> [String: Any] {
        let relative = "Packages/StrandAnalytics/Tests/StrandAnalyticsTests/oracles/healthspan_v2.json"
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: candidate))
                let root = try XCTUnwrap(object as? [String: Any])
                XCTAssertEqual(root["schemaVersion"] as? Int, 2)
                XCTAssertFalse(try XCTUnwrap(root["note"] as? String).isEmpty)
                return root
            }
            directory = directory.deletingLastPathComponent()
        }
        XCTFail("committed oracle \(relative) not found above \(#filePath)")
        throw CocoaError(.fileNoSuchFile)
    }

    private func number(_ d: [String: Any], _ key: String) throws -> Double {
        try XCTUnwrap(d[key] as? NSNumber, key).doubleValue
    }

    private func optional(_ d: [String: Any], _ key: String) -> Double? {
        (d[key] as? NSNumber)?.doubleValue
    }

    private func inputs(_ d: [String: Any]) throws -> VitalityEngine.Inputs {
        VitalityEngine.Inputs(
            chronoAge: try number(d, "chronoAge"), sex: d["sex"] as? String,
            restingHR: optional(d, "restingHR"), vo2max: optional(d, "vo2max"),
            vo2maxSource: VitalityEngine.VO2maxSource(rawValue: d["vo2maxSource"] as? String ?? "") ?? .strap,
            sleepHours: optional(d, "sleepHours"), sleepRegularity: optional(d, "sleepRegularity"),
            steps: optional(d, "steps"), moderateMinPerWeek: optional(d, "moderateMinPerWeek"),
            vigorousMinPerWeek: optional(d, "vigorousMinPerWeek"),
            strengthMinPerWeek: optional(d, "strengthMinPerWeek"),
            leanMassKg: optional(d, "leanMassKg"), weightKg: optional(d, "weightKg"))
    }

    /// Every curve over its whole domain.
    func testCurvesMatchTheFixture() throws {
        let cases = try XCTUnwrap(try loadOracle()["curves"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 665)
        for c in cases {
            let name = try XCTUnwrap(c["curve"] as? String)
            let x = try number(c, "x"), want = try number(c, "y")
            let sex = c["sex"] as? String
            let age = optional(c, "age") ?? 0
            let got: Double
            switch name {
            case "rhr":          got = VitalityEngine.restingHRLnHazard(bpm: x, sex: sex)
            case "vo2maxTarget": got = VitalityEngine.vo2maxTarget(age: x, sex: sex)
            case "vo2max":       got = VitalityEngine.vo2maxLnHazard(vo2max: x, target: try number(c, "target"))
            case "leanmass":     got = VitalityEngine.leanMassLnHazard(percent: x, age: age, sex: sex)
            case "sleep":        got = VitalityEngine.sleepDurationLnHazard(hours: x)
            case "sri":          got = VitalityEngine.sriLnHazard(sri: x)
            case "strength":     got = VitalityEngine.strengthLnHazard(minPerWeek: x)
            case "moderate":     got = VitalityEngine.moderateLnHazard(minPerWeek: x, age: age)
            case "vigorous":     got = VitalityEngine.vigorousLnHazard(minPerWeek: x, age: age)
            case "steps":        got = VitalityEngine.stepsLnHazard(steps: x, age: age)
            default: XCTFail("unknown curve \(name)"); continue
            }
            XCTAssertEqual(got, want, accuracy: 1e-12, "\(name) @ \(x) \(sex ?? "") \(age)")
        }
    }

    func testEngineCasesMatchTheFixture() throws {
        let cases = try XCTUnwrap(try loadOracle()["engineCases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 12)
        for fixture in cases {
            let id = try XCTUnwrap(fixture["id"] as? String)
            let i = try inputs(try XCTUnwrap(fixture["inputs"] as? [String: Any], id))
            guard (fixture["nil"] as? Bool) != true else {
                XCTAssertNil(VitalityEngine.compute(i), id); continue
            }
            let r = try XCTUnwrap(VitalityEngine.compute(i), id)
            XCTAssertEqual(r.bodyAge, try number(fixture, "bodyAge"), accuracy: 1e-9, id)
            XCTAssertEqual(r.vitality, try number(fixture, "vitality"), accuracy: 1e-9, id)
            XCTAssertEqual(r.deltaYears, try number(fixture, "deltaYears"), accuracy: 1e-9, id)
            XCTAssertEqual(r.lnHazardSum, try number(fixture, "lnHazardSum"), accuracy: 1e-9, id)
            XCTAssertEqual(r.factorsUsed, fixture["factorsUsed"] as? Int, id)
            XCTAssertEqual(r.lowerConfidence, fixture["lowerConfidence"] as? Bool, id)
            XCTAssertEqual(r.biggestLever?.key, fixture["biggestLever"] as? String, id)

            let wanted = try XCTUnwrap(fixture["contributions"] as? [[String: Any]], id)
            let got = r.contributions.sorted { $0.key < $1.key }
            XCTAssertEqual(got.count, wanted.count, id)
            for (c, want) in zip(got, wanted) {
                let label = "\(id).\(c.key)"
                XCTAssertEqual(c.key, want["key"] as? String, label)
                XCTAssertEqual(c.domain.rawValue, want["domain"] as? String, label)
                XCTAssertEqual(c.unit, want["unit"] as? String, label)
                XCTAssertEqual(c.value, try number(want, "value"), accuracy: 1e-9, label)
                XCTAssertEqual(c.target, try number(want, "target"), accuracy: 1e-9, label)
                XCTAssertEqual(c.lnHazard, try number(want, "lnHazard"), accuracy: 1e-12, label)
                XCTAssertEqual(try XCTUnwrap(c.deltaYears, label),
                               try number(want, "deltaYears"), accuracy: 1e-9, label)
            }
        }
    }

    /// The two calibration people, asserted by name so a regenerated oracle cannot quietly move them:
    /// an average US 30-year-old man reads about +6 years and a woman about +7.5 (WHOOP white paper,
    /// Table 2), and a person meeting every target reads exactly their age.
    func testCalibrationPeople() throws {
        let cases = try XCTUnwrap(try loadOracle()["engineCases"] as? [[String: Any]])
        func offset(_ id: String) throws -> Double {
            let c = try XCTUnwrap(cases.first { $0["id"] as? String == id }, id)
            return try number(c, "bodyAge") - number(try XCTUnwrap(c["inputs"] as? [String: Any]), "chronoAge")
        }
        XCTAssertEqual(try offset("average-us-30-male"), 6.0, accuracy: 0.5)
        XCTAssertEqual(try offset("average-us-30-female"), 7.5, accuracy: 0.5)
        XCTAssertEqual(try offset("at-targets-male-30"), 0, accuracy: 1e-9)
        XCTAssertEqual(try offset("at-targets-female-45"), 0, accuracy: 1e-9)
    }

    func testSleepRegularityCasesMatchTheFixture() throws {
        let cases = try XCTUnwrap(try loadOracle()["sriCases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 7)
        for fixture in cases {
            let id = try XCTUnwrap(fixture["id"] as? String)
            let tz = try XCTUnwrap(fixture["tzOffsetSec"] as? Int, id)
            let sessions = try XCTUnwrap(fixture["sessions"] as? [[String: Any]], id).map { s in
                SleepRegularity.Session(
                    start: try number(s, "start"), end: try number(s, "end"),
                    wake: try XCTUnwrap(s["wake"] as? [[String: Any]]).map {
                        SleepRegularity.Span(start: try number($0, "start"), end: try number($0, "end"))
                    })
            }
            XCTAssertEqual(SleepRegularity.dailyAgreement(sessions: sessions, tzOffsetSec: tz).count,
                           fixture["pairs"] as? Int, id)
            let got = SleepRegularity.index(sessions: sessions, tzOffsetSec: tz)
            if let want = optional(fixture, "sri") {
                XCTAssertEqual(try XCTUnwrap(got, id), want, accuracy: 1e-9, id)
            } else {
                XCTAssertNil(got, id)
            }
        }
    }

    func testPaceProjectionCasesMatchTheFixture() throws {
        let cases = try XCTUnwrap(try loadOracle()["paceCases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 10)
        for fixture in cases {
            let id = try XCTUnwrap(fixture["id"] as? String)
            let base = try inputs(try XCTUnwrap(fixture["baseline"] as? [String: Any], id))
            let recent = try inputs(try XCTUnwrap(fixture["recent"] as? [String: Any], id))
            let windows = try XCTUnwrap(fixture["monthlyWindows"] as? [[String: Any]], id).map(inputs)
            let p = PaceOfAgingEngine.project(baseline: base, recent: recent, monthlyWindows: windows)
            guard (fixture["nil"] as? Bool) != true else { XCTAssertNil(p, id); continue }
            let r = try XCTUnwrap(p, id)
            XCTAssertEqual(r.pace, try number(fixture, "pace"), accuracy: 1e-9, id)
            XCTAssertEqual(r.currentBodyAge, try number(fixture, "currentBodyAge"), accuracy: 1e-9, id)
            XCTAssertEqual(r.projectedBodyAge, try number(fixture, "projectedBodyAge"), accuracy: 1e-9, id)
            XCTAssertEqual(r.paceMargin, try number(fixture, "paceMargin"), accuracy: 1e-9, id)
            XCTAssertEqual(r.isSteady, fixture["isSteady"] as? Bool, id)
            XCTAssertEqual(r.lowerConfidence, fixture["lowerConfidence"] as? Bool, id)
            XCTAssertEqual(r.comparedKeys, fixture["comparedKeys"] as? [String], id)
        }
    }
}
