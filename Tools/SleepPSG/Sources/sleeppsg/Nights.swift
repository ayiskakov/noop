import Foundation
import StrandAnalytics
import WhoopProtocol

// Nights — score the shipped V2 and V3 stagers over cohorts in the `Tools/SleepTrain` night format.
//
// `Tools/SleepTrain` prepares each PSG cohort (Wearanize+, sleep-accel, DREAMT) as a directory of per-night
// CSV files on the PSG clock: `{id}_grav.csv`, `{id}_hr.csv`, `{id}_rr.csv`, `{id}_truth.csv`. This section
// replays both shipped stagers over them, exactly as the app calls them, in two ways per night:
//
//   window — inside the sleep window `SleepStager.bandSleepWindow` would allow, emulated from the PSG
//            hypnogram with the same persist / grace rule (the strap's band plays that role in the app);
//   span   — over the whole scored span, as when the band gives no window.
//
// Every scored epoch counts, and an epoch the stager leaves outside its window is wake. The V3 rows are the
// in-repo check on `Tools/SleepTrain/train.py`'s numbers: on a cohort the model never trained on (DREAMT) the
// two must agree, since this is the Swift port and that is the Python reference. On a cohort V3 WAS trained
// on (Wearanize+, sleep-accel) its row here is in-sample and flatters it; `train.py`'s cross-validated rows
// are the honest figures there.

struct NightSubject {
    let id: String
    let start: Int
    let end: Int
    let grav: [GravitySample]
    let hr: [HRSample]
    let rr: [RRInterval]
    /// One label per epoch of `[start, end)`, the scored span; nil = unscored.
    let truth: [String?]
    let window: (from: Int, to: Int)?
}

enum Nights {
    /// A multiple of 30, so night-format second 0 lands on the stagers' wall-clock epoch grid.
    static let timeBase = 1_699_999_980
    static let bandPersist = 10
    static let bandGrace = 10

    static func rows(_ path: String) -> [[Substring]] {
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").dropFirst().map { $0.split(separator: ",") }
    }

