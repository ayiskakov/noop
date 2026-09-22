import XCTest
@testable import WhoopProtocol

/// WHOOP 5/MG type-47 **version-16** record — a MAX86176 optical/electrical AFE FIFO buffer, surfaced
/// ONLY as EXPLICITLY UNVALIDATED instrumentation (#891).
///
/// UNVALIDATED CANDIDATE; MAX86176 FIFO; NOT an ECG, NOT a heart rate, NOT a diagnosis. The sample rate
/// and the physical meaning of the channels are UNPROVEN. These tests pin the DECODE + STORE shape — the
/// header, the FIFO framing, and that a full record yields a non-empty candidate stream while an empty one
/// yields none — and the classification (`decodesWithoutNamedSignal`); they assert NOTHING physiological.
///
/// Both fixtures are real, CRC-valid v16 records captured from WHOOP 5/MG hardware (fw 50.39.1.0), each
/// 1584 bytes. Real type-47 history frames carry no device name / serial / token, so the fixtures are
/// anonymous. See `decodeWhoop5HistoricalV16`.
final class Whoop5HistoricalV16Tests: XCTestCase {

    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2); var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j }
        return out
    }

    // A FULL v16 record: record_index 29868937, unix 1789990296. Its MAX86176 FIFO carries 500 words on
    // the 0x80 channel (dominant tag byte 0x83) and 7 on the 0xC0 channel.
    private let fullHex =
        "aa0128060100cde02f100389c3c7019815b16a3d2a030a000132000000ffff00f40183ee1083e9a883f2f883f32a83f1ca83f0a783f0a483ec8a83f09883ee2283ee9983eb7c83f0c883f48a83f8b983f67c83ed1683eaba83ee5d83e94983ea8683f18583f70f83f52883f33383edef83eaba83ead383e86983eb5b83f05983f16c83f8a383f79d83ec1e83e56a83e8e983ed1e83ea5283ebdb83f0fd83edd883ebd383ed4c83f20783f57583f21083f3d883f35e83ee9583ed8b83ecdf83ed9b83ec8e83f54783f2e683f1f083eae883eb2f83efe683f62683ef2383e9d783e7eb83eb2f83e8e183e8df83eb7983f05d83eed183e85d83f14483f96a83ef5383e70a83e9bd83eb6683f19b83edfe83e58083e72e83e94883ee3683efa783f2ba83f01383ef3f83f00e83e9e683e6a983e7f683eabf83f00383ef1483f1f383f0a383ee6c83ec7983e73d83dec383e25683e61f83e3f183e56983ebd383ee6b83eecc83eacc83ea3583eb3483ec1883eca383f11883f0e983eb8d83ebda83eb4883f13683f06783f36a83ee3383e2dd83e3eb83e9ba83ea2283e80683eccd83e83583e7f483e8fc83e89e83e3ee83e80783ed1283edb283ec5a83eadf83ec4e83ef5d83eb3783e50f83e18a83e42283e9d483e5ab83e95083ef6583f01083ecd383ea4583ebcc83f52283f11b83e9ea83e6a583e64583e48183e8d683e9f083e6b083ebb983ecff83ede683edc883e7e883ea9e83e6f783e8af83e9d283e66783e6bf83f05783f26483f20183eafb83e9c283eabd83f04e83efca83ed4983eddd83e87283e7be83e6db83e5ef83eb0483ef9a83eefb83e8fb83e28f83e50983eb6d83eec783eca083e8e083e52083e9f783e82c83e97a83ec6583e9e083e8df83e63283e1e683e68983eab483e9a583e60883eade83eaad83eb7783eba583e20483e1f683e6c383e91683e6da83e64483e7b583e8d683e93883e60783e68983ec1283e96c83e8a183e94e83e63e83e7ba83ec6883e59283e51483e62983ec1483ecc983ec4e83ea2083e65283e6b883ed4283f1a783f2d883f5b583fbd583fc5b83ffe780012a83fe8a8003ef83ff5d83f64283f05f83e93a83e77983eb4083ec3383e6bc83e16383dad083d7da83d40283cfb383d1fe83d41f83d98383dd0c83dd9f83dffb83e40a83e5b583e36e83e4e983ed2283eeea83ecea83ec2683e9ea83e7ad83e1c983e8db83f0b983f08483edc983eb5183f04583ea6a83e9b683e8e683eb3383ec4783ec2083ea2683ef7283eff383eac783f10b83f03c83ed0283ee9883eda883f05a83f3a383edc283e9f583eab683e92c83e6c683e89583f0f683f01783eeea83efc483ecf483ef7a83ede483f00e83f0c983eae183efb483eff483f2d783f45f83efd483e9e883eaad83f13c83ef7183f06c83f0c483ece683ef2f83efe883eea883f07c83f58783f29883f42883f6bf83f43683f20283f55e83f28c83f42283f20f83f46683f5c383f0f583f57383f72983f6a083f2b383f3ab83f65d83f40f83f74883f88183f98c83f68f83f59683fb4283f9f183f68f83f72383f60f83f71683f6f483efa983ef0283f47183f6dd83f64483f6d083f9b483fa7e83f87483f3d383ef4483efaf83edf083ee2383eb2183e79583e6bf83e94b83f1a183f2b283eeea83f2bd83ed7d83e88b83e94183f03883f19383effb83eb5683e77983e4f683dee683e00a83de8f83df6d83e32283e59483e98e83e75883e7c883dff083da6583dda183e39b83e4dc83e61b83e17483e27683e77283e89883e7da83e27f83df9b83e18283e24983e14083e00e83dd0383de0883e2a583e56083e0e383e52983e80683e29683e5a383dd1583d8bf83e24383e97a83e97483e47283e46a83e0f983dd4483e2ca83e13683e10183e28183e7c883e0da83de3283dba983de8183e41483e80e83e5bb83e35d83de8483dcb083dff883e1b683e52183e2e383e38183e0ca83e66e83e3d283e3eb83e5f983e6df83e8f383e68383e31083dcdb83d94283dd2f83e15083e38283e05083dcd583de2b83e0df83e33183e37b83e5bd83e4b983e51d83e35083e46583e34183dc6583da1983de9b83e39f83e3d483e6d083e85d83e39683e45e83e5a883e68983e5e683e14c0b3f003f003e003e003e003e003e003e003e003e003e00edffedffedffedffedffedffedffedffedffedffedff003c9b1ea9"

    // An EMPTY v16 record (~1% nonzero payload): record_index 29868914, unix 1789990273. Its FIFO body is
    // all-zero padding, so it carries NO 0x80- or 0xC0-channel words.
    private let emptyHex =
        "aa0128060100cde02f100372c3c7018115b16a3d2a0003000100000000ffff0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000088a5f065"

    // MARK: - version is mapped

    func testV16IsAMappedHistoricalVersion() {
        XCTAssertTrue(mappedWhoop5HistoricalVersions.contains(16),
                      "v16 must be mapped so it stops being raw-archived and is stored via ecgCandidateSample")
    }

    // MARK: - header decodes (record_index@11, unix@15)

    func testV16HeaderDecodes() {
        let p = parseFrame(bytes(fullHex), family: .whoop5)
        XCTAssertEqual(p.typeName, "HISTORICAL_DATA")
        XCTAssertEqual(p.crcOK, true, "fixture must be CRC-valid or the store/archive assertions are meaningless")
        XCTAssertEqual(p.parsed["hist_version"]?.intValue, 16)
        XCTAssertEqual(p.parsed["record_index"]?.intValue, 29_868_937)   // monotonic lifetime counter @11
        XCTAssertEqual(p.parsed["unix"]?.intValue, 1_789_990_296)        // real unix seconds @15

        let e = parseFrame(bytes(emptyHex), family: .whoop5)
        XCTAssertEqual(e.parsed["hist_version"]?.intValue, 16)
        XCTAssertEqual(e.parsed["record_index"]?.intValue, 29_868_914)
        XCTAssertEqual(e.parsed["unix"]?.intValue, 1_789_990_273)
    }

    // MARK: - ecg_candidate: non-empty on a full record, empty on an empty one

    func testV16FullRecordDecodesEcgCandidate() {
        let p = parseFrame(bytes(fullHex), family: .whoop5).parsed
        let samples = try! XCTUnwrap(p["ecg_candidate"]?.intArrayValue,
                                     "a full v16 record must decode a non-empty ecg_candidate array")
        XCTAssertFalse(samples.isEmpty)
        XCTAssertEqual(samples.count, 500)                              // 0x80-class word count
        XCTAssertEqual(p["ecg_candidate_count"]?.intValue, 500)
        // The record DECLARES its word count @32 (u16 LE) and the decoder honours it exactly.
        XCTAssertEqual(p["ecg_candidate_word_count"]?.intValue, 500,
                       "the FIFO is length-prefixed; the stored sample count must equal the declared one")
        // ZERO, not 7. The 7 an earlier revision reported were bytes of the TRAILING region being read as
        // FIFO words; inside the correctly bounded FIFO there is no 0xC0-class word at all.
        XCTAssertEqual(p["ecg_candidate_alt_count"]?.intValue, 0)
        // The raw big-endian 16-bit samples, verbatim (0x83 tag → 0x80 class; sample = byte1<<8|byte2).
        XCTAssertEqual(Array(samples.prefix(6)), [60944, 59816, 62200, 62250, 61898, 61607])
        XCTAssertEqual(samples.last, 57676)
        // Unsigned 16-bit: instrumentation only, no scale/sign asserted.
        XCTAssertTrue(samples.allSatisfy { $0 >= 0 && $0 <= 65535 })
    }

    /// The FIFO must stop where the record says it stops. The body does NOT run to the payload limit: a
    /// different, unidentified structure follows it (a count byte then 16-bit LITTLE-endian values), and
    /// scanning 3-byte words to the end walks into it. That is not a cosmetic over-read — a trailing byte
    /// pair whose alignment puts a high bit in the tag position is admitted as a SAMPLE, contaminating the
    /// one stream this whole layout exists to preserve.
    func testV16FifoStopsAtItsDeclaredLengthAndIgnoresTheTrailingRegion() {
        let frame = bytes(fullHex)
        let p = parseFrame(frame, family: .whoop5).parsed
        let declared = try! XCTUnwrap(p["ecg_candidate_word_count"]?.intValue)
        let samples = try! XCTUnwrap(p["ecg_candidate"]?.intArrayValue)

        // The declared body ends well before the payload limit — the gap IS the trailing region.
        let fifoEnd = 34 + declared * 3
        let payloadLimit = frame.count - 4
        XCTAssertEqual(fifoEnd, 1534)
        XCTAssertLessThan(fifoEnd, payloadLimit,
                          "fixture must actually HAVE a trailing region, or this proves nothing")

        // Every stored sample must be reconstructible from a word inside [34, fifoEnd) — i.e. none of them
        // came from beyond the declared FIFO.
        var expected: [Int] = []
        for off in stride(from: 34, to: fifoEnd, by: 3) where frame[off] & 0x80 != 0 {
            expected.append((Int(frame[off + 1]) << 8) | Int(frame[off + 2]))
        }
        XCTAssertEqual(samples, expected)

        // And the trailing region really does contain bytes a 3-byte scan would have taken: the `0xed`/
        // `0xff` run. This is the exact byte pattern that produced the phantom "0xC0 channel".
        let trailing = Array(frame[fifoEnd..<payloadLimit])
        XCTAssertTrue(trailing.contains(0xed) && trailing.contains(0xff),
                      "the trailing region must still hold the high-bit bytes an unbounded scan consumed")
    }

    func testV16EmptyRecordHasNoEcgCandidate() {
        let p = parseFrame(bytes(emptyHex), family: .whoop5).parsed
        XCTAssertNil(p["ecg_candidate"], "a v16 record declaring 0 FIFO words carries no samples")
        XCTAssertNil(p["ecg_candidate_count"])
        XCTAssertEqual(p["ecg_candidate_word_count"]?.intValue, 0, "the record declares an empty FIFO")
        XCTAssertEqual(p["ecg_candidate_alt_count"]?.intValue, 0, "no 0xC0-class words either")
    }

    /// A corrupt/oversized length must clamp to the payload, never read into the CRC trailer or past the
    /// end of the frame. Built by overwriting the declared count with 0xFFFF on the real fixture.
    func testV16OversizedDeclaredLengthIsClampedToThePayload() {
        var frame = bytes(fullHex)
        frame[32] = 0xFF
        frame[33] = 0xFF                     // declares 65535 words = 196,605 bytes; the frame is 1584
        let p = parseFrame(frame, family: .whoop5).parsed
        XCTAssertEqual(p["ecg_candidate_word_count"]?.intValue, 65535)
        // It must not crash, and it must not invent more samples than the payload can hold.
        let maxWords = ((frame.count - 4) - 34) / 3
        XCTAssertLessThanOrEqual(p["ecg_candidate"]?.intArrayValue?.count ?? 0, maxWords)
    }

    // MARK: - v16 carries NO named signal — instrumentation only (decodesWithoutNamedSignal)

    func testV16CarriesNoNamedPhysiologicalSignal() {
        let p = parseFrame(bytes(fullHex), family: .whoop5).parsed
        XCTAssertNil(p["heart_rate"], "v16 must not surface a heart rate")
        XCTAssertNil(p["gravity_x"], "v16 must not surface gravity/motion")
        XCTAssertNil(p["ppg_waveform"], "v16 is not the v26 PPG layout")
        XCTAssertNil(p["spo2_red"])
        // Classified as a decoded layout that carries nothing scoreable, exactly like v20/v21.
        XCTAssertEqual(
            historicalLayoutSupport(version: 16, family: .whoop5, hasHeartRate: false,
                                    hasGravity: false, hasPpgWaveform: false),
            .decodesWithoutNamedSignal)
    }

    // MARK: - extractHistoricalStreams banks the candidate durably (twin of ppgWaveform)

    func testExtractHistoricalStreamsBanksEcgCandidateOnlyForFullRecords() {
        let full = parseFrame(bytes(fullHex), family: .whoop5)
        let empty = parseFrame(bytes(emptyHex), family: .whoop5)
        let streams = extractHistoricalStreams([full, empty],
                                               deviceClockRef: 1_789_990_296,
                                               wallClockRef: 1_789_990_296)
        XCTAssertEqual(streams.ecgCandidate.count, 1, "only the full record banks a row; the empty one adds none")
        let row = try! XCTUnwrap(streams.ecgCandidate.first)
        XCTAssertEqual(row.ts, 1_789_990_296)
        XCTAssertEqual(row.samples.count, 500)
        XCTAssertEqual(Array(row.samples.prefix(3)), [60944, 59816, 62200])
        // A v16-only chunk must NOT read as "no sensor records" — it persisted an instrumentation stream.
        XCTAssertFalse(streams.isEmpty)
        // And it truly emits no scoreable stream (instrumentation only).
        XCTAssertTrue(streams.hr.isEmpty && streams.gravity.isEmpty && streams.ppgWaveform.isEmpty)
    }

    func testStreamsIsEmptyConsidersEcgCandidate() {
        var s = Streams()
        XCTAssertTrue(s.isEmpty)
        s.ecgCandidate = [EcgCandidateSample(ts: 1, samples: [1, 2, 3])]
        XCTAssertFalse(s.isEmpty)
    }

    // MARK: - not double-archived: an intact v16 record is skipped by rejectedHistoricalRecords

    func testIntactV16IsNotRawArchived() {
        let full = bytes(fullHex)
        XCTAssertFalse(isUnmappedWhoop5HistoricalRecord(full), "v16 is now a mapped layout")
        XCTAssertTrue(rejectedHistoricalRecords([full], family: .whoop5).isEmpty,
                      "an intact v16 record is stored durably in ecgCandidateSample, so it must not be "
                      + "double-archived as raw history (the sample-bound skip)")
    }

    /// The skip is bound to a row EXISTING, not to a clean verdict. An intact v16 record whose FIFO body
    /// is all padding decodes no samples, so `extractHistoricalStreams` banks nothing for it — archiving
    /// is then the only thing standing between that record and the next trim ack. Making the skip
    /// verdict-bound instead (as v26's is) silently dropped exactly these records.
    func testEmptyV16IsStillRawArchived() {
        let empty = bytes(emptyHex)
        let p = parseFrame(empty, family: .whoop5)
        XCTAssertTrue(p.ok && p.crcOK == true,
                      "fixture is an INTACT record — a verdict-bound skip would drop it, which is the bug")
        XCTAssertNil(p.parsed["ecg_candidate"], "…and it decodes no samples, so no row will be banked")

        let streams = extractHistoricalStreams([p], deviceClockRef: 1_789_990_273,
                                               wallClockRef: 1_789_990_273)
        XCTAssertTrue(streams.ecgCandidate.isEmpty, "premise: the extraction banks nothing for this record")
        XCTAssertEqual(rejectedHistoricalRecords([empty], family: .whoop5), [empty],
                       "so its bytes must survive in the raw archive — otherwise it is stored NOWHERE")
    }

    /// The two fixtures together: the one that banks a row is skipped, the one that does not is archived.
    func testV16ArchiveSplitsOnWhetherARowWillExist() {
        let full = bytes(fullHex)
        let empty = bytes(emptyHex)
        XCTAssertEqual(rejectedHistoricalRecords([full, empty], family: .whoop5), [empty],
                       "every v16 record is stored SOMEWHERE — as a row, or as archived bytes, never neither")
    }

    // MARK: - Codable tolerance (mirrors the ppg_waveform decodeIfPresent guard)

    func testStreamsDecodeToleratesMissingAndPresentEcgCandidate() throws {
        let dec = JSONDecoder()
        let s1 = try dec.decode(Streams.self, from: Data(#"{"hr":[]}"#.utf8))
        XCTAssertTrue(s1.ecgCandidate.isEmpty)
        let json = #"{"ecg_candidate":[{"ts":1789990296,"samples":[60944,59816,62200]}]}"#
        let s2 = try dec.decode(Streams.self, from: Data(json.utf8))
        XCTAssertEqual(s2.ecgCandidate,
                       [EcgCandidateSample(ts: 1_789_990_296, samples: [60944, 59816, 62200])])
        let round = try dec.decode(Streams.self, from: JSONEncoder().encode(s2))
        XCTAssertEqual(round.ecgCandidate, s2.ecgCandidate)
    }
}
