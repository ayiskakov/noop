import XCTest
@testable import Strand

final class TestBundleAssemblerTests: XCTestCase {

    func testReScrubsEveryFileIncludingRawCapture() {
        // A serial that never went through the append(log:) sink, e.g. embedded in raw-capture console text.
        let rawWithSerial = "{\"console\":\"connected to WHOOP 4C1594026 ok\"}"
        let entries = [
            FileExport.BundleEntry(name: "report.txt", data: Data("clean line".utf8)),
            FileExport.BundleEntry(name: "raw-capture.jsonl", data: Data(rawWithSerial.utf8)),
        ]
        let scrubbed = TestBundleAssembler.redactEntries(entries)
        let raw = scrubbed.first { $0.name == "raw-capture.jsonl" }!
        let text = String(data: raw.data, encoding: .utf8)!
        XCTAssertFalse(text.contains("4C1594026"), "the injected serial must be scrubbed")
        XCTAssertTrue(text.contains("WHOOP <serial>"))
    }

    func testMetaJsonIsNotMangledButStillPasses() {
        // meta.json has no PII shapes, so it should pass through byte-identical.
        let json = Data("{\"schema\":1,\"redaction\":\"v2\"}".utf8)
        let scrubbed = TestBundleAssembler.redactEntries([FileExport.BundleEntry(name: "meta.json", data: json)])
        XCTAssertEqual(scrubbed.first!.data, json)
    }

    func testStampsRedactionV2() {
        XCTAssertEqual(TestBundleAssembler.redactionVersion, "v2")
    }

    func testCapTruncatesRawCaptureTailAndFlags() {
        // report.txt + meta.json are small; raw-capture blows the cap. We keep the most-recent tail.
        let small = FileExport.BundleEntry(name: "report.txt", data: Data("small".utf8))
        let oversized = String(repeating: "x", count: 40 * 1024 * 1024)  // 40 MB of raw-capture
        let entries = [small, FileExport.BundleEntry(name: "raw-capture.jsonl", data: Data(oversized.utf8))]

        let (capped, truncated) = TestBundleAssembler.capEntries(entries, capBytes: 20 * 1024 * 1024)
        XCTAssertTrue(truncated, "the bundle exceeded the cap so truncated must be true")
        let total = capped.reduce(0) { $0 + $1.data.count }
        XCTAssertLessThanOrEqual(total, 20 * 1024 * 1024)
        // report.txt is preserved in full; only raw-capture is trimmed.
        XCTAssertEqual(capped.first { $0.name == "report.txt" }?.data, small.data)
        let raw = capped.first { $0.name == "raw-capture.jsonl" }!
        XCTAssertLessThan(raw.data.count, oversized.utf8.count)
        // We keep the TAIL (most recent), so the last byte survives.
        XCTAssertEqual(raw.data.last, Data(oversized.utf8).last)
    }

    func testCapSnapsTrimmedTailToLineBoundary() {
        // A raw byte-count tail can (and in production did) land mid-record, shipping a file with a
        // corrupted first line. Every trimmable name is newline-delimited JSONL, so the trimmed tail must
        // always start at a clean line boundary.
        let small = FileExport.BundleEntry(name: "report.txt", data: Data("small".utf8))
        let lines = (1...2000).map { "{\"n\":\($0),\"pad\":\"\(String(repeating: "x", count: 50))\"}" }
        let raw = FileExport.BundleEntry(name: "raw-capture.jsonl", data: Data(lines.joined(separator: "\n").utf8))
        // Force a mid-file trim at a cap unlikely to land exactly on a newline.
        let cap = raw.data.count / 2
        let (capped, truncated) = TestBundleAssembler.capEntries([small, raw], capBytes: cap)
        XCTAssertTrue(truncated)
        let cappedRaw = capped.first { $0.name == "raw-capture.jsonl" }!
        let text = String(data: cappedRaw.data, encoding: .utf8)!
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(text.hasPrefix("{"), "trimmed tail must start at a clean line boundary, got: \(text.prefix(30))")
        // Every kept line must still be valid JSON (no partial record survived).
        for line in text.split(separator: "\n") {
            XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                            "corrupted line survived trimming: \(line.prefix(30))")
        }
    }

    func testTrimToLineBoundaryHandlesNoNewline() {
        // A single-line (or already-empty) entry has nothing to snap to - returned unchanged, never worse.
        let noNewline = Data("no newline here".utf8)
        XCTAssertEqual(TestBundleAssembler.trimToLineBoundary(noNewline), noNewline)
        XCTAssertEqual(TestBundleAssembler.trimToLineBoundary(Data()), Data())
    }

    func testCapLeavesUndersizedBundleUntouched() {
        let entries = [FileExport.BundleEntry(name: "report.txt", data: Data("tiny".utf8))]
        let (capped, truncated) = TestBundleAssembler.capEntries(entries, capBytes: 20 * 1024 * 1024)
        XCTAssertFalse(truncated)
        XCTAssertEqual(capped, entries)
    }


    func testFairAllowancesIsWaterFillingAndNeverBreachesBudget() {
        // Classic water-filling: 1 fits whole, 10 takes its share of what is left, 30 takes the rest.
        let a = TestBundleAssembler.fairAllowances(
            sizes: [("big", 30), ("small", 1), ("mid", 10)], budget: 20)
        XCTAssertEqual(a["small"], 1)                                    // whole, under any share
        XCTAssertEqual(a["mid"], 9)                                      // (20-1)/2
        XCTAssertEqual(a["big"], 10)                                     // the remainder
        XCTAssertEqual(a.values.reduce(0, +), 20)                        // budget fully used
        // Input order must not change the answer.
        let b = TestBundleAssembler.fairAllowances(
            sizes: [("small", 1), ("mid", 10), ("big", 30)], budget: 20)
        XCTAssertEqual(a, b)
        // Everything fits: nobody is trimmed.
        XCTAssertEqual(TestBundleAssembler.fairAllowances(sizes: [("x", 3), ("y", 4)], budget: 100),
                       ["x": 3, "y": 4])
        // Degenerate budgets stay in range rather than going negative.
        XCTAssertEqual(TestBundleAssembler.fairAllowances(sizes: [("x", 5)], budget: 0), ["x": 0])
        XCTAssertEqual(TestBundleAssembler.fairAllowances(sizes: [], budget: 10), [:])
        // A single trimmable stream still gets the WHOLE remainder — the original behaviour, unchanged.
        XCTAssertEqual(TestBundleAssembler.fairAllowances(sizes: [("only", 999)], budget: 42), ["only": 42])
    }
}
