import XCTest
@testable import StrandAnalytics

/// The pure arithmetic behind the gated R16 ECG review strip (#891).
///
/// UNVALIDATED INSTRUMENTATION. Nothing here computes a heart rate, an interval, a rhythm or a voltage,
/// and no test below asserts anything physiological — these pin GROUPING and RENDERING, which are facts
/// about arrays.
///
/// Numeric expectations were produced by compiling `EcgStrip.swift` standalone and pinning its stdout
/// (`AGENTS.md`: verify by oracle, not by eye). A waveform is the one thing a reviewer cannot check by
/// reading the code, so the properties that matter — drift removed, deflection preserved, no transient
/// across a gap — are asserted as measured ratios rather than as eyeballed shapes.
final class EcgStripTests: XCTestCase {

    private func ref(ts: Int, index: Int?, stored: Int = 500, declared: Int = 500,
                     quality: Int = 3, progress: Int = 50, contact: [Bool] = []) -> EcgStrip.RecordRef {
        EcgStrip.RecordRef(ts: ts, recordIndex: index, storedCount: stored, declaredCount: declared,
                           quality: quality, progress: progress, contactFlags: contact)
    }

    // MARK: - Grouping: the record index decides, not the clock

    func testConsecutiveRecordsFormOneRecording() {
        let records = (0..<64).map { ref(ts: 1000 + $0, index: 500 + $0) }
        let out = EcgStrip.group(deviceId: "d", records: records)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].recordCount, 64)
        XCTAssertEqual(out[0].startTs, 1000)
        XCTAssertEqual(out[0].endTs, 1063)
        XCTAssertEqual(out[0].durationSeconds, 64, "each record is the one second it represents")
        XCTAssertEqual(out[0].storedSamples, 32_000)
    }

    func testAGapInTheRecordIndexSplitsTheRecording() {
        let a = (0..<10).map { ref(ts: 1000 + $0, index: 500 + $0) }
        let b = (0..<10).map { ref(ts: 2000 + $0, index: 900 + $0) }
        let out = EcgStrip.group(deviceId: "d", records: a + b)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out.map(\.recordCount), [10, 10])
        XCTAssertEqual(out.map(\.startTs), [2000, 1000], "newest first")
    }

    /// The reason contiguity is decided on the index and not the clock. A strap RTC correction moves
    /// `ts` mid-session while the monotonic counter keeps advancing by one — so a ts-gap heuristic tears
    /// one recording in half and presents it as two, each with a wrong duration.
    func testAClockCorrectionMidSessionDoesNotSplitTheRecording() {
        var records = (0..<10).map { ref(ts: 1000 + $0, index: 500 + $0) }
        // The strap's clock jumps 90 seconds forward between record 5 and 6; the index does not.
        records += (10..<20).map { ref(ts: 1090 + $0, index: 500 + $0) }
        let out = EcgStrip.group(deviceId: "d", records: records)
        XCTAssertEqual(out.count, 1, "consecutive indices are one recording whatever the clock did")
        XCTAssertEqual(out[0].recordCount, 20)
        // A ts-only rule would have produced two, which is the bug this guards.
        let tsOnly = EcgStrip.group(deviceId: "d", records: records.map {
            EcgStrip.RecordRef(ts: $0.ts, recordIndex: nil, storedCount: $0.storedCount,
                               declaredCount: $0.declaredCount, quality: $0.quality,
                               progress: $0.progress, contactFlags: $0.contactFlags)
        })
        XCTAssertEqual(tsOnly.count, 2, "the fallback genuinely differs — this fixture proves the point")
    }

    func testRecordsWithoutAnIndexFallBackToAdjacentSeconds() {
        let out = EcgStrip.group(deviceId: "d", records: [
            ref(ts: 100, index: nil), ref(ts: 101, index: nil), ref(ts: 102, index: nil),
            ref(ts: 200, index: nil),
        ])
        XCTAssertEqual(out.map(\.recordCount), [1, 3])
    }

    func testUnsortedInputGroupsTheSameAsSortedInput() {
        let records = (0..<20).map { ref(ts: 1000 + $0, index: 500 + $0) }
        XCTAssertEqual(EcgStrip.group(deviceId: "d", records: records.reversed()),
                       EcgStrip.group(deviceId: "d", records: records))
    }

    func testASingleRecordIsAOneSecondRecording() {
        let out = EcgStrip.group(deviceId: "d", records: [ref(ts: 42, index: 7)])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].durationSeconds, 1)
    }

    func testNoRecordsIsNoRecordings() {
        XCTAssertEqual(EcgStrip.group(deviceId: "d", records: []), [])
    }

    // MARK: - Grouping: what the summary reports

    func testAnIncompleteRecordingReportsItselfAsIncomplete() {
        let complete = EcgStrip.group(deviceId: "d", records: [ref(ts: 1, index: 1)])
        XCTAssertTrue(complete[0].isComplete)
        XCTAssertEqual(complete[0].storedSamples, complete[0].declaredSamples)

        let lossy = EcgStrip.group(deviceId: "d", records: [ref(ts: 1, index: 1, stored: 300)])
        XCTAssertFalse(lossy[0].isComplete,
                       "storing fewer samples than the record declared means the strip is drawing an "
                       + "incomplete waveform, and the screen has to say so")
        XCTAssertEqual(lossy[0].storedSamples, 300)
        XCTAssertEqual(lossy[0].declaredSamples, 500)
    }

    func testContactIsReportedAsACountOfEntriesNotAQualityScore() {
        let out = EcgStrip.group(deviceId: "d", records: [
            ref(ts: 1, index: 1, contact: Array(repeating: true, count: 10)),
            ref(ts: 2, index: 2, contact: [true, true, true, true, true, true, true, true, true, false]),
            ref(ts: 3, index: 3, contact: Array(repeating: false, count: 10)),
        ])
        XCTAssertEqual(out[0].contactClosed, 19)
        XCTAssertEqual(out[0].contactTotal, 30)
    }

    func testARecordCarryingNoContactStreamContributesNoContactEntries() {
        let out = EcgStrip.group(deviceId: "d", records: [ref(ts: 1, index: 1, contact: [])])
        XCTAssertEqual(out[0].contactTotal, 0,
                       "no slower stream means no entries — not ten that happen to read false")
    }

    /// 255 is the strap's "no session is running" value. Reporting it as a progress of 255 would put a
    /// nonsense percentage on screen; it is reported as absent.
    func testTheNoSessionProgressValueIsReportedAsAbsent() {
        let none = EcgStrip.group(deviceId: "d", records: [
            ref(ts: 1, index: 1, progress: 255), ref(ts: 2, index: 2, progress: 255),
        ])
        XCTAssertNil(none[0].peakProgress)

        let ran = EcgStrip.group(deviceId: "d", records: [
            ref(ts: 1, index: 1, progress: 255), ref(ts: 2, index: 2, progress: 40),
            ref(ts: 3, index: 3, progress: 100),
        ])
        XCTAssertEqual(ran[0].peakProgress, 100)
    }

    // MARK: - The display filter

    /// Pinned from the standalone run. The spike at index 10 is what matters: a filter that removed
    /// baseline wander by removing everything would flatten it too.
    func testHighPassMatchesTheOracle() {
        var ramp = (0..<20).map { Double($0) * 100.0 }
        ramp[10] += 5000
        let out = EcgStrip.highPass(ramp, sampleRate: 500, cutoffHz: 0.5)
        let expected: [Double] = [
            99.375605, 99.375605, 198.130713, 296.269198, 393.794912, 490.711680, 587.023303,
            682.733562, 777.846210, 872.364979, 5935.073811, 1028.610858, 1121.563864, 1213.936477,
            1305.732318, 1396.954991, 1487.608074, 1577.695123, 1667.219673, 1756.185236,
        ]
        XCTAssertEqual(out.count, expected.count)
        for (a, b) in zip(out, expected) { XCTAssertEqual(a, b, accuracy: 1e-5) }
    }

    /// The property the filter exists for, measured rather than eyeballed, at a realistic window length.
    /// A 20-sample window is far shorter than the filter's ~160-sample time constant at 500 Hz, so the
    /// oracle case above cannot show this and a test built only on it would prove nothing.
    func testTheFilterRemovesDriftWhileKeepingANarrowDeflection() {
        let drift = (0..<1000).map { Double($0) * 28.0 }          // ~28,000 counts of wander
        let filtered = EcgStrip.highPass(drift, sampleRate: 500)
        let inputSpan = drift.max()! - drift.min()!
        let outputSpan = filtered.max()! - filtered.min()!
        XCTAssertLessThan(outputSpan, inputSpan * 0.2,
                          "at least 80 percent of a linear drift must be gone — an unfiltered strip is a "
                          + "ramp with the signal riding invisibly on it")

        var withPeak = drift
        for i in 500..<505 { withPeak[i] += 4000 }                 // a narrow 4,000-count deflection
        let peakFiltered = EcgStrip.highPass(withPeak, sampleRate: 500)
        let recovered = peakFiltered.max()! - filtered.max()!
        XCTAssertGreaterThan(recovered, 4000 * 0.9,
                             "and at least 90 percent of a narrow deflection must survive it")
    }

    func testDegenerateFilterInputsReturnTheInputRatherThanZeros() {
        XCTAssertEqual(EcgStrip.highPass([], sampleRate: 500), [])
        XCTAssertEqual(EcgStrip.highPass([7], sampleRate: 500), [7])
        XCTAssertEqual(EcgStrip.highPass([1, 2, 3], sampleRate: 0), [1, 2, 3])
        XCTAssertEqual(EcgStrip.highPass([1, 2, 3], sampleRate: 500, cutoffHz: 0), [1, 2, 3])
    }

    /// The filter's first output has no predecessor to difference against and is zero by construction;
    /// leaving it there puts a spurious step on the left edge of every strip.
    func testTheFirstSampleDoesNotRenderAsAStepFromZero() {
        let out = EcgStrip.highPass([1000, 1100, 1200, 1300], sampleRate: 500)
        XCTAssertEqual(out[0], out[1], "the leading sample is carried, not left at zero")
    }

    // MARK: - Gaps are never filtered across

    /// The decisive one. A 10,000-count step at a gap boundary manufactures a transient of almost the
    /// same size if the filter runs straight through it — a deflection that looks exactly like a complex,
    /// at the one place where the strap recorded nothing at all.
    func testFilteringDoesNotManufactureADeflectionAtAGap() {
        let joined = Array(repeating: 0.0, count: 10) + Array(repeating: 10_000.0, count: 10)
        let through = EcgStrip.highPass(joined, sampleRate: 500)
        let segmented = EcgStrip.filterSegments(joined, gapAfter: [9], sampleRate: 500)

        XCTAssertGreaterThan(through.map(abs).max()!, 9000,
                             "filtering through the step is what produces the phantom deflection")
        XCTAssertLessThan(segmented.map(abs).max()!, 1,
                          "filtered per segment, the step never enters the filter and nothing is invented")
        XCTAssertEqual(segmented.count, joined.count, "no sample is lost to the segmentation")
    }

    func testSegmentFilteringWithNoGapsMatchesFilteringTheWholeSeries() {
        let samples = (0..<200).map { Double($0 % 37) * 13 }
        XCTAssertEqual(EcgStrip.filterSegments(samples, gapAfter: [], sampleRate: 500),
                       EcgStrip.highPass(samples, sampleRate: 500))
    }

    func testConcatenateReportsGapsRatherThanFillingThem() {
        let (samples, gaps) = EcgStrip.concatenate([
            (ts: 10, samples: [1, 2, 3]),
            (ts: 11, samples: [4, 5, 6]),
            (ts: 14, samples: [7, 8, 9]),     // seconds 12 and 13 are missing
        ])
        XCTAssertEqual(samples, [1, 2, 3, 4, 5, 6, 7, 8, 9],
                       "nothing is inserted for a missing second — interpolating would draw a smooth "
                       + "line through a stretch where the strap recorded nothing")
        XCTAssertEqual(gaps, [5], "the break is marked at the last sample before the missing seconds")
    }

    func testConcatenateSortsAndHandlesTheEmptyCase() {
        let (samples, gaps) = EcgStrip.concatenate([
            (ts: 11, samples: [4, 5]), (ts: 10, samples: [1, 2]),
        ])
        XCTAssertEqual(samples, [1, 2, 4, 5])
        XCTAssertEqual(gaps, [])
        let (empty, noGaps) = EcgStrip.concatenate([])
        XCTAssertEqual(empty, [])
        XCTAssertEqual(noGaps, [])
    }

    // MARK: - Envelope rendering

    func testEnvelopeMatchesTheOracle() {
        let four = EcgStrip.envelope([1, 5, 2, 8, 3, 9, 4, 7], columns: 4)
        XCTAssertEqual(four, [EcgStrip.Column(min: 1, max: 5), EcgStrip.Column(min: 2, max: 8),
                              EcgStrip.Column(min: 3, max: 9), EcgStrip.Column(min: 4, max: 7)])
        let three = EcgStrip.envelope([1, 5, 2, 8, 3, 9, 4, 7], columns: 3)
        XCTAssertEqual(three, [EcgStrip.Column(min: 1, max: 5), EcgStrip.Column(min: 2, max: 8),
                               EcgStrip.Column(min: 4, max: 9)])
    }

    /// Why min/max and not decimation or averaging. A narrow peak hidden among many samples per column
    /// must reach the picture: decimation drops it whenever the stride steps over it, and averaging
    /// attenuates it in proportion to how narrow it is — which is backwards for a signal whose sharpest
    /// features are the ones worth seeing.
    func testANarrowPeakSurvivesTheEnvelopeWhereDecimationAndAveragingLoseIt() {
        var samples = [Double](repeating: 0, count: 4000)
        samples[1234] = 9999                                  // one sample in four thousand
        let columns = EcgStrip.envelope(samples, columns: 100)
        XCTAssertEqual(columns.map(\.max).max(), 9999, "the peak reaches the picture intact")

        // Decimation at the same reduction takes every 40th sample and steps straight over index 1234.
        let decimated = stride(from: 0, to: samples.count, by: 40).map { samples[$0] }
        XCTAssertEqual(decimated.max(), 0, "decimation loses it entirely")

        // Averaging spreads it across 40 samples, cutting it to a fortieth.
        let averaged = stride(from: 0, to: samples.count, by: 40).map {
            samples[$0..<Swift.min($0 + 40, samples.count)].reduce(0, +) / 40
        }
        XCTAssertLessThan(averaged.max()!, 300, "averaging flattens it to near nothing")
    }

    func testEveryColumnCoversSamplesAndNoSampleIsSkipped() {
        let samples = (0..<1000).map { Double($0) }
        let columns = EcgStrip.envelope(samples, columns: 97)
        XCTAssertEqual(columns.count, 97)
        // The columns must partition the series: the first starts at the first sample, the last ends at
        // the last, and no value in between falls outside every column's range.
        XCTAssertEqual(columns.first?.min, 0)
        XCTAssertEqual(columns.last?.max, 999)
        for (a, b) in zip(columns, columns.dropFirst()) {
            XCTAssertLessThanOrEqual(a.max, b.max, "a monotonic series must produce monotonic columns")
        }
    }

    func testMoreColumnsThanSamplesProducesOneColumnPerSampleNotEmptyOnes() {
        let columns = EcgStrip.envelope([1, 2, 3], columns: 700)
        XCTAssertEqual(columns.count, 3,
                       "stretching three columns across the width shows the data is sparser than the "
                       + "space given it; 700 columns, 697 of them empty, would not")
    }

    func testDegenerateEnvelopeInputs() {
        XCTAssertEqual(EcgStrip.envelope([], columns: 100), [])
        XCTAssertEqual(EcgStrip.envelope([1, 2, 3], columns: 0), [])
        XCTAssertEqual(EcgStrip.envelope([1, 2, 3], columns: -5), [])
    }

    // MARK: - Vertical range

    func testVerticalRangePadsTheDataAndMatchesTheOracle() {
        let columns = EcgStrip.envelope([1, 5, 2, 8, 3, 9, 4, 7], columns: 4)
        let range = EcgStrip.verticalRange(columns)
        XCTAssertEqual(range.min, 0.36, accuracy: 1e-9)
        XCTAssertEqual(range.max, 9.64, accuracy: 1e-9)
    }

    /// A flat window — an all-zero record, or one pinned at the amplifier rail — has no span to pad.
    /// It must draw as a centred flat line, not divide by zero.
    func testAFlatWindowGetsAUnitRangeRatherThanAZeroHeightOne() {
        let flat = [EcgStrip.Column(min: 7, max: 7), EcgStrip.Column(min: 7, max: 7)]
        let range = EcgStrip.verticalRange(flat)
        XCTAssertLessThan(range.min, range.max)
        XCTAssertEqual(range.min, 6)
        XCTAssertEqual(range.max, 8)
    }

    func testAnEmptyEnvelopeStillYieldsADrawableRange() {
        let range = EcgStrip.verticalRange([])
        XCTAssertLessThan(range.min, range.max)
    }

    func testBreakColumnsIsTheEnvelopeColumnHoldingTheGapSample() {
        // Oracle: the column whose `envelope` bounds contain the sample, found by scanning those bounds.
        for count in 1..<64 {
            for requested in 1..<48 {
                let n = min(requested, count)
                for i in 0..<count {
                    let holder = (0..<n).first { c in
                        c * count / n <= i && i < max(c * count / n + 1, (c + 1) * count / n)
                    }
                    XCTAssertEqual(EcgStrip.breakColumns(gapAfter: [i], sampleCount: count, columns: requested),
                                   [holder!], "count \(count) columns \(requested) sample \(i)")
                }
            }
        }
        // A case the scaled index gets wrong: sample 197 of 199 over 119 columns sits in column 118.
        XCTAssertEqual(EcgStrip.breakColumns(gapAfter: [197], sampleCount: 199, columns: 119), [118])
        XCTAssertEqual(EcgStrip.breakColumns(gapAfter: [-1, 5], sampleCount: 5, columns: 3), [])
    }
}
