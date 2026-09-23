// healthspan_v2_twin.swift — regenerates
// Packages/StrandAnalytics/Tests/StrandAnalyticsTests/oracles/healthspan_v2.json.
//
//   SRC=Packages/StrandAnalytics/Sources/StrandAnalytics
//   swiftc -O $SRC/VitalityEngine.swift $SRC/PaceOfAgingEngine.swift $SRC/SleepRegularity.swift \
//       Tools/oracle-twins/healthspan_v2_twin.swift -o /tmp/hs_twin && /tmp/hs_twin \
//       > Packages/StrandAnalytics/Tests/StrandAnalyticsTests/oracles/healthspan_v2.json
//
import Foundation
// Oracle twin for healthspan_v2.json: compiled standalone with VitalityEngine.swift, PaceOfAgingEngine.swift
// and SleepRegularity.swift (`swiftc -O`), it prints every case's inputs AND outputs.
func stride_(_ a: Double, _ b: Double, _ s: Double) -> [Double] { Array(stride(from: a, through: b, by: s)) }
var curves: [[String: Any]] = []
func curve(_ name: String, _ params: [String: Any], _ xs: [Double], _ f: (Double) -> Double) {
    for x in xs { var d = params; d["curve"] = name; d["x"] = x; d["y"] = f(x); curves.append(d) }
}
for sex in ["male", "female"] {
    curve("rhr", ["sex": sex], stride_(40, 110, 5)) { VitalityEngine.restingHRLnHazard(bpm: $0, sex: sex) }
    curve("vo2maxTarget", ["sex": sex], stride_(15, 90, 5)) { VitalityEngine.vo2maxTarget(age: $0, sex: sex) }
    for age in [30.0, 60] {
        curve("leanmass", ["sex": sex, "age": age], stride_(50, 90, 2.5)) {
            VitalityEngine.leanMassLnHazard(percent: $0, age: age, sex: sex) }
    }
}
curve("vo2max", ["target": 44.0], stride_(15, 75, 2.5)) { VitalityEngine.vo2maxLnHazard(vo2max: $0, target: 44) }
curve("sleep", [:], stride_(2, 13, 0.25)) { VitalityEngine.sleepDurationLnHazard(hours: $0) }
curve("sri", [:], stride_(-20, 100, 5)) { VitalityEngine.sriLnHazard(sri: $0) }
curve("strength", [:], stride_(0, 240, 10)) { VitalityEngine.strengthLnHazard(minPerWeek: $0) }
for age in [18.0, 30, 50, 70, 85] {
    curve("moderate", ["age": age], stride_(0, 400, 20)) { VitalityEngine.moderateLnHazard(minPerWeek: $0, age: age) }
    curve("vigorous", ["age": age], stride_(0, 90, 3)) { VitalityEngine.vigorousLnHazard(minPerWeek: $0, age: age) }
    curve("steps", ["age": age], stride_(0, 15000, 500)) { VitalityEngine.stepsLnHazard(steps: $0, age: age) }
}

func encode(_ i: VitalityEngine.Inputs) -> [String: Any] {
    var d: [String: Any] = ["chronoAge": i.chronoAge, "vo2maxSource": i.vo2maxSource.rawValue]
    if let v = i.sex { d["sex"] = v }
    if let v = i.restingHR { d["restingHR"] = v }
    if let v = i.vo2max { d["vo2max"] = v }
    if let v = i.sleepHours { d["sleepHours"] = v }
    if let v = i.sleepRegularity { d["sleepRegularity"] = v }
    if let v = i.steps { d["steps"] = v }
    if let v = i.moderateMinPerWeek { d["moderateMinPerWeek"] = v }
    if let v = i.vigorousMinPerWeek { d["vigorousMinPerWeek"] = v }
    if let v = i.strengthMinPerWeek { d["strengthMinPerWeek"] = v }
    if let v = i.leanMassKg { d["leanMassKg"] = v }
    if let v = i.weightKg { d["weightKg"] = v }
    return d
}
let targetsM30 = VitalityEngine.Inputs(chronoAge: 30, sex: "male", restingHR: 60, vo2max: 44, sleepHours: 8,
    sleepRegularity: 70, steps: 8000, moderateMinPerWeek: 100, vigorousMinPerWeek: 10, strengthMinPerWeek: 40,
    leanMassKg: 64, weightKg: 80)
let targetsF45 = VitalityEngine.Inputs(chronoAge: 45, sex: "female", restingHR: 64,
    vo2max: VitalityEngine.vo2maxTarget(age: 45, sex: "female"), sleepHours: 7, sleepRegularity: 70, steps: 8000,
    moderateMinPerWeek: VitalityEngine.moderateTarget(age: 45), vigorousMinPerWeek: VitalityEngine.vigorousTarget(age: 45),
    strengthMinPerWeek: 40, leanMassKg: 65.5 * 0.655, weightKg: 65.5)
