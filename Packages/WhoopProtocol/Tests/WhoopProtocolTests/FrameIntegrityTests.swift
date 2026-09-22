import XCTest
@testable import WhoopProtocol

/// The frame-integrity contract: the parse result carries the verifier's FULL verdict plus a
/// non-optional reason, the structural bounds are enforced per device family, and a named inner
/// field is only ever read out of payload bytes.
///
/// Every synthetic frame below is built the way a strap builds one (real CRC-8 / CRC-16-Modbus
/// header checksum, real zlib CRC32 payload trailer, exact declared length) and then broken in
/// exactly ONE way, so each assertion attributes a single cause. The frames taken from the capture
/// corpus are marked as such.
final class FrameIntegrityTests: XCTestCase {

    static func hex(_ s: String) -> [UInt8] { FramingTests.hex(s) }

    // MARK: - Fixtures

    /// Synthetic, fully valid WHOOP 5.0/MG COMMAND_RESPONSE frame (20 bytes).
    static let w5Valid = "aa010c000001e74124070211223344557481f36e"

    /// Total 12 bytes (declared 4): a WHOOP 5.0 frame one byte below the minimum, again with both
    /// checksums correct. Its byte at offset 8 — the inner packet type — is the first byte of its
    /// own CRC32 trailer.
    static let w5Total12 = "aa0104000001e52100000000"

    /// Exactly 13 bytes (declared 5): valid header checksum, valid CRC32 over its single payload
    /// byte, exact length. It PASSES the tightened gate; the sequence number, command byte and
    /// metadata type it appears to carry are all inside its CRC32 trailer.
    static let w5Min13Metadata = "aa0105000001e4dd31b7efdc83"
    /// The same frame at 14 bytes (declared 6). It is fully valid AND the first byte of its trailer
    /// reads 3 = HISTORY_COMPLETE at the metadata-type offset — the forgery F-05 describes. The
    /// sequence number at offset 9 is now a genuine payload byte and must still decode.
    static let w5Meta14FakesHistoryComplete = "aa0106000001e49931530315e675"


    private func corrupt(_ hexString: String, at index: Int) -> [UInt8] {
        var f = Self.hex(hexString)
        f[index] ^= 0xFF
        return f
    }

    // MARK: - Vollständiges Integritätsurteil im Parse-Ergebnis


    func testWhoop5HeaderChecksumWrongPayloadCRCRightIsRejected() {
        let frame = corrupt(Self.w5Valid, at: 6)
        let parsed = parseFrame(frame, family: .whoop5)
        XCTAssertFalse(parsed.ok)
        XCTAssertEqual(parsed.rejectReason, .headerChecksumMismatch)
        XCTAssertEqual(parsed.crcOK, true)
        XCTAssertEqual(parsed.typeName, "COMMAND_RESPONSE")
    }

    func testBelowMinimumLengthOwnsTheReasonWhenPayloadCRCIsUnavailable() {
        // Too short for a CRC32 over any payload byte at all: the structural rule decides it.
        let parsed = parseFrame(Self.hex(Self.w5Total12), family: .whoop5)
        XCTAssertFalse(parsed.ok)
        XCTAssertNil(parsed.crcOK, "the diagnostic stays honest: no CRC32 was computed")
        XCTAssertEqual(parsed.rejectReason, .belowMinimumLength)
    }

    func testFullyValidFrameKeepsItsPositiveVerdictAndFields() {
        let parsed = parseFrame(Self.hex(Self.w5Valid), family: .whoop5)
        XCTAssertTrue(parsed.ok)
        XCTAssertEqual(parsed.rejectReason, .none)
        XCTAssertEqual(parsed.crcOK, true)
        XCTAssertEqual(parsed.typeName, "COMMAND_RESPONSE")
        XCTAssertEqual(parsed.seq, 7)

        let five = parseFrame(Self.hex(Self.w5Valid), family: .whoop5)
        XCTAssertTrue(five.ok)
        XCTAssertEqual(five.rejectReason, .none)
        XCTAssertEqual(five.seq, 7)
    }

    // MARK: - Ablehnungsgrund liegt am Parse-Ergebnis an

    func testConsumerReadsTheReasonFromTheParseResultAlone() {
        // A consumer sees only what it was handed — no frame bytes, no second verify, no second
        // parse. That is the whole point of carrying the reason on the result.
        func report(_ parsed: ParsedFrame) -> FrameRejectReason { parsed.rejectReason }
        XCTAssertEqual(report(parseFrame(corrupt(Self.w5Valid, at: 6), family: .whoop5)), .headerChecksumMismatch)
        XCTAssertEqual(report(parseFrame(corrupt(Self.w5Valid, at: 12), family: .whoop5)), .payloadCRCMismatch)
    }