    static func load(dir: String) -> [NightSubject] {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasSuffix("_truth.csv") }.sorted()
        var out = [NightSubject?](repeating: nil, count: files.count)
        out.withUnsafeMutableBufferPointer { buf in
            let dst = buf
            DispatchQueue.concurrentPerform(iterations: files.count) { i in
                dst[i] = loadOne(dir: dir, id: String(files[i].dropLast("_truth.csv".count)))
            }
        }
        return out.compactMap { $0 }
    }

    static func loadOne(dir: String, id: String) -> NightSubject? {
        let labels = rows("\(dir)/\(id)_truth.csv").map { $0.first.map(String.init) ?? "none" }
        guard let a = labels.firstIndex(where: { $0 != "none" }),
              let b = labels.lastIndex(where: { $0 != "none" }) else { return nil }
        let truth: [String?] = labels[a...b].map { $0 == "none" ? nil : $0 }
        let grav = rows("\(dir)/\(id)_grav.csv").compactMap { r -> GravitySample? in
            guard r.count >= 4, let t = Int(r[0]), let x = Double(r[1]), let y = Double(r[2]), let z = Double(r[3])
            else { return nil }
            return GravitySample(ts: timeBase + t, x: x, y: y, z: z)
        }
        let hr = rows("\(dir)/\(id)_hr.csv").compactMap { r -> HRSample? in
            guard r.count >= 2, let t = Int(r[0]), let v = Int(r[1]) else { return nil }
            return HRSample(ts: timeBase + t, bpm: v)
        }
        let rr = rows("\(dir)/\(id)_rr.csv").compactMap { r -> RRInterval? in
            guard r.count >= 2, let t = Int(r[0]), let v = Int(r[1]) else { return nil }
            return RRInterval(ts: timeBase + t, rrMs: v)
        }
        let start = timeBase + 30 * a, end = timeBase + 30 * (b + 1)
        let window = bandWindow(truth.map { $0 == "light" || $0 == "deep" || $0 == "rem" })
            .map { (from: start + 30 * $0.lowerBound, to: start + 30 * $0.upperBound) }
        return NightSubject(id: id, start: start, end: end, grav: grav, hr: hr, rr: rr, truth: truth, window: window)
    }

    /// `SleepStager.bandSleepWindow`'s rule on a per-epoch asleep flag: the first and last runs of
    /// `bandPersist` asleep epochs, widened by `bandGrace` epochs each side.
    static func bandWindow(_ asleep: [Bool]) -> Range<Int>? {
        var run = 0, onset: Int?, final: Int?
        for i in asleep.indices {
            run = asleep[i] ? run + 1 : 0
            if run >= bandPersist { onset = i - bandPersist + 1; break }
        }
        run = 0
        for i in asleep.indices.reversed() {
            run = asleep[i] ? run + 1 : 0
            if run >= bandPersist { final = i + bandPersist - 1; break }
        }
        guard let o = onset, let f = final, o <= f else { return nil }
        return max(0, o - bandGrace)..<min(asleep.count, f + bandGrace + 1)
    }

    typealias Stager = (NightSubject, (from: Int, to: Int)?) -> [StageSegment]

    static let v2: Stager = { s, w in
        SleepStagerV2.stageSession(start: s.start, end: s.end, grav: s.grav, hr: s.hr, rr: s.rr, resp: [], sleepWindow: w)
    }
    static let v3: Stager = { s, w in
        SleepStagerV3.stageSession(start: s.start, end: s.end, grav: s.grav, hr: s.hr, rr: s.rr, resp: [], sleepWindow: w)
    }

    /// One report row: pooled kappa, mean per-night kappa, per-stage F1, pooled stage-share bias (pp) and the
    /// per-night minute bias of each stage with its 95 % limits of agreement.
    static func row(_ name: String, _ nights: [NightSubject], _ stager: Stager, windowed: Bool,
                    dump: inout [String]) -> String {
        var pooled = Confusion()
        var kappas: [Double] = [], minutes: [[Double]] = [[], [], [], []]
        var latencyBias: [String: [Double]] = ["deep": [], "rem": []], early: [String: Int] = ["deep": 0, "rem": 0]
        /// Minutes from the first sleep epoch to the first `stage` epoch.
        func first(_ labels: [String?], _ stage: String) -> Double? {
            guard let on = labels.firstIndex(where: { $0 != nil && $0 != "wake" }),
                  let f = labels.firstIndex(where: { $0 == stage }) else { return nil }
            return Double(f - on) / 2
        }
        for s in nights {
            let labels = epochLabels(stager(s, windowed ? s.window : nil), start: s.start, end: s.end)
            for stage in ["deep", "rem"] {
                let p = first(labels, stage)
                if let p = p, p < 5 { early[stage]! += 1 }
                if let p = p, let t = first(s.truth, stage) { latencyBias[stage]!.append(p - t) }
            }
            var c = Confusion()
            var counts = [[0, 0], [0, 0], [0, 0], [0, 0]]
            for (i, t) in s.truth.enumerated() {
                dump.append("\(name),\(s.id),\(i),\(t ?? "none"),\(labels[i])")
                guard let t = t else { continue }
                c.add(ref: t, pred: labels[i])
                counts[stageOrder.firstIndex(of: t)!][0] += 1
                counts[stageOrder.firstIndex(of: labels[i])!][1] += 1
            }
            pooled.merge(c)
            // Undefined (one class on both sides, or no scored epoch): out of the per-night mean, as
            // `Tools/SleepTrain/train.py`'s summary leaves it out.
            if !c.kappa.isNaN { kappas.append(c.kappa) }
            for k in 0..<4 { minutes[k].append(Double(counts[k][1] - counts[k][0]) / 2) }
        }
        let f1 = stageOrder.map { String(format: "%.2f", pooled.prf($0).f1) }.joined(separator: " / ")
        let total = Double(pooled.total)
        let share = stageOrder.indices.map { k -> String in
            let predK = (0..<4).reduce(0) { $0 + pooled.m[$1][k] }
            let truthK = pooled.m[k].reduce(0, +)
            return String(format: "%+.1f", Double(predK - truthK) / total * 100)
        }.joined(separator: " / ")
        let mins = minutes.map { String(format: "%+.0f ± %.0f", mean($0), 1.96 * sd($0)) }.joined(separator: " / ")
        let lat = ["deep", "rem"].map { String(format: "%+.0f (%d)", mean(latencyBias[$0]!), early[$0]!) }
            .joined(separator: " / ")
        return "| \(name) | \(nights.count) | \(String(format: "%.3f", pooled.kappa)) | "
            + "\(String(format: "%.3f", mean(kappas))) | \(f1) | \(share) | \(mins) | \(lat) |"
    }

    static func run(dirs: [String], dump path: String?) {
        print("""

        ================================================================================
        V3 — the shipped V2 and V3 stagers over Tools/SleepTrain night-format cohorts
        ================================================================================
        window = staged inside the band-style sleep window emulated from the PSG hypnogram, wake outside
        span   = the whole scored span staged
        V3 is in-sample on the cohorts it was trained on (Wearanize+, sleep-accel): quote Tools/SleepTrain's
        cross-validated figures for those, and these rows only for a cohort it never saw.

        | Stager, cohort, view | nights | kappa | mean night kappa | F1 wake / light / deep / rem | stage share bias pp | minute bias ± 1.96 SD wake / light / deep / rem | first deep / REM latency bias, min (nights < 5 min) |
        |---|---|---|---|---|---|---|---|
        """)
        var dump: [String] = ["row,night,epoch,truth,pred"]
        for dir in dirs {
            let nights = load(dir: dir)
            let cohort = (dir as NSString).lastPathComponent
            for (name, stager) in [("V2", v2), ("V3", v3)] {
                for windowed in [true, false] {
                    print(row("\(name) \(cohort) \(windowed ? "window" : "span")", nights, stager,
                              windowed: windowed, dump: &dump))
                }
            }
        }
        if let path = path {
            try? dump.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