// Average US adults of 30 (NHANES-scale values: resting HR, accelerometer steps, device sleep, few meeting
// the strength guideline, FRIEND-median VO2max, DXA-scale lean fraction). These carry the calibration.
let avgM = VitalityEngine.Inputs(chronoAge: 30, sex: "male", restingHR: 68, vo2max: 40, sleepHours: 6.8,
    sleepRegularity: 62, steps: 5500, moderateMinPerWeek: 45, vigorousMinPerWeek: 3, strengthMinPerWeek: 15,
    leanMassKg: 62, weightKg: 86)
let avgF = VitalityEngine.Inputs(chronoAge: 30, sex: "female", restingHR: 73, vo2max: 32, sleepHours: 6.9,
    sleepRegularity: 62, steps: 4800, moderateMinPerWeek: 35, vigorousMinPerWeek: 1, strengthMinPerWeek: 8,
    leanMassKg: 45, weightKg: 77)
let athlete = VitalityEngine.Inputs(chronoAge: 40, sex: "male", restingHR: 48, vo2max: 55, vo2maxSource: .external,
    sleepHours: 7.8, sleepRegularity: 85, steps: 12000, moderateMinPerWeek: 250, vigorousMinPerWeek: 60,
    strengthMinPerWeek: 90, leanMassKg: 66, weightKg: 78)
let sedentary = VitalityEngine.Inputs(chronoAge: 55, sex: "female", restingHR: 82, vo2max: 22, sleepHours: 5.4,
    sleepRegularity: 40, steps: 2500, moderateMinPerWeek: 0, vigorousMinPerWeek: 0, strengthMinPerWeek: 0,
    leanMassKg: 40, weightKg: 85)
var strapVO2 = avgM; strapVO2.leanMassKg = nil
var externalVO2 = strapVO2; externalVO2.vo2maxSource = .external
var noRegularity = avgM; noRegularity.sleepRegularity = nil
let wearableOnly = VitalityEngine.Inputs(chronoAge: 35, sex: "male", restingHR: 62, sleepHours: 7.2,
    sleepRegularity: 74, steps: 9000, moderateMinPerWeek: 80, vigorousMinPerWeek: 12)
let older = VitalityEngine.Inputs(chronoAge: 68, sex: "male", restingHR: 58, vo2max: 30, sleepHours: 9.6,
    sleepRegularity: 78, steps: 6200, moderateMinPerWeek: 90, vigorousMinPerWeek: 4, strengthMinPerWeek: 45)
let tooFew = VitalityEngine.Inputs(chronoAge: 40, restingHR: 65, sleepHours: 7.5)

var engineCases: [[String: Any]] = []
for (id, i) in [("at-targets-male-30", targetsM30), ("at-targets-female-45", targetsF45),
                ("average-us-30-male", avgM), ("average-us-30-female", avgF), ("athlete-external-vo2", athlete),
                ("sedentary-55-female", sedentary), ("strap-vo2-folds-into-rhr", strapVO2),
                ("external-vo2-scores-alone", externalVO2), ("no-regularity-full-duration", noRegularity),
                ("wearable-only", wearableOnly), ("older-long-sleeper", older), ("too-few-factors", tooFew)] {
    var d: [String: Any] = ["id": id, "inputs": encode(i)]
    guard let r = VitalityEngine.compute(i) else { d["nil"] = true; engineCases.append(d); continue }
    d["bodyAge"] = r.bodyAge; d["vitality"] = r.vitality; d["deltaYears"] = r.deltaYears
    d["lnHazardSum"] = r.lnHazardSum; d["factorsUsed"] = r.factorsUsed; d["lowerConfidence"] = r.lowerConfidence
    d["biggestLever"] = r.biggestLever?.key ?? NSNull()
    d["contributions"] = r.contributions.sorted { $0.key < $1.key }.map {
        ["key": $0.key, "domain": $0.domain.rawValue, "unit": $0.unit, "value": $0.value, "target": $0.target,
         "lnHazard": $0.lnHazard, "deltaYears": $0.deltaYears!] as [String: Any]
    }
    engineCases.append(d)
}