    func testEveryRejectionReasonIsDistinguishable() {
        var wrongSOF = Self.hex(Self.w5Valid)
        wrongSOF[0] = 0x00
        let trailing = Self.hex(Self.w5Valid) + [0x00]

        let reasons: [FrameRejectReason] = [
            parseFrame(wrongSOF, family: .whoop5).rejectReason,
            parseFrame(Self.hex(Self.w5Total12), family: .whoop5).rejectReason,
            parseFrame(trailing, family: .whoop5).rejectReason,
            parseFrame(corrupt(Self.w5Valid, at: 6), family: .whoop5).rejectReason,
            parseFrame(corrupt(Self.w5Valid, at: 12), family: .whoop5).rejectReason,
            parseFrame(Self.hex(Self.w5Valid), family: .whoop5).rejectReason,
        ]
        XCTAssertEqual(reasons, [.noStartOfFrame, .belowMinimumLength, .lengthMismatch,
                                 .headerChecksumMismatch, .payloadCRCMismatch, .none])
        XCTAssertEqual(Set(reasons).count, reasons.count, "the reasons must not collapse into each other")
        XCTAssertEqual(FrameRejectReason.allCases.count, 6)
    }

    func testValidFrameCarriesNoReason() {
        XCTAssertEqual(parseFrame(Self.hex(Self.w5Valid), family: .whoop5).rejectReason, .none)
        XCTAssertEqual(parseFrame(Self.hex(Self.w5Valid), family: .whoop5).rejectReason, .none)
        XCTAssertEqual(verifyFrame(Self.hex(Self.w5Valid), family: .whoop5).reason, .none)
    }

    func testMissingReasonInAnOlderSerialisedResultDecodesAsNone() throws {
        // Capture files and hand-written fixtures predate the field; decoding must not turn strict.
        let json = Data("""
        {"ok":true,"typeName":"REALTIME_DATA","crcOK":true,"lenBytes":28,"rawHex":"",
         "fields":[],"parsed":{}}
        """.utf8)
        let decoded = try JSONDecoder().decode(ParsedFrame.self, from: json)
        XCTAssertEqual(decoded.rejectReason, .none)
    }

    // MARK: - Strukturelle Mindest- und Genaulänge je Gerätefamilie


    func testWhoop5BelowMinimumLengthIsRejectedInsteadOfReadingTheTrailer() {
        let frame = Self.hex(Self.w5Total12)
        let check = verifyFrame(frame, family: .whoop5)
        XCTAssertFalse(check.ok)
        XCTAssertEqual(check.reason, .belowMinimumLength)
        // Its header checksum is genuinely correct (recomputed here, since a frame this short is not
        // read at all any more), so only the structural minimum stands between it and the gates —
        // and its "inner packet type" would be the first byte of its own CRC32 trailer.
        XCTAssertEqual(crc16Modbus(Array(frame[0..<6])), UInt16(frame[6]) | (UInt16(frame[7]) << 8))
        XCTAssertNil(check.crc8OK, "nothing is read out of a frame below the minimum")
        let parsed = parseFrame(frame, family: .whoop5, collectFields: true)
        XCTAssertEqual(parsed.typeName, "INVALID/FRAGMENT")
        XCTAssertTrue(parsed.parsed.isEmpty)
    }

    func testAFrameExactlyAtTheFamilyMinimumStaysValid() {
        let w5 = Self.hex(Self.w5Min13Metadata)
        XCTAssertEqual(w5.count, FrameLimits.whoop5MinimumFrameBytes)
        XCTAssertTrue(verifyFrame(w5, family: .whoop5).ok)
    }

    func testOneByteTooManyIsRejected() {
        for (h, family) in [(Self.w5Valid, DeviceFamily.whoop5)] {
            let frame = Self.hex(h) + [0x00]
            let check = verifyFrame(frame, family: family)
            XCTAssertFalse(check.ok, "trailing bytes must be rejected (\(family))")
            XCTAssertEqual(check.reason, .lengthMismatch, "\(family)")
            // The payload CRC still verifies — the envelope is what is wrong, and the diagnostic
            // must say so rather than blame the payload.
            XCTAssertEqual(check.crc32OK, true, "\(family)")
            XCTAssertFalse(parseFrame(frame, family: family).ok, "\(family)")
        }
    }

    func testOneByteTooFewIsRejected() {
        for (h, family) in [(Self.w5Valid, DeviceFamily.whoop5)] {
            let frame = Array(Self.hex(h).dropLast())
            let check = verifyFrame(frame, family: family)
            XCTAssertFalse(check.ok, "a truncated frame must be rejected (\(family))")
            XCTAssertEqual(check.reason, .lengthMismatch, "\(family)")
            XCTAssertNil(check.crc32OK, "a CRC over bytes we do not have is not computed (\(family))")
            XCTAssertFalse(parseFrame(frame, family: family).ok, "\(family)")
        }
    }

