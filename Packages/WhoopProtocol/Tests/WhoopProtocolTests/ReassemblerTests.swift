import XCTest
@testable import WhoopProtocol

final class ReassemblerTests: XCTestCase {
    // Build a real ~1928-byte type-43 frame from a 1917-byte synthetic payload so the
    // test is self-contained (no capture dependency): inner = 1917+3, length = 1924,
    // total = 1928. Reassembly must reproduce it exactly from 244-byte fragments.
    private func bigFrame() -> [UInt8] {
        let payload = (0..<1917).map { UInt8($0 & 0xFF) }
        return w5Frame(payload, type: 43, seq: 7, cmd: 0)
    }

    func testReassembleFromFragments() {
        let frame = bigFrame()
        XCTAssertEqual(frame.count, 1932)
        var fragments: [[UInt8]] = []
        var i = 0
        while i < frame.count {
            fragments.append(Array(frame[i..<min(i + 244, frame.count)]))
            i += 244
        }
        XCTAssertEqual(fragments.count, 8)
        // Only the first fragment carries the 0xAA SOF.
        XCTAssertEqual(fragments[0].first, 0xAA)
        for f in fragments.dropFirst() {
            XCTAssertNotEqual(f.first, 0xAA)
        }
        let r = Reassembler()
        var assembled: [[UInt8]] = []
        for f in fragments {
            assembled.append(contentsOf: r.feed(f))
        }
        XCTAssertEqual(assembled.count, 1)
        XCTAssertEqual(assembled[0], frame)
    }

    func testTwoFramesInOneFeed() {
        let a = w5Frame([0x01, 0x02], type: 40)
        let b = w5Frame([0x03, 0x04], type: 48)
        let r = Reassembler()
        let out = r.feed(a + b)
        XCTAssertEqual(out, [a, b])
    }

    func testReassembleFromOneBytePerFragment() {
        // Two back-to-back frames, fed a single byte per fragment. This is the worst case for the old
        // removeFirst drain and exercises the offset/compact window hard: head advances byte by byte,
        // compact() slides the tail every feed(). Output must still be the two exact frames, in order.
        let a = w5Frame([0x01, 0x02], type: 40)
        let b = w5Frame([0x03, 0x04], type: 48)
        let r = Reassembler()
        var out: [[UInt8]] = []
        for byte in a + b {
            out.append(contentsOf: r.feed([byte]))
        }
        XCTAssertEqual(out, [a, b])
    }

    func testLeadingGarbageIsSkipped() {
        let a = w5Frame([0x09], type: 40)
        let r = Reassembler()
        let out = r.feed([0x11, 0x22, 0x33] + a)
        XCTAssertEqual(out, [a])
    }

    func testPartialFrameWaitsForRest() {
        let a = w5Frame([0x01, 0x02, 0x03, 0x04], type: 40)
        let r = Reassembler()
        XCTAssertTrue(r.feed(Array(a[0..<5])).isEmpty)        // header + part
        XCTAssertEqual(r.feed(Array(a[5..<a.count])), [a])    // remainder completes it
    }

    func testOversizedDeclaredLengthResyncsInsteadOfWedging() {
        // A corrupt/misaligned 0xAA declaring an impossibly large length (a bit-flip or a spurious
        // mid-frame SOF) must be dropped so the stream resyncs to the next real frame. Without the
        // ceiling, feed() would wait forever for bytes that can never arrive and the live stream
        // would freeze until a reconnect. (Reimplemented from @vulnix0x4's PR #374.)
        let valid = w5Frame([0x09], type: 40)
        let r = Reassembler()
        // Spurious SOF with a 0xFFFF length (total 65539, far past the 8 KB ceiling), then a real
        // frame. With the cap, the real frame emerges instead of the stream wedging.
        let out = r.feed([0xAA, 0x01, 0xFF, 0xFF] + valid)
        XCTAssertEqual(out, [valid], "a garbage oversized SOF must not wedge the stream")
    }

    /// A false start-of-frame whose declared length is PLAUSIBLE, which the floor and ceiling guards
    /// both accept. Before the header-checksum gate, feed() waited for that many bytes and emitted them
    /// as a single frame, consuming the valid frames that fell inside it — they never reached a parser
    /// and nothing downstream could put them back, because the CRC32 that rejects the bad frame runs
    /// after `head` has advanced past them (W01-003).
    ///
    /// Declared length 0x0064 gives total 108: past the 5/MG floor, far under the 8 KB ceiling. The two
    /// header-CRC bytes are deliberately wrong, which is what a payload byte read as a frame start does.
    func testFalseSOFWithAnInRangeLengthDoesNotSwallowTheFramesBehindIt() {
        let first = w5Frame([0x01, 0x02, 0x03], type: 40)
        let second = w5Frame([0x04, 0x05], type: 48)
        let header: [UInt8] = [0xAA, 0x01, 0x64, 0x00, 0x00, 0x00]
        let wrong = crc16Modbus(header) ^ 0xFFFF
        let falseSOF = header + [UInt8(wrong & 0xFF), UInt8(wrong >> 8)]
        let r = Reassembler()
        let out = r.feed(falseSOF + first + second)
        XCTAssertEqual(out, [first, second],
                       "a false SOF must resync by one byte, not eat the frames behind it")
        XCTAssertEqual(r.headerChecksumDrops, 1, "and the drop must be counted, not silent")
    }

