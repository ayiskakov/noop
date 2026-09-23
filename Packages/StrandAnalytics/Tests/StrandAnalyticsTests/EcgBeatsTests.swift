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
    ///
    /// `amplitude` scales each complex by its peak time, for recordings whose complexes grow and shrink;
    /// `clockJump` moves every record from `at` onwards by `seconds` of wall clock, leaving the record
    /// index running on, as a clock correction partway through a session does.
    private func recording(bpm: Double, seconds: Int, polarity: Double = -1, hum: Double = 0.5,
                           quality: Int = 3, startIndex: Int = 1_000, ts0: Int = 1_790_000_000,
                           amplitude: (Double) -> Double = { _ in 1 },
                           clockJump: (at: Int, seconds: Int)? = nil)
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
        let full = 8_000.0
        var x = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let ti = Double(i) / fs
            var v = 40_000 + 15_000 * sin(2 * .pi * 0.3 * ti)          // offset and drift
            v += hum * full * sin(2 * .pi * 50 * ti)                   // mains
            v += 0.05 * full * noise.next()
            for p in peaks where abs(ti - p) < 0.6 {
                let q = (ti - p) / 0.010, tw = (ti - p - 0.25) / 0.060
                let a = full * amplitude(p)
                v += polarity * a * exp(-0.5 * q * q)                  // QRS
                v += polarity * 0.3 * a * exp(-0.5 * tw * tw)          // T wave
            }
            x[i] = v
        }
        let records = (0..<seconds).map { s in
            EcgCandidateSample(ts: ts0 + s + (clockJump.map { s >= $0.at ? $0.seconds : 0 } ?? 0),
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
        // The codes are states, not a scale: an unknown higher one is not taken as better.
        XCTAssertEqual(EcgBeats.analyse(recording(bpm: 90, seconds: 20, quality: 4).records).analysedSeconds, 0)
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
        // Inside a long stretch, where only the record checks can drop them: one record that stored and
        // declared 245 samples, and one that stored 500 but declared 600.
        var records = recording(bpm: 80, seconds: 20).records
        let a = records[6], b = records[13]
        records[6] = EcgCandidateSample(ts: a.ts, samples: Array(a.samples.prefix(245)), recordIndex: a.recordIndex,
                                        quality: 3)
        records[13] = EcgCandidateSample(ts: b.ts, samples: b.samples, recordIndex: b.recordIndex,
                                         declaredCount: 600, quality: 3)
        XCTAssertEqual(EcgBeats.analyse(records).analysedSeconds, 18)
    }

    func testTinyInputsGiveNoBeatsRatherThanTrapping() {
        XCTAssertEqual(EcgBeats.detect([], sampleRate: 0.5), [])
        XCTAssertEqual(EcgBeats.detect([1], sampleRate: 1), [])
        XCTAssertEqual(EcgBeats.detect([1, 9], sampleRate: 2), [])
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
        let f = EcgStrip.markerFractions(beats: [(ts: 10, sample: 0), (ts: 11, sample: 250),
                                                 (ts: 20, sample: 499), (ts: 15, sample: 0)],
                                         records: records)
        XCTAssertEqual(f.count, 3)   // record 15 lies in the gap and has no place on the strip
        XCTAssertEqual(f[0], 0.5 / 1_500, accuracy: 1e-12)
        XCTAssertEqual(f[1], 750.5 / 1_500, accuracy: 1e-12)
        XCTAssertEqual(f[2], 1_499.5 / 1_500, accuracy: 1e-12)
    }

    /// A clock correction partway through a session leaves the record index running on, so the stretch
    /// stays one. Each beat must still be stamped from its own record: stamped from the stretch's start,
    /// the beats after the correction named records five seconds early and their markers landed on
    /// other complexes or on none.
    func testAClockCorrectionMidStretchKeepsEveryBeatOnItsComplex() throws {
        let (records, peaks) = recording(bpm: 80, seconds: 20, clockJump: (at: 10, seconds: 5))
        let result = EcgBeats.analyse(records)
        XCTAssertEqual(Set(result.beats.map(\.segment)), [0])
        XCTAssertEqual(result.beats.count, peaks.count)
        // Intervals are counted on the sample clock, so the one spanning the correction is ordinary.
        XCTAssertEqual(result.rejectedIntervals, 0)
        XCTAssertLessThan(try XCTUnwrap(result.rrMs.max()), 60_000 / 80 * 1.1)
        for (beat, peak) in zip(result.beats, peaks) {
            let record = try XCTUnwrap(records.firstIndex { $0.ts == beat.recordTs })
            XCTAssertEqual(Double(record * 500 + beat.sample), peak * 500, accuracy: 5)
        }
        let marks = EcgStrip.markerFractions(beats: result.beats.map { (ts: $0.recordTs, sample: $0.sample) },
                                             records: records.map { (ts: $0.ts, sampleCount: $0.samples.count) })
        XCTAssertEqual(marks.count, peaks.count)
        for (mark, peak) in zip(marks, peaks) {
            XCTAssertEqual(mark * 10_000, peak * 500, accuracy: 5)
        }
    }

    /// Complexes that shrink and grow, as they do when the finger's pressure on the clasp changes, are
    /// all found. One threshold for the whole stretch lost every complex below about half the largest,
    /// and the median rate did not move to show it.
    func testEveryBeatIsFoundAsTheAmplitudeSwings() {
        for low in [0.4, 0.6] {
            let (records, peaks) = recording(bpm: 72, seconds: 60,
                                             amplitude: { low + (1 - low) * (0.5 + 0.5 * cos(2 * .pi * $0 / 20)) })
            let result = EcgBeats.analyse(records)
            XCTAssertEqual(result.beats.count, peaks.count, "swing down to \(low)")
            for (beat, peak) in zip(result.beats, peaks) {
                XCTAssertEqual(beat.time - Double(records[0].ts), peak, accuracy: 0.010)
            }
        }
    }

    func testAStepDownInAmplitudeIsFollowed() {
        let (records, peaks) = recording(bpm: 75, seconds: 30, amplitude: { $0 < 15 ? 1 : 0.4 })
        let result = EcgBeats.analyse(records)
        XCTAssertEqual(result.beats.count, peaks.count)
        for (beat, peak) in zip(result.beats, peaks) {
            XCTAssertEqual(beat.time - Double(records[0].ts), peak, accuracy: 0.010)
        }
    }

    /// Where the complexes fade into the noise they cannot be found, and none may be invented there.
    func testAFadingSignalLosesBeatsButNeverInventsThem() {
        let amplitude: (Double) -> Double = { 0.5 + 0.5 * cos(2 * .pi * $0 / 20) }
        let (records, peaks) = recording(bpm: 72, seconds: 60, amplitude: amplitude)
        let result = EcgBeats.analyse(records)
        let t0 = Double(records[0].ts)
        for beat in result.beats {
            XCTAssertTrue(peaks.contains { abs($0 - (beat.time - t0)) < 0.010 }, "beat at \(beat.time - t0) s")
        }
        for peak in peaks where amplitude(peak) >= 0.25 {
            XCTAssertTrue(result.beats.contains { abs($0.time - t0 - peak) < 0.010 }, "complex at \(peak) s")
        }
    }

    /// A spike of the opposite polarity to the complexes and as large as they are, midway between two
    /// beats. The running threshold judges energy, which such a spike has plenty of, and takes it for a
    /// beat; judged against the neighbouring complexes' deflection it is not one.
    func testAnOppositePolaritySpikeBetweenBeatsIsNotABeat() {
        var (records, peaks) = recording(bpm: 75, seconds: 30)
        let spikes = [7, 15, 23].map { (peaks[$0] + peaks[$0 + 1]) / 2 }
        records = records.enumerated().map { s, r in
            EcgCandidateSample(ts: r.ts, samples: r.samples.enumerated().map { i, v in
                let t = Double(s) + Double(i) / 500
                return v + Int(spikes.reduce(0.0) { $0 + 8_000 * exp(-0.5 * pow((t - $1) / 0.008, 2)) }.rounded())
            }, recordIndex: r.recordIndex, quality: 3)
        }
        let result = EcgBeats.analyse(records)
        XCTAssertEqual(result.beats.count, peaks.count)
        for (beat, peak) in zip(result.beats, peaks) {
            XCTAssertEqual(beat.time - Double(records[0].ts), peak, accuracy: 0.010)
        }
    }

    /// A second of artefact raises the threshold for a moment, not for the stretch. At over 3 % of a
    /// 30-second stretch it put a threshold taken from the stretch's 98th percentile above every
    /// real complex. In record 1 or 3 it lifts two of the three blocks the levels are first learned
    /// from, which once silenced the stretch the same way: 3 of 37 beats, and no rate.
    func testABriefArtefactDoesNotSilenceTheRestOfTheStretch() {
        for k in [1, 3, 15] {
            var (records, peaks) = recording(bpm: 75, seconds: 30)
            var noise = Lcg(state: 7)
            let r = records[k]
            records[k] = EcgCandidateSample(ts: r.ts, samples: r.samples.map { $0 + Int(80_000 * noise.next()) },
                                            recordIndex: r.recordIndex, quality: 3)
            let result = EcgBeats.analyse(records)
            let t0 = Double(records[0].ts)
            let clear: (Double) -> Bool = { abs($0 - (Double(k) + 0.5)) > 1.5 }
            for peak in peaks where clear(peak) {
                XCTAssertTrue(result.beats.contains { abs($0.time - t0 - peak) < 0.010 }, "record \(k): complex at \(peak) s")
            }
            for beat in result.beats where clear(beat.time - t0) {
                XCTAssertTrue(peaks.contains { abs($0 - (beat.time - t0)) < 0.010 }, "record \(k): beat at \(beat.time - t0) s")
            }
        }
    }
}
