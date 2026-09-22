import XCTest
@testable import Strand
import WhoopProtocol
import WhoopStore

/// Pins the success-side observability the log forensics flagged as the blind spot (#150): NOOP logged
/// FAILURES (decoded-to-0) but never SUCCESSES, so a strap log couldn't tell a banking strap from a
/// broken one. These cover the pure tally + summary helpers that drive the new
/// "Backfill: session persisted N rows (M with motion) across K night(s)" line.
final class BackfillerSessionTallyTests: XCTestCase {

    // rows = biometric streams only (HR, R-R, SpO2, skin-temp, resp, gravity) — battery/events are
    // housekeeping, NOT biometric history, so they must not inflate the count. motion = gravity.
    func testChunkTallySumsBiometricRowsAndGravityOnly() {
        // #103: `v18Aux` is one packed row per strap-second and would swamp this figure on a 5/MG, so
        // it is deliberately excluded like events/battery — a big number here proves that, not just a
        // signature change.
        let counts = (hr: 10, rr: 4, events: 99, battery: 7, spo2: 3, skinTemp: 2, resp: 1, gravity: 5,
                      v18Aux: 86_400)
        let tally = Backfiller.chunkTally(counts: counts, timestamps: [])
        XCTAssertEqual(tally.rows, 10 + 4 + 3 + 2 + 1 + 5)   // 25 — events(99)/battery(7)/v18Aux excluded
        XCTAssertEqual(tally.motion, 5)
        XCTAssertTrue(tally.nights.isEmpty)
    }

    // nights collapse timestamps to distinct day-keys (ts / 86400), so a chunk spanning a day boundary
    // counts two nights and same-day samples count once.
    func testChunkTallyNightsAreDistinctDayKeys() {
        let day0 = 1_700_000_000
        let sameDay = day0 + 3_600
        let nextDay = day0 + 86_400
        let tally = Backfiller.chunkTally(counts: (0, 0, 0, 0, 0, 0, 0, 0, 0),
                                          timestamps: [day0, sameDay, nextDay])
        XCTAssertEqual(tally.nights, Set([day0 / 86_400, nextDay / 86_400]))
        XCTAssertEqual(tally.nights.count, 2)
    }

    // The summary stays SILENT when nothing persisted, so a console-only / caught-up session doesn't
    // claim a false success — the existing empty-banking diagnostics speak for that case instead.
    func testSessionSummaryNilWhenNoRows() {
        XCTAssertNil(Backfiller.sessionSummaryLine(rows: 0, motion: 0, skinTemp: 0, nights: 0))
    }

    func testSessionSummaryFormat() {
        XCTAssertEqual(
            Backfiller.sessionSummaryLine(rows: 240, motion: 180, skinTemp: 12, nights: 3),
            "Backfill: session persisted 240 rows (180 with motion, 12 skin-temp) across 3 night(s).")
    }

    // #727: a strap banking HR/RR-only records (no DSP sleep block) persists rows but ZERO skin-temp,
    // so the line surfaces that 0 and "skin temp never appears" reports are self-diagnosing from the log.
    func testSessionSummaryShowsZeroSkinTemp() {
        XCTAssertEqual(
            Backfiller.sessionSummaryLine(rows: 872, motion: 172, skinTemp: 0, nights: 1),
            "Backfill: session persisted 872 rows (172 with motion, 0 skin-temp) across 1 night(s).")
    }

    // MARK: - #67 offload clock-diagnostic line (WHERE rows landed + WHY)

    // No nights persisted → no line (nothing to date).
    func testClockDiagNilWhenNoNights() {
        XCTAssertNil(Backfiller.sessionClockDiagLine(nightKeys: [], device: 1_700_000_000, wall: 1_700_000_000, usedIdentityRef: false, family: .whoop5))
    }