    // MARK: - Innere Felder werden nur aus Nutzdatenbytes gelesen

    func testWhoop5AtTheMinimumDecodesNoSequenceCommandOrMetadataField() {
        let frame = Self.hex(Self.w5Min13Metadata)
        let parsed = parseFrame(frame, family: .whoop5, collectFields: true)
        // It passes the gate — which is exactly why the field bound has to hold on its own.
        XCTAssertTrue(parsed.ok)
        XCTAssertEqual(parsed.typeName, "METADATA")
        XCTAssertNil(parsed.seq, "offset 9 is the first byte of the CRC32 trailer")
        XCTAssertNil(parsed.parsed["meta_type"], "offset 10 is trailer, not a metadata type")
        XCTAssertNil(parsed.parsed["cmd"])
        XCTAssertFalse(parsed.fields.contains { $0.name == "seq" })
    }

    func testWhoop5OneByteAboveTheMinimumDecodesTheSequenceButNotTheMetadataType() {
        let frame = Self.hex(Self.w5Meta14FakesHistoryComplete)
        XCTAssertEqual(frame.count, 14)
        let parsed = parseFrame(frame, family: .whoop5, collectFields: true)
        XCTAssertTrue(parsed.ok, "the frame is fully valid — nothing but the bound protects it")
        // Offset 9 is now a genuine payload byte.
        XCTAssertEqual(parsed.seq, 83)
        // Offset 10 holds 0x03 — the byte that means HISTORY_COMPLETE — but it is the first byte of
        // the CRC32 trailer, so no metadata type is decoded from it.
        XCTAssertEqual(frame[10], 3)
        XCTAssertNil(parsed.parsed["meta_type"],
                     "a frame must not be able to forge a chunk state out of its own checksum")
        XCTAssertNil(parsed.parsed["cmd"])
    }




    // MARK: - Zusammensetzer gibt keinen unterlangen Rahmen aus


    func testWhoop5ReassemblerDropsAnUndersizedStartOfFrameAndResyncs() {
        let undersized = Self.hex(Self.w5Total12)    // declares a total of 12 bytes
        let valid = Self.hex(Self.w5Valid)
        let r = Reassembler(family: .whoop5)
        XCTAssertEqual(r.feed(undersized + valid), [valid])
        XCTAssertEqual(r.belowMinimumLengthDrops, 1)
    }

    func testReassemblerLeavesFragmentedDeliveryByteIdentical() {
        let valid = Self.hex(Self.w5Valid)
        let r = Reassembler()
        var out: [[UInt8]] = []
        for chunk in stride(from: 0, to: valid.count, by: 5) {
            out += r.feed(Array(valid[chunk..<min(chunk + 5, valid.count)]))
        }
        XCTAssertEqual(out, [valid])
        XCTAssertEqual(r.belowMinimumLengthDrops, 0)
    }

    // MARK: - Echte aufgezeichnete Rahmen bleiben gültig

    private struct HexEntry: Decodable { let hex: String }
    private struct FamilyHexEntry: Decodable { let hex: String; let family: String? }
    private struct DecoderOracleFile: Decodable { let frames: [FamilyHexEntry] }
    private struct OpticalOracleFile: Decodable { let records: [HexEntry] }

    private func resource(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"),
                                "missing \(name).json test resource")
        return try Data(contentsOf: url)
    }

    /// Every real frame the package's capture corpus holds must keep a POSITIVE verdict under the
    /// tightened rules — minimum length, exact length, header checksum and payload CRC32 together.
    /// This is the regression guard for the whole change: the corpus is what a strap actually sent.
    func testEveryRecordedFrameInTheCorpusStaysValid() throws {
        var checked = 0
        func assertValid(_ hexString: String, _ family: DeviceFamily, _ label: String) {
            let frame = Self.hex(hexString)
            let check = verifyFrame(frame, family: family)
            XCTAssertTrue(check.ok, "\(label) (\(frame.count) B) rejected: \(check.reason)")
            XCTAssertEqual(check.reason, .none, "\(label)")
            XCTAssertTrue(parseFrame(frame, family: family).ok, "\(label)")
            checked += 1
        }

        let dec = JSONDecoder()
        for (i, e) in try dec.decode(DecoderOracleFile.self, from: resource("decoder_oracle")).frames.enumerated() {
            assertValid(e.hex, .whoop5, "decoder_oracle.json #\(i)")
        }
        for (i, e) in try dec.decode(OpticalOracleFile.self,
                                     from: resource("r20_optical_oracle")).records.enumerated() {
            assertValid(e.hex, .whoop5, "r20_optical_oracle.json #\(i)")
        }
        XCTAssertEqual(checked, 10, "the corpus size is pinned so a lost resource cannot pass as green")
    }
}