    /// The gate must not cost a real frame. Every valid frame carries a correct header checksum, so
    /// this is the half that would break loudly if the CRC span or byte order were wrong.
    func testAValidFrameStillPassesTheHeaderGate() {
        let frame = w5Frame([0x09, 0x08, 0x07], type: 40)
        let r = Reassembler()
        XCTAssertEqual(r.feed(frame), [frame])
        XCTAssertEqual(r.headerChecksumDrops, 0, "a real frame must never be counted as a false SOF")
    }

    /// A false SOF with nothing behind it is rejected by its CRC-16 header, emits nothing, and is counted.
    func testALoneFalseSOFIsCountedAndEmitsNothing() {
        let r = Reassembler(family: .whoop5)
        // 0xAA, fmt, declared length 0x0040 (total 72: in range), header bytes, then a bad CRC16.
        let falseSOF: [UInt8] = [0xAA, 0x01, 0x40, 0x00, 0x00, 0x00, 0xFF, 0xFF]
        let out = r.feed(falseSOF)
        XCTAssertEqual(out, [], "nothing to emit")
        XCTAssertEqual(r.headerChecksumDrops, 1, "the bad 5/MG header must be counted and resynced")
    }

    // MARK: - W01-003 on real frames

    private func realV18Frames() throws -> (worn: [UInt8], oneRR: [UInt8]) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "decoder_oracle", withExtension: "json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let frames = try XCTUnwrap(json["frames"] as? [[String: Any]])
        func frame(_ name: String) throws -> [UInt8] {
            let hex = try XCTUnwrap(frames.first { $0["name"] as? String == name }?["hex"] as? String)
            return stride(from: 0, to: hex.count, by: 2).map {
                let i = hex.index(hex.startIndex, offsetBy: $0)
                return UInt8(hex[i...hex.index(after: i)], radix: 16)!
            }
        }
        return (try frame("whoop5_v18_real_worn"), try frame("whoop5_v18_real_one_rr"))
    }

    private func intactFrames(_ stream: [UInt8], fragment: Int) -> Int {
        let r = Reassembler()
        var out: [[UInt8]] = []
        var k = 0
        while k < stream.count {
            let e = min(k + fragment, stream.count)
            out += r.feed(Array(stream[k..<e]))
            k = e
        }
        return out.filter { verifyFrame($0, family: .whoop5).ok }.count
    }

    /// A leftover tail holding 0xAA and a length word that declares 1000 bytes, ahead of 12 real v18
    /// records in 244-byte BLE fragments. Before the header gate: 4 frames emitted, 3 intact, 9 records
    /// swallowed into one 1000-byte blob.
    func testStraySOFAheadOfRealRecordsLosesNone() throws {
        let (worn, oneRR) = try realV18Frames()
        var stream: [UInt8] = [0x11, 0x22, 0xAA, 0x01, 0xE0, 0x03, 0x33, 0x44]
        for _ in 0..<6 { stream += worn + oneRR }
        XCTAssertEqual(intactFrames(stream, fragment: 244), 12)
    }

    /// One real record whose length byte flipped, then 10 real records. Before the header gate: 2 frames
    /// emitted, 1 intact.
    func testACorruptLengthLosesOnlyItsOwnRecord() throws {
        let (worn, oneRR) = try realV18Frames()
        var bad = worn
        bad[3] = 0x04
        var stream = bad
        for _ in 0..<10 { stream += oneRR }
        XCTAssertEqual(intactFrames(stream, fragment: stream.count), 10)
    }

    /// Why BLEManager rebuilds the reassembler when a link drops (W06-033): the half of a real record the
    /// dropped link delivered has a genuine header, so the gate keeps it, and it takes the next link's
    /// first record as its tail. A fresh reassembler loses nothing.
    func testAPartialRecordFromADroppedLinkCostsTheNextLinkItsFirstRecord() throws {
        let (worn, oneRR) = try realV18Frames()
        var nextLink: [UInt8] = []
        for _ in 0..<10 { nextLink += oneRR }

        let carried = Reassembler()
        XCTAssertTrue(carried.feed(Array(worn.prefix(60))).isEmpty, "precondition: the head waits for its tail")
        let afterCarry = carried.feed(nextLink).filter { verifyFrame($0, family: .whoop5).ok }.count
        XCTAssertEqual(afterCarry, 9)

        XCTAssertEqual(Reassembler().feed(nextLink).filter { verifyFrame($0, family: .whoop5).ok }.count, 10)
    }
}