// SRI on synthetic schedules. Day 20000 ≈ 2024-10; tz offset +3 h.
let tz = 10_800
func night(_ day: Int, _ bedHour: Double, _ hours: Double, wake: [(Double, Double)] = []) -> SleepRegularity.Session {
    let midnight = Double((day + 1) * 86_400 - tz)          // local midnight ending `day`
    let start = midnight + (bedHour - 24) * 3600
    return SleepRegularity.Session(start: start, end: start + hours * 3600,
        wake: wake.map { SleepRegularity.Span(start: start + $0.0 * 3600, end: start + $0.1 * 3600) })
}
let d0 = 20000
var sriCases: [[String: Any]] = []
func sriCase(_ id: String, _ sessions: [SleepRegularity.Session]) {
    var d: [String: Any] = ["id": id, "tzOffsetSec": tz,
        "sessions": sessions.map { s in ["start": s.span.start, "end": s.span.end,
            "wake": s.wake.map { ["start": $0.start, "end": $0.end] }] as [String: Any] }]
    let a = SleepRegularity.dailyAgreement(sessions: sessions, tzOffsetSec: tz)
    d["pairs"] = a.count
    d["sri"] = SleepRegularity.index(sessions: sessions, tzOffsetSec: tz) ?? NSNull()
    sriCases.append(d)
}
sriCase("identical-23-to-07", (0..<14).map { night(d0 + $0, 23, 8) })
sriCase("alternating-23-and-03", (0..<14).map { night(d0 + $0, $0 % 2 == 0 ? 23 : 27, 8) })
sriCase("drifting-one-hour-a-day", (0..<10).map { night(d0 + $0, 22 + Double($0), 8) })
sriCase("unworn-nights-are-skipped", (0..<14).filter { $0 % 4 != 3 }.map { night(d0 + $0, 23, 8) })
sriCase("wake-bout-every-other-night", (0..<14).map {
    night(d0 + $0, 23, 8, wake: $0 % 2 == 0 ? [(3, 4)] : []) })
sriCase("too-few-pairs", (0..<5).map { night(d0 + $0, 23, 8) })
sriCase("weekend-shift", (0..<21).map { night(d0 + $0, $0 % 7 >= 5 ? 25 : 23, $0 % 7 >= 5 ? 9 : 7.5) })

// Pace projections.
var paceCases: [[String: Any]] = []
func paceCase(_ id: String, _ base: VitalityEngine.Inputs, _ recent: VitalityEngine.Inputs,
              _ windows: [VitalityEngine.Inputs]) {
    var d: [String: Any] = ["id": id, "baseline": encode(base), "recent": encode(recent),
                            "monthlyWindows": windows.map(encode)]
    guard let p = PaceOfAgingEngine.project(baseline: base, recent: recent, monthlyWindows: windows) else {
        d["nil"] = true; paceCases.append(d); return
    }
    d["pace"] = p.pace; d["currentBodyAge"] = p.currentBodyAge; d["projectedBodyAge"] = p.projectedBodyAge
    d["paceMargin"] = p.paceMargin; d["isSteady"] = p.isSteady; d["lowerConfidence"] = p.lowerConfidence
    d["comparedKeys"] = p.comparedKeys
    paceCases.append(d)
}
func with(_ i: VitalityEngine.Inputs, _ f: (inout VitalityEngine.Inputs) -> Void) -> VitalityEngine.Inputs { var c = i; f(&c); return c }
let months = (0..<6).map { k in with(avgM) { $0.steps = 5500 + Double(k % 2 == 0 ? 300 : -300); $0.restingHR = 68 + Double(k % 3) - 1 } }
paceCase("steady-no-windows", avgM, avgM, [])
paceCase("steady-six-windows", avgM, avgM, months)
paceCase("improving-recent-month", avgM, with(avgM) { $0.steps = 9000; $0.moderateMinPerWeek = 120; $0.vigorousMinPerWeek = 15 }, months)
paceCase("worsening-recent-month", avgM, with(avgM) { $0.sleepHours = 5.5; $0.sleepRegularity = 45; $0.steps = 3000 }, months)
paceCase("new-lean-mass-is-not-aging", with(avgM) { $0.leanMassKg = nil }, avgM, [])
paceCase("dropped-driver-is-not-aging", avgM, with(avgM) { $0.strengthMinPerWeek = nil }, months)
paceCase("extreme-worsening-clamps", athlete, sedentary, [])
paceCase("extreme-improvement-clamps", sedentary, athlete, [])
paceCase("two-windows-use-the-prior", avgM, with(avgM) { $0.steps = 7000 }, Array(months.prefix(2)))
paceCase("too-few-shared-drivers", VitalityEngine.Inputs(chronoAge: 30, restingHR: 60, sleepHours: 7, steps: 8000),
         VitalityEngine.Inputs(chronoAge: 30, sleepRegularity: 70, moderateMinPerWeek: 50, strengthMinPerWeek: 40), [])

let root: [String: Any] = [
    "schemaVersion": 2,
    "note": "Generated by compiling VitalityEngine.swift, PaceOfAgingEngine.swift and SleepRegularity.swift standalone (swiftc -O) with the healthspan v2 oracle twin, and printing every case's inputs and outputs verbatim. Regenerate only for a deliberate model change, and say why in the commit.",
    "curves": curves, "engineCases": engineCases, "sriCases": sriCases, "paceCases": paceCases]
let data = try! JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
print(String(data: data, encoding: .utf8)!)
