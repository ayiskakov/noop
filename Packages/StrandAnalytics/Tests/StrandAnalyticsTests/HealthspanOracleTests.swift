import Foundation
import XCTest
@testable import StrandAnalytics

/// Pins `VitalityEngine` and `PaceOfAgingEngine` against a committed oracle produced by compiling both
/// sources standalone (`swiftc -O`) and printing every value verbatim — the stored-data rule in AGENTS.md:
/// a helper whose output reaches a stored row or a score is verified by having RUN it over a spread of
/// cases, not by reading it. The Body Age and the pace both persist to `metricSeries`, so a coefficient or
/// a shrink changing silently would rewrite history that is already on disk.
final class HealthspanOracleTests: XCTestCase {

    private func loadOracle() throws -> [String: Any] {
        let relative = "Packages/StrandAnalytics/Tests/StrandAnalyticsTests/oracles/healthspan_oracle.json"
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: candidate))
                let root = try XCTUnwrap(object as? [String: Any])
                XCTAssertEqual(root["schemaVersion"] as? Int, 1)
                XCTAssertFalse(try XCTUnwrap(root["note"] as? String).isEmpty)
                return root
            }
            directory = directory.deletingLastPathComponent()
        }
        XCTFail("committed oracle \(relative) not found above \(#filePath)")
        throw CocoaError(.fileNoSuchFile)
    }

    private func number(_ d: [String: Any], _ key: String) throws -> Double {
        try XCTUnwrap(d[key] as? NSNumber).doubleValue
    }

    func testDoseResponseCurvesMatchTheFixture() throws {
        let cases = try XCTUnwrap(try loadOracle()["doseResponse"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 31)
        for fixture in cases {
            let curve = try XCTUnwrap(fixture["curve"] as? String)
            let minutes = try number(fixture, "minPerWeek")
            let want = try number(fixture, "lnHazard")
            let got: Double
            switch curve {
            case "moderate": got = VitalityEngine.moderateLnHazard(minPerWeek: minutes)
            case "vigorous": got = VitalityEngine.vigorousLnHazard(minPerWeek: minutes)
            case "strength": got = VitalityEngine.strengthLnHazard(minPerWeek: minutes)
            default: XCTFail("unknown curve \(curve)"); continue
            }
            XCTAssertEqual(got, want, accuracy: 1e-12, "\(curve) @ \(minutes) min/wk")
        }
    }

    func testFatFreeMassIndexMatchesTheFixture() throws {
        let cases = try XCTUnwrap(try loadOracle()["ffmi"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 7)
        for fixture in cases {
            let sex = try XCTUnwrap(fixture["sex"] as? String)
            let index = try number(fixture, "ffmi")
            XCTAssertEqual(VitalityEngine.ffmiCutoff(sex: sex),
                           try number(fixture, "cutoff"), accuracy: 1e-12, sex)
            XCTAssertEqual(VitalityEngine.ffmiLnHazard(ffmi: index, sex: sex),
                           try number(fixture, "lnHazard"), accuracy: 1e-12, "\(index) \(sex)")
        }
    }

    func testEngineCasesMatchTheFixture() throws {
        let cases = try XCTUnwrap(try loadOracle()["engineCases"] as? [[String: Any]])
        XCTAssertEqual(Set(cases.compactMap { $0["id"] as? String }),
                       Set(["all-at-reference", "six-at-reference", "healthy", "unhealthy",
                            "sedentary-one-activity-driver", "sedentary-four-activity-drivers",
                            "low-lean-mass"]))

        for fixture in cases {
            let id = try XCTUnwrap(fixture["id"] as? String)
            let result = try XCTUnwrap(VitalityEngine.compute(inputs(for: id)), id)
            XCTAssertEqual(result.bodyAge, try number(fixture, "bodyAge"), accuracy: 1e-9, id)
            XCTAssertEqual(result.vitality, try number(fixture, "vitality"), accuracy: 1e-9, id)
            XCTAssertEqual(result.deltaYears, try number(fixture, "deltaYears"), accuracy: 1e-9, id)
            XCTAssertEqual(result.lnHazardSum, try number(fixture, "lnHazardSum"), accuracy: 1e-9, id)
            XCTAssertEqual(result.factorsUsed, fixture["factorsUsed"] as? Int, id)
            XCTAssertEqual(result.lowerConfidence, fixture["lowerConfidence"] as? Bool, id)

            let wanted = try XCTUnwrap(fixture["contributions"] as? [[String: Any]], id)
            let got = result.contributions.sorted { $0.key < $1.key }
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

    func testPaceCasesMatchTheFixture() throws {
        let cases = try XCTUnwrap(try loadOracle()["paceCases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 9)
        for fixture in cases {
            let id = try XCTUnwrap(fixture["id"] as? String)
            let samples = paceSamples(for: id)
            XCTAssertEqual(PaceOfAgingEngine.usableSamples(samples).count,
                           fixture["usableSamples"] as? Int, id)

            guard (fixture["nil"] as? Bool) != true else {
                XCTAssertNil(PaceOfAgingEngine.compute(samples: samples), id)
                XCTAssertEqual(PaceOfAgingEngine.daysUntilReady(samples),
                               fixture["daysUntilReady"] as? Int, id)
                continue
            }
            let r = try XCTUnwrap(PaceOfAgingEngine.compute(samples: samples), id)
            XCTAssertEqual(r.pace, try number(fixture, "pace"), accuracy: 1e-9, id)
            XCTAssertEqual(r.slopeLnPerYear, try number(fixture, "slopeLnPerYear"), accuracy: 1e-12, id)
            XCTAssertEqual(r.standardErrorLnPerYear,
                           try number(fixture, "standardErrorLnPerYear"), accuracy: 1e-12, id)
            XCTAssertEqual(r.paceMargin, try number(fixture, "paceMargin"), accuracy: 1e-9, id)
            XCTAssertEqual(r.isSteady, fixture["isSteady"] as? Bool, id)
            XCTAssertEqual(r.samplesUsed, fixture["samplesUsed"] as? Int, id)
            XCTAssertEqual(r.lowerConfidence, fixture["lowerConfidence"] as? Bool, id)
        }
    }

    // MARK: - The inputs the oracle twin was run on, reproduced exactly

    private func inputs(for id: String) -> VitalityEngine.Inputs {
        let reference = VitalityEngine.Inputs(
            chronoAge: 40, restingHR: 65, vo2max: 45, expectedVO2max: 45,
            sleepHours: 7.5, sleepConsistency: 0.75, rmssd: 45, rmssdNorm: 45, steps: 7000,
            moderateMinPerWeek: 150, vigorousMinPerWeek: 75, strengthMinPerWeek: 30,
            leanMassKg: 60, heightCm: 180, sex: "male")
        let sedentaryOne = VitalityEngine.Inputs(
            chronoAge: 40, restingHR: 65, sleepHours: 7.5, sleepConsistency: 0.75, steps: 0)
        switch id {
        case "all-at-reference":
            return reference
        case "six-at-reference":
            var i = reference
            i.moderateMinPerWeek = nil; i.vigorousMinPerWeek = nil
            i.strengthMinPerWeek = nil; i.leanMassKg = nil; i.heightCm = nil
            return i
        case "healthy":
            return .init(chronoAge: 40, restingHR: 52, vo2max: 55.5, expectedVO2max: 45,
                         sleepHours: 7.5, sleepConsistency: 0.9, rmssd: 54, rmssdNorm: 45, steps: 11000)
        case "unhealthy":
            return .init(chronoAge: 40, restingHR: 80, vo2max: 34.5, expectedVO2max: 45,
                         sleepHours: 5.5, sleepConsistency: 0.5, rmssd: 31.5, rmssdNorm: 45, steps: 3000)
        case "sedentary-one-activity-driver":
            return sedentaryOne
        case "sedentary-four-activity-drivers":
            var i = sedentaryOne
            i.moderateMinPerWeek = 0; i.vigorousMinPerWeek = 0; i.strengthMinPerWeek = 0
            return i
        case "low-lean-mass":
            var i = reference
            i.leanMassKg = 52       // FFMI 16.0 at 180 cm — below the male cutoff
            return i
        default:
            XCTFail("unknown engine case \(id)")
            return reference
        }
    }

    private func paceSamples(for id: String) -> [PaceOfAgingEngine.Sample] {
        let signature = "hrv,rhr,sleep,steps"
        func drift(_ gompertzYearsPerYear: Double, _ days: Int = 90) -> [PaceOfAgingEngine.Sample] {
            (0..<days).map {
                PaceOfAgingEngine.Sample(
                    dayIndex: $0,
                    lnHazardSum: 0.20 + VitalityEngine.lnHazardPerYear
                        * gompertzYearsPerYear * Double($0) / PaceOfAgingEngine.daysPerYear,
                    factorSignature: signature)
            }
        }
        switch id {
        case "flat-90":                             return drift(0)
        case "worsening-one-gompertz-year-per-year":return drift(1)
        case "improving-half-year-per-year":        return drift(-0.5)
        case "noisy-flat":
            return (0..<90).map {
                PaceOfAgingEngine.Sample(dayIndex: $0,
                                         lnHazardSum: 0.20 + ($0 % 2 == 0 ? 0.05 : -0.05),
                                         factorSignature: signature)
            }
        case "short-span-60":                       return drift(0, 60)
        case "too-short-59":                        return drift(0, 59)
        case "signature-break-at-70":
            return (0..<90).map {
                PaceOfAgingEngine.Sample(dayIndex: $0, lnHazardSum: 0.20,
                                         factorSignature: $0 < 70 ? "hrv,rhr,sleep" : signature)
            }
        case "extreme-improvement-clamps":          return drift(-20)
        case "extreme-worsening-clamps":            return drift(20)
        default:
            XCTFail("unknown pace case \(id)")
            return []
        }
    }
}