    // Rows landed years in the past on the identity ref. The DATE is the #67 signature and still shows;
    // the ref itself is the designed 5/MG decode, so it is named as such rather than as a fallback.
    func testClockDiagIdentityShowsThePastDateItLandedOn() {
        let marchDay = 1_711_276_123 / 86_400          // 2024-03-24
        let line = Backfiller.sessionClockDiagLine(nightKeys: [marchDay],
                                                   device: 1_783_486_611, wall: 1_783_486_611,
                                                   usedIdentityRef: true, family: .whoop5)
        XCTAssertEqual(line, "Backfill: rows landed on 2024-03-24 · clock ref: identity - correct for 5/MG (records carry real-unix timestamps, no correlation needed)")
    }

    // A genuinely stale-but-correlated ref: the correction IS engaged and the behind-by days are named.
    func testClockDiagCorrelatedStaleRefReportsCorrectionEngaged() {
        let day = 1_711_276_123 / 86_400
        let line = Backfiller.sessionClockDiagLine(nightKeys: [day],
                                                   device: 1_711_276_123, wall: 1_783_486_123,
                                                   usedIdentityRef: false, family: .whoop5)
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.contains("835d behind wall - correction engaged"), line ?? "")
    }

    // A healthy strap: in-sync ref, single night, and the date range collapses to one day.
    func testClockDiagInSyncSingleDay() {
        let day = 1_783_400_000 / 86_400
        let line = Backfiller.sessionClockDiagLine(nightKeys: [day],
                                                   device: 1_783_400_000, wall: 1_783_400_050,
                                                   usedIdentityRef: false, family: .whoop5)
        XCTAssertTrue(line!.hasSuffix("· clock ref in sync"), line ?? "")
        XCTAssertFalse(line!.contains("…"))   // one day, not a range
    }

    // Multi-night chunk shows a lo…hi UTC range.
    func testClockDiagMultiNightRange() {
        let d0 = 1_711_276_123 / 86_400
        let d1 = d0 + 2
        let line = Backfiller.sessionClockDiagLine(nightKeys: [d0, d1], device: nil, wall: nil, usedIdentityRef: false, family: .whoop5)
        XCTAssertTrue(line!.contains("2024-03-24…2024-03-26"), line ?? "")
    }

    // #1598: the identity ref is the designed decode on a 5/MG, whose records carry real-unix seconds.
    // It must not be reported as the #700 "IDENTITY fallback" bug — every healthy 5/MG session sets
    // usedIdentityRef, and that line sent triage down a dead end.
    func testClockDiagIdentityOnWhoop5ReadsAsByDesignNotFallback() {
        let day = 1_783_400_000 / 86_400
        let line = Backfiller.sessionClockDiagLine(nightKeys: [day],
                                                   device: 1_783_400_000, wall: 1_783_400_000,
                                                   usedIdentityRef: true, family: .whoop5)
        XCTAssertNotNil(line)
        XCTAssertFalse(line!.contains("IDENTITY fallback"), line ?? "")
        XCTAssertFalse(line!.contains("correction OFF"), line ?? "")
        XCTAssertTrue(line!.contains("identity - correct for 5/MG"), line ?? "")
    }

    // The 5/MG carve-out is gated on usedIdentityRef, not on the family alone: a 5/MG that somehow
    // decoded with a real correlation still reports the ordinary in-sync/stale verdicts.
    func testClockDiagWhoop5WithRealRefStillReportsInSync() {
        let day = 1_783_400_000 / 86_400
        let line = Backfiller.sessionClockDiagLine(nightKeys: [day],
                                                   device: 1_783_400_000, wall: 1_783_400_050,
                                                   usedIdentityRef: false, family: .whoop5)
        XCTAssertTrue(line!.hasSuffix("· clock ref in sync"), line ?? "")
    }

    // No em-dash leaks (matches the noCursorLine/futureRtcLine convention).
    func testClockDiagHasNoEmDash() {
        let line = Backfiller.sessionClockDiagLine(nightKeys: [1_711_276_123 / 86_400],
                                                   device: 1_783_486_611, wall: 1_783_486_611, usedIdentityRef: true, family: .whoop5)
        XCTAssertFalse(line!.contains("\u{2014}"))
        // #1598's 5/MG variant is held to the same convention.
        let w5 = Backfiller.sessionClockDiagLine(nightKeys: [1_711_276_123 / 86_400],
                                                 device: 1_783_486_611, wall: 1_783_486_611, usedIdentityRef: true, family: .whoop5)
        XCTAssertFalse(w5!.contains("\u{2014}"))
    }

    // #783: trim=0xFFFFFFFF on a fresh run that banked NOTHING means "no banked history": the genuine
    // clock/charge guidance with the "fully charge it" hint.
    func testNoCursorLineNoRowsGivesNoHistoryGuidance() {
        let line = Backfiller.noCursorLine(rowsPersisted: 0)
        XCTAssertTrue(line.contains("no banked history to offload"))
        XCTAssertTrue(line.contains("fully charge it"))
    }

    // #783: trim=0xFFFFFFFF AFTER the auto-continuation has already persisted rows means "caught up",
    // NOT "no history". It must NOT emit the scary fully-charge guidance (that falsely alarmed users
    // whose strap had just synced fine).
    func testNoCursorLineAfterRowsGivesCaughtUpLine() {
        let line = Backfiller.noCursorLine(rowsPersisted: 240)
        XCTAssertTrue(line.contains("reached the end of available history"))
        XCTAssertTrue(line.contains("240 row(s)"))
        XCTAssertFalse(line.contains("no banked history"))
        XCTAssertFalse(line.contains("fully charge"))
    }

    // No em-dash leaks into either branch (project hard rule).
    func testNoCursorLineHasNoEmDash() {
        XCTAssertFalse(Backfiller.noCursorLine(rowsPersisted: 0).contains("\u{2014}"))
        XCTAssertFalse(Backfiller.noCursorLine(rowsPersisted: 5).contains("\u{2014}"))
    }

    // MARK: - #773 corrupt future-RTC detection

    // A genuine offload is PAST-dated; a past timestamp is never flagged.
    func testFutureRtcNotFlaggedForPastDate() {
        let now = 1_700_000_000
        XCTAssertFalse(Backfiller.isCorruptFutureRtc(endUnix: now - 86_400, wallNowUnix: now))
        XCTAssertFalse(Backfiller.isCorruptFutureRtc(endUnix: now, wallNowUnix: now))
    }

    // Ordinary forward skew under the 1-day tolerance is NOT a corrupt clock (no false alarm).
    func testFutureRtcToleratesSmallSkew() {
        let now = 1_700_000_000
        XCTAssertFalse(Backfiller.isCorruptFutureRtc(endUnix: now + 3_600, wallNowUnix: now))
        // Exactly at the tolerance boundary is still OK (strictly greater trips it).
        XCTAssertFalse(Backfiller.isCorruptFutureRtc(endUnix: now + Backfiller.futureRtcToleranceSeconds, wallNowUnix: now))
    }

    // A date days into the future can only be a corrupt strap RTC, so it's flagged.
    func testFutureRtcFlaggedForFarFutureDate() {
        let now = 1_700_000_000
        XCTAssertTrue(Backfiller.isCorruptFutureRtc(endUnix: now + 10 * 86_400, wallNowUnix: now))
    }

    // The recovery hint names the cause + the fix and reports the days-ahead, with no em-dash.
    func testFutureRtcLineWording() {
        let now = 1_700_000_000
        let line = Backfiller.futureRtcLine(endUnix: now + 10 * 86_400, wallNowUnix: now)
        XCTAssertTrue(line.contains("10 day(s) in the FUTURE"))
        XCTAssertTrue(line.contains("clock (RTC) is corrupt"))
        XCTAssertTrue(line.contains("Fully charge"))
        XCTAssertFalse(line.contains("\u{2014}"))
    }

    // MARK: - #1 records-bearing 0xFFFFFFFF END must NOT false-alarm "no banked history"

    /// A store that forwards the real decoded counts so the session tally reflects rows that genuinely
    /// landed.
    private final class TallyStore: BackfillStoreWriting {
        @discardableResult
        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int,
                spo2: Int, skinTemp: Int, resp: Int, gravity: Int, v18Aux: Int) {
            (streams.hr.count, streams.rr.count, 0, 0,
             streams.spo2.count, streams.skinTemp.count, streams.resp.count, streams.gravity.count,
             streams.v18Aux.count)
        }
        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {}
        func setCursor(_ name: String, _ value: Int) async throws {}
        func cursor(_ name: String) async throws -> Int? { nil }
    }

    private func hexBytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2); var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j }
        return out
    }

    /// Build a HISTORY_END frame (type 49, cmd 2) carrying the given trim. Payload layout is
    /// unix(4) + subsec(2) + unk0(4) + trim(4), matching the metadata post-hook (HistoricalMetaTests).
    private func historyEndFrame(trim: UInt32, unix: UInt32 = 1_700_000_000) -> [UInt8] {
        func le32(_ v: UInt32) -> [UInt8] {
            [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
        }
        let payload = le32(unix) + [0, 0] + le32(0) + le32(trim)
        return w5Frame(payload, type: 49, seq: 0, cmd: 2)
    }

    /// #1 (the critical other half): a genuinely empty session (a 0xFFFFFFFF END with no accumulated
    /// records, so zero rows persisted) STILL emits the real no-history guidance. The relocation must not
    /// silence the legitimate case.
    @MainActor func testTrulyEmptyNoCursorEndStillWarnsNoHistory() async {
        var lines: [String] = []
        let backfiller = Backfiller(
            store: TallyStore(),
            deviceId: "test",
            ackTrim: { _, _ in },
            log: { lines.append($0) })
        backfiller.begin(family: .whoop5)
        await backfiller.ingest(historyEndFrame(trim: 0xFFFFFFFF))  // no records this session

        XCTAssertEqual(backfiller.sessionRowsPersisted, 0)
        let joined = lines.joined(separator: "\n")
        XCTAssertTrue(joined.contains("no banked history to offload"),
                      "a truly-empty no-cursor session must still warn the strap has no banked history")
        XCTAssertTrue(joined.contains("fully charge it"))
    }

    // MARK: - #1683: the stale counterpart to futureRtcLine

    /// A strap that stopped banking weeks ago and one that is caught up produced the SAME "banked no
    /// sensor history" line, so neither the user nor a triager could tell them apart. That is why #1541
    /// stayed open and unactionable.
    func testACaughtUpOrBrieflyIdleStrapIsNotStale() {
        let now = 1_700_000_000
        XCTAssertFalse(Backfiller.isStaleNewestRecord(newestUnix: nil, wallNowUnix: now))
        XCTAssertFalse(Backfiller.isStaleNewestRecord(newestUnix: 0, wallNowUnix: now))
        XCTAssertFalse(Backfiller.isStaleNewestRecord(newestUnix: now, wallNowUnix: now))
        XCTAssertFalse(Backfiller.isStaleNewestRecord(newestUnix: now - 86_400, wallNowUnix: now),
                       "one night off-wrist is ordinary and must stay silent")
    }

    func testTwoDaysIsTheBoundaryAndQualifies() {
        let now = 1_700_000_000
        XCTAssertTrue(Backfiller.isStaleNewestRecord(newestUnix: now - 2 * 86_400, wallNowUnix: now))
    }

    /// A future-dated record belongs to `futureRtcLine`; this rule must not also claim it.
    func testAFutureDatedRecordIsNotStale() {
        let now = 1_700_000_000
        XCTAssertFalse(Backfiller.isStaleNewestRecord(newestUnix: now + 86_400, wallNowUnix: now))
    }

    /// The numbers from the #1683 capture: newest stored record 1785692420 against a wall clock of
    /// 1787820941. The user was told only "banked no sensor history"; this says three weeks.
    func testStaleRecordLineReportsTheRealCaptureAsTwentyFourDays() {
        let line = Backfiller.staleRecordLine(newestUnix: 1_785_692_420, wallNowUnix: 1_787_820_941)
        XCTAssertTrue(line.contains("about 24 day(s) old"), line)
        XCTAssertTrue(line.contains("stopped saving history"), line)
        // The part the old advice omitted: charging alone has already been retried every connect.
        XCTAssertTrue(line.contains("re-sends the clock on every connect"), line)
        // The test that tells the user whether NOOP is even involved.
        XCTAssertTrue(line.contains("official WHOOP app"), line)
        XCTAssertFalse(line.contains("\u{2014}"))
    }

    /// States the fact, never the diagnosis: a drawered strap shows the same number innocently.
    func testStaleRecordLineDoesNotAssertACorruptClock() {
        let line = Backfiller.staleRecordLine(newestUnix: 1_700_000_000 - 20 * 86_400,
                                              wallNowUnix: 1_700_000_000)
        XCTAssertFalse(line.contains("corrupt"), line)
        XCTAssertTrue(line.contains("If you have worn it"), line)
    }

    /// The banner is what the user READS; the log line needs a capture export. The standing banner
    /// omitted the age entirely and PROMISED that charging "should" work - advice NOOP has effectively
    /// retried on every connect for weeks, since it re-sends SET_CLOCK each time.
    func testStaleRecordBannerDatesTheSilenceAndPromisesNothing() {
        let line = Backfiller.staleRecordBanner(newestUnix: 1_785_692_420, wallNowUnix: 1_787_820_941)
        XCTAssertTrue(line.contains("about 24 day(s) old"), line)
        XCTAssertTrue(line.contains("If you have been wearing it"), line)
        XCTAssertTrue(line.contains("official WHOOP app"), line)
        XCTAssertFalse(line.contains("should start banking again"), line)
        XCTAssertFalse(line.contains("\u{2014}"))
    }

    // ---- #1754: two distinct empty-offload banners ------------------------------------------

    /// The no-flash-cursor banner (trim=0xFFFFFFFF) names the clock/charge cause — the existing copy,
    /// now a named constant so the caller's branch reads as a choice between two states.
    func testNoFlashCursorBannerNamesClockAndCharge() {
        let line = Backfiller.noFlashCursorBanner
        XCTAssertTrue(line.contains("no stored history to hand over"), line)
        XCTAssertTrue(line.contains("clock has lost sync"), line)
        XCTAssertTrue(line.contains("Fully charge it to 100%"), line)
        XCTAssertFalse(line.contains("sensor front-end"), line)
    }

    /// The no-sensor-records banner (valid trim, advancing write pointer, zero rows) does NOT name
    /// the clock — it points at the sensor front-end or power state, and asks for a strap log rather
    /// than promising that charging will fix it.
    func testNoSensorRecordsBannerDoesNotBlameTheClock() {
        let line = Backfiller.noSensorRecordsBanner
        XCTAssertTrue(line.contains("no sensor records"), line)
        XCTAssertTrue(line.contains("flash cursor is valid and advancing"), line)
        XCTAssertTrue(line.contains("not a clock problem"), line)
        XCTAssertTrue(line.contains("sensor front-end or power"), line)
        XCTAssertFalse(line.contains("clock has lost sync"), line)
        XCTAssertFalse(line.contains("Fully charge it to 100%"), line)
    }

    /// The two banners must be distinct strings — a caller choosing between them must not get the
    /// same copy for both states.
    func testTheTwoBannersAreDistinct() {
        XCTAssertNotEqual(Backfiller.noFlashCursorBanner, Backfiller.noSensorRecordsBanner)
    }

    /// No em-dash in either banner (project rule).
    func testNoEmDashInEitherBanner() {
        XCTAssertFalse(Backfiller.noFlashCursorBanner.contains("\u{2014}"))
        XCTAssertFalse(Backfiller.noSensorRecordsBanner.contains("\u{2014}"))
    }
}
