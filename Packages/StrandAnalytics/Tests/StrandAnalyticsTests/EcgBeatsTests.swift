import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// R-peak detection on synthetic R16-shaped recordings: several injected rates, both polarities, with
/// the baseline offset, drift and mains hum real captures carry. Recovering more than one rate is the
/// point — a detector that locks onto the record period would pass a single-rate test.
final class EcgBeatsTests: XCTestCase {

    /// Deterministic noise, so every run sees the same signal.
    private struct Lcg {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53) * 2 - 1
        }
    }

    /// `seconds` full records of a synthetic ECG at `bpm`, with ±3 % alternating R-R jitter. Returns the
    /// records and the injected R-peak times (seconds from the start).
    private func recording(bpm: Double, seconds: Int, polarity: Double = -1, hum: Double = 0.5,
                           quality: Int = 3, startIndex: Int = 1_000, ts0: Int = 1_790_000_000)
        -> (records: [EcgCandidateSample], rPeaks: [Double]) {
        let fs = EcgBeats.sampleRate
        let n = seconds * Int(fs)
        var peaks: [Double] = []
        var t = 0.4, k = 0
        while t < Double(seconds) - 0.2 {
            peaks.append(t)
            t += 60 / bpm * (k % 2 == 0 ? 1.03 : 0.97)
            k += 1
        }
        var noise = Lcg(state: UInt64(bpm * 1_000))
        let amplitude = 8_000.0
        var x = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let ti = Double(i) / fs
            var v = 40_000 + 15_000 * sin(2 * .pi * 0.3 * ti)          // offset and drift
            v += hum * amplitude * sin(2 * .pi * 50 * ti)               // mains
            v += 0.05 * amplitude * noise.next()
            for p in peaks where abs(ti - p) < 0.6 {
                let q = (ti - p) / 0.010, tw = (ti - p - 0.25) / 0.060
                v += polarity * amplitude * exp(-0.5 * q * q)           // QRS
                v += polarity * 0.3 * amplitude * exp(-0.5 * tw * tw)   // T wave
            }
            x[i] = v
        }
        let records = (0..<seconds).map { s in
            EcgCandidateSample(ts: ts0 + s,
                               samples: x[(s * 500)..<((s + 1) * 500)].map { Int($0.rounded()) },
                               recordIndex: startIndex + s, quality: quality)
        }
        return (records, peaks)
    }

    /// The rate the injected beats imply, by the same median rule the detector reports.
    private func injectedRate(_ peaks: [Double]) -> Double {
        let rr = zip(peaks.dropFirst(), peaks).map { ($0 - $1) * 1_000 }.sorted()
        let m = rr.count % 2 == 1 ? rr[rr.count / 2] : (rr[rr.count / 2 - 1] + rr[rr.count / 2]) / 2
        return 60_000 / m
    }

    func testRecoversSeveralInjectedRatesInEitherPolarity() {
        for bpm in [48.0, 75, 110, 150] {
            for polarity in [-1.0, 1.0] {
                let (records, peaks) = recording(bpm: bpm, seconds: 30, polarity: polarity)
                let result = EcgBeats.analyse(records)
                XCTAssertEqual(result.beats.count, peaks.count, "\(bpm) bpm, polarity \(polarity)")
                XCTAssertEqual(result.rejectedIntervals, 0, "\(bpm) bpm")
                XCTAssertEqual(try XCTUnwrap(result.heartRate), injectedRate(peaks), accuracy: 0.5, "\(bpm) bpm")
                // Each detected beat lands on its injected R peak, within 10 ms.
                for (beat, peak) in zip(result.beats, peaks) {
                    XCTAssertEqual(beat.time - Double(records[0].ts), peak, accuracy: 0.010)
                }
            }
        }
    }

    func testOnlyQualityThreeRecordsAreAnalysed() {
        let (clean, peaks) = recording(bpm: 90, seconds: 20)
        let noisy = recording(bpm: 60, seconds: 20, quality: 0, startIndex: 1_020, ts0: 1_790_000_020).records
        let result = EcgBeats.analyse(clean + noisy)
        XCTAssertEqual(result.analysedSeconds, 20)
        XCTAssertEqual(try XCTUnwrap(result.heartRate), injectedRate(peaks), accuracy: 0.5)
        XCTAssertTrue(result.beats.allSatisfy { $0.time < 1_790_000_020 })
    }

    func testNoIntervalSpansAGapOrALowerQualityRecord() {
        var records = recording(bpm: 80, seconds: 20).records
        // A quality-1 record in the middle splits the stretch in two.
        let r = records[10]
        records[10] = EcgCandidateSample(ts: r.ts, samples: r.samples, recordIndex: r.recordIndex, quality: 1)
        let result = EcgBeats.analyse(records)
        XCTAssertEqual(Set(result.beats.map(\.segment)), [0, 1])
        XCTAssertEqual(result.analysedSeconds, 19)
        // The longest usable interval is still one beat, not the hole.
        XCTAssertLessThan(try XCTUnwrap(result.rrMs.max()), 60_000 / 80 * 1.1)
    }

    func testShortStretchesAndPartialRecordsAreSkipped() {
        let short = recording(bpm: 80, seconds: EcgBeats.minSegmentSeconds - 1).records
        XCTAssertEqual(EcgBeats.analyse(short).analysedSeconds, 0)
        let r = recording(bpm: 80, seconds: 1).records[0]
        let partial = EcgCandidateSample(ts: r.ts, samples: Array(r.samples.prefix(245)), recordIndex: 1,
                                         declaredCount: 500, quality: 3)
        XCTAssertEqual(EcgBeats.analyse([partial]).analysedSeconds, 0)
    }

    func testNoRateWithoutEnoughIntervals() {
        let result = EcgBeats.analyse(recording(bpm: 50, seconds: 8).records)
        XCTAssertLessThan(result.rrMs.count, EcgBeats.minIntervalsForRate)
        XCTAssertNil(result.heartRate)
    }

    func testAFlatStretchHasNoBeats() {
        let flat = (0..<10).map { EcgCandidateSample(ts: $0, samples: Array(repeating: 1_234, count: 500),
                                                      recordIndex: $0, quality: 3) }
        XCTAssertEqual(EcgBeats.analyse(flat).beats, [])
    }

    func testMarkersFollowTheSampleAxisAcrossAGap() {
        // Records at t=10, 11 and (after a gap) 20, 500 samples each: 1,500 samples on the strip.
        let records = [(ts: 10, sampleCount: 500), (ts: 11, sampleCount: 500), (ts: 20, sampleCount: 500)]
        let f = EcgStrip.markerFractions(beatTimes: [10.0, 11.5, 20.998, 15.0], records: records,
                                         samplesPerSecond: 500)
        XCTAssertEqual(f.count, 3)   // 15.0 lies in the gap and has no place on the strip
        XCTAssertEqual(f[0], 0.5 / 1_500, accuracy: 1e-12)
        XCTAssertEqual(f[1], 750.5 / 1_500, accuracy: 1e-12)
        XCTAssertEqual(f[2], 1_499.5 / 1_500, accuracy: 1e-12)
    }
}
