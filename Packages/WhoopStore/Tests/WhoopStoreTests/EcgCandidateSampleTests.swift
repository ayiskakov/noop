import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

/// v47 migration: durable storage for the WHOOP 5/MG v16 MAX86176 FIFO 0x80-channel (#891).
///
/// EXPLICITLY UNVALIDATED INSTRUMENTATION — the twin of `PpgWaveformSampleTests`. Adding v16 to
/// `mappedWhoop5HistoricalVersions` took it off the raw-archive path, so the FIFO body is stored here or
/// it is lost; these tests prove the new table exists, its key/shape, that insert/read round-trips, and
/// that the packed BLOB survives a write + read cycle intact — including UNSIGNED samples above 32767,
/// which is the one place this table's packing deliberately differs from the signed PPG waveform. They
/// assert NOTHING physiological: this is not an ECG, heart rate, or diagnosis.
final class EcgCandidateSampleTests: XCTestCase {
    // Realistic v16 candidate values: unsigned 16-bit big-endian FIFO words near the top of the range
    // (the real capture reads ~57k–62k), which is exactly where a signed round trip would flip the sign.
    private let realSamples = [60944, 59816, 62200, 62250, 61898, 61607, 57676, 0, 65535, 1]

    func testV47CreatesEcgCandidateTable() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("ecgCandidateSample"))
    }

    func testEcgCandidatePrimaryKeyIsDeviceIdTs() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.primaryKeyColumns("ecgCandidateSample")
        XCTAssertEqual(cols, ["deviceId", "ts"])
    }

    func testEcgCandidateTableShape() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "ecgCandidateSample")
        XCTAssertEqual(Set(cols), ["deviceId", "ts", "samples"])
    }

    func testEcgCandidateInsertRoundTripAndDedup() async throws {
        let store = try await WhoopStore.inMemory()
        let streams = Streams(ecgCandidate: [EcgCandidateSample(ts: 1_789_990_296, samples: realSamples)])
        _ = try await store.insert(streams, deviceId: "my-whoop")
        let n1 = try await store.ecgCandidateCountForTest()
        XCTAssertEqual(n1, 1)
        let read = try await store.ecgCandidateSamples(deviceId: "my-whoop",
                                                       from: 1_789_990_296, to: 1_789_990_296)
        XCTAssertEqual(read, [EcgCandidateSample(ts: 1_789_990_296, samples: realSamples)],
                       "unsigned 16-bit samples (incl. 65535) must survive the round trip unflipped")
        // Idempotent re-insert, ON CONFLICT DO NOTHING (mirrors every other per-second stream's dedupe).
        _ = try await store.insert(streams, deviceId: "my-whoop")
        let n2 = try await store.ecgCandidateCountForTest()
        XCTAssertEqual(n2, 1)
    }

    func testEcgCandidateReadRespectsRangeAndDeviceScope() async throws {
        let store = try await WhoopStore.inMemory()
        let base = 1_789_990_000
        let streams = Streams(ecgCandidate: (0..<5).map {
            EcgCandidateSample(ts: base + $0, samples: [$0, 65535 - $0])
        })
        _ = try await store.insert(streams, deviceId: "dev-a")
        _ = try await store.insert(
            Streams(ecgCandidate: [EcgCandidateSample(ts: base, samples: [7])]), deviceId: "dev-b")

        let read = try await store.ecgCandidateSamples(deviceId: "dev-a", from: base + 1, to: base + 3)
        XCTAssertEqual(read.map(\.ts), [base + 1, base + 2, base + 3])
        XCTAssertEqual(read.map(\.samples), [[1, 65534], [2, 65533], [3, 65532]])

        let other = try await store.ecgCandidateSamples(deviceId: "dev-b", from: base, to: base)
        XCTAssertEqual(other, [EcgCandidateSample(ts: base, samples: [7])])
    }

    /// A short/variable-length record round-trips exactly — the pack format is not fixed to a sample count.
    func testEcgCandidateHandlesShortSampleArray() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.insert(
            Streams(ecgCandidate: [EcgCandidateSample(ts: 500, samples: [40000, 12])]), deviceId: "d")
        let read = try await store.ecgCandidateSamples(deviceId: "d", from: 500, to: 500)
        XCTAssertEqual(read, [EcgCandidateSample(ts: 500, samples: [40000, 12])])
    }

    // MARK: - #891 Test Centre export

    /// The export emits one JSON line per row, ordered by (deviceId, ts), with sorted keys and unsigned
    /// samples — the format the app hands to the iOS share sheet / macOS save panel.
    func testEcgCandidateExportJSONL() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.insert(Streams(ecgCandidate: [
            EcgCandidateSample(ts: 100, samples: [60944, 1]),
            EcgCandidateSample(ts: 101, samples: [65535]),
        ]), deviceId: "dev-a")
        _ = try await store.insert(Streams(ecgCandidate: [
            EcgCandidateSample(ts: 50, samples: [7]),
        ]), deviceId: "dev-b")
        let jsonl = try await store.ecgCandidateExportJSONL()
        let lines = jsonl.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, [
            #"{"deviceId":"dev-a","samples":[60944,1],"ts":100}"#,
            #"{"deviceId":"dev-a","samples":[65535],"ts":101}"#,
            #"{"deviceId":"dev-b","samples":[7],"ts":50}"#,
        ], "one sorted-key JSON object per row, ordered by (deviceId, ts), unsigned samples preserved")
    }

    /// A store with no candidate rows exports an empty string (the button then no-ops rather than
    /// handing the share sheet an empty file).
    func testEcgCandidateExportEmptyStoreIsEmptyString() async throws {
        let store = try await WhoopStore.inMemory()
        let jsonl = try await store.ecgCandidateExportJSONL()
        XCTAssertTrue(jsonl.isEmpty)
    }

    func testPackUnpackEcgCandidateSamplesRoundTripsUnsigned() {
        let samples = [0, 1, 32767, 32768, 65535, 60944, 57676]
        let packed = WhoopStore.packEcgCandidateSamples(samples)
        XCTAssertEqual(packed.count, samples.count * 2, "2 bytes/sample, no per-record overhead")
        XCTAssertEqual(WhoopStore.unpackEcgCandidateSamples(packed), samples,
                       "values above 32767 must NOT be sign-flipped (the deviation from packPpgSamples)")
    }

    func testUnpackEcgCandidateSamplesDropsTrailingOddByte() {
        var data = WhoopStore.packEcgCandidateSamples([1, 2, 3])
        data.append(0xFF)
        XCTAssertEqual(WhoopStore.unpackEcgCandidateSamples(data), [1, 2, 3])
    }

    // MARK: - #891 rolling retention (mirrors ppgWaveform)

    /// The cap keeps the NEWEST rows, swept amortised — the same newest-N property the ppg table rests on.
    func testEcgCandidateRetentionKeepsTheNewestRows() async throws {
        let s = try await WhoopStore.inMemory()
        try await s.upsertDevice(id: "dev1", mac: nil, name: nil)
        for ts in 100...105 {
            _ = try await s.insert(
                Streams(ecgCandidate: [EcgCandidateSample(ts: ts, samples: realSamples)]),
                deviceId: "dev1",
                v18AuxRetentionRows: WhoopStore.v18AuxRetentionRows,
                v18AuxPruneEveryRows: WhoopStore.v18AuxPruneEveryRows,
                ecgCandidateRetentionRows: 2, ecgCandidatePruneEveryRows: 1)
        }
        let rows = try await s.ecgCandidateSamples(deviceId: "dev1", from: 0, to: 1_000)
        XCTAssertEqual(rows.map(\.ts), [104, 105], "newest-N, not oldest-N and not everything")
    }

    /// A batch with no candidate row must not sweep at all (guards against banking the budget off other
    /// streams, exactly like the ppg equivalent).
    func testNoEcgCandidateRowsMeansNoRetentionSweep() async throws {
        let s = try await WhoopStore.inMemory()
        try await s.upsertDevice(id: "dev1", mac: nil, name: nil)
        _ = try await s.insert(
            Streams(ecgCandidate: [EcgCandidateSample(ts: 100, samples: realSamples)]),
            deviceId: "dev1",
            v18AuxRetentionRows: WhoopStore.v18AuxRetentionRows,
            v18AuxPruneEveryRows: WhoopStore.v18AuxPruneEveryRows,
            ecgCandidateRetentionRows: 5, ecgCandidatePruneEveryRows: 1)
        // An HR-only batch banks nothing here, so the cap of 1 must NOT evict the candidate row above.
        _ = try await s.insert(Streams(hr: [HRSample(ts: 200, bpm: 60)]), deviceId: "dev1",
                               v18AuxRetentionRows: WhoopStore.v18AuxRetentionRows,
                               v18AuxPruneEveryRows: WhoopStore.v18AuxPruneEveryRows,
                               ecgCandidateRetentionRows: 1, ecgCandidatePruneEveryRows: 1)
        let rows = try await s.ecgCandidateSamples(deviceId: "dev1", from: 0, to: 1_000)
        XCTAssertEqual(rows.map(\.ts), [100])
    }

    func testProductionRetentionCapMatchesPpgWaveform() {
        XCTAssertEqual(WhoopStore.ecgCandidateRetentionRows, 604_800)
        XCTAssertEqual(WhoopStore.ecgCandidatePruneEveryRows, 10_000)
    }

    /// End-to-end: a real v16 offload frame decodes and banks exactly one candidate row via the same
    /// `extractHistoricalStreams` -> `insert` path the Backfiller uses.
    func testV16FrameDecodesAndBanksThroughInsert() async throws {
        let full = parseFrame(v16FullFrame(), family: .whoop5)
        let streams = extractHistoricalStreams([full], deviceClockRef: 1_789_990_296,
                                               wallClockRef: 1_789_990_296)
        XCTAssertEqual(streams.ecgCandidate.count, 1)
        let store = try await WhoopStore.inMemory()
        _ = try await store.insert(streams, deviceId: "my-whoop")
        let read = try await store.ecgCandidateSamples(deviceId: "my-whoop",
                                                       from: 1_789_990_296, to: 1_789_990_296)
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read.first?.samples.count, 500)
        XCTAssertEqual(Array(read.first!.samples.prefix(3)), [60944, 59816, 62200])
    }

    private func v16FullFrame() -> [UInt8] {
        let s = "aa0128060100cde02f100389c3c7019815b16a3d2a030a000132000000ffff00f40183ee1083e9a883f2f883f32a83f1ca83f0a783f0a483ec8a83f09883ee2283ee9983eb7c83f0c883f48a83f8b983f67c83ed1683eaba83ee5d83e94983ea8683f18583f70f83f52883f33383edef83eaba83ead383e86983eb5b83f05983f16c83f8a383f79d83ec1e83e56a83e8e983ed1e83ea5283ebdb83f0fd83edd883ebd383ed4c83f20783f57583f21083f3d883f35e83ee9583ed8b83ecdf83ed9b83ec8e83f54783f2e683f1f083eae883eb2f83efe683f62683ef2383e9d783e7eb83eb2f83e8e183e8df83eb7983f05d83eed183e85d83f14483f96a83ef5383e70a83e9bd83eb6683f19b83edfe83e58083e72e83e94883ee3683efa783f2ba83f01383ef3f83f00e83e9e683e6a983e7f683eabf83f00383ef1483f1f383f0a383ee6c83ec7983e73d83dec383e25683e61f83e3f183e56983ebd383ee6b83eecc83eacc83ea3583eb3483ec1883eca383f11883f0e983eb8d83ebda83eb4883f13683f06783f36a83ee3383e2dd83e3eb83e9ba83ea2283e80683eccd83e83583e7f483e8fc83e89e83e3ee83e80783ed1283edb283ec5a83eadf83ec4e83ef5d83eb3783e50f83e18a83e42283e9d483e5ab83e95083ef6583f01083ecd383ea4583ebcc83f52283f11b83e9ea83e6a583e64583e48183e8d683e9f083e6b083ebb983ecff83ede683edc883e7e883ea9e83e6f783e8af83e9d283e66783e6bf83f05783f26483f20183eafb83e9c283eabd83f04e83efca83ed4983eddd83e87283e7be83e6db83e5ef83eb0483ef9a83eefb83e8fb83e28f83e50983eb6d83eec783eca083e8e083e52083e9f783e82c83e97a83ec6583e9e083e8df83e63283e1e683e68983eab483e9a583e60883eade83eaad83eb7783eba583e20483e1f683e6c383e91683e6da83e64483e7b583e8d683e93883e60783e68983ec1283e96c83e8a183e94e83e63e83e7ba83ec6883e59283e51483e62983ec1483ecc983ec4e83ea2083e65283e6b883ed4283f1a783f2d883f5b583fbd583fc5b83ffe780012a83fe8a8003ef83ff5d83f64283f05f83e93a83e77983eb4083ec3383e6bc83e16383dad083d7da83d40283cfb383d1fe83d41f83d98383dd0c83dd9f83dffb83e40a83e5b583e36e83e4e983ed2283eeea83ecea83ec2683e9ea83e7ad83e1c983e8db83f0b983f08483edc983eb5183f04583ea6a83e9b683e8e683eb3383ec4783ec2083ea2683ef7283eff383eac783f10b83f03c83ed0283ee9883eda883f05a83f3a383edc283e9f583eab683e92c83e6c683e89583f0f683f01783eeea83efc483ecf483ef7a83ede483f00e83f0c983eae183efb483eff483f2d783f45f83efd483e9e883eaad83f13c83ef7183f06c83f0c483ece683ef2f83efe883eea883f07c83f58783f29883f42883f6bf83f43683f20283f55e83f28c83f42283f20f83f46683f5c383f0f583f57383f72983f6a083f2b383f3ab83f65d83f40f83f74883f88183f98c83f68f83f59683fb4283f9f183f68f83f72383f60f83f71683f6f483efa983ef0283f47183f6dd83f64483f6d083f9b483fa7e83f87483f3d383ef4483efaf83edf083ee2383eb2183e79583e6bf83e94b83f1a183f2b283eeea83f2bd83ed7d83e88b83e94183f03883f19383effb83eb5683e77983e4f683dee683e00a83de8f83df6d83e32283e59483e98e83e75883e7c883dff083da6583dda183e39b83e4dc83e61b83e17483e27683e77283e89883e7da83e27f83df9b83e18283e24983e14083e00e83dd0383de0883e2a583e56083e0e383e52983e80683e29683e5a383dd1583d8bf83e24383e97a83e97483e47283e46a83e0f983dd4483e2ca83e13683e10183e28183e7c883e0da83de3283dba983de8183e41483e80e83e5bb83e35d83de8483dcb083dff883e1b683e52183e2e383e38183e0ca83e66e83e3d283e3eb83e5f983e6df83e8f383e68383e31083dcdb83d94283dd2f83e15083e38283e05083dcd583de2b83e0df83e33183e37b83e5bd83e4b983e51d83e35083e46583e34183dc6583da1983de9b83e39f83e3d483e6d083e85d83e39683e45e83e5a883e68983e5e683e14c0b3f003f003e003e003e003e003e003e003e003e003e00edffedffedffedffedffedffedffedffedffedffedff003c9b1ea9"
        var out = [UInt8](); out.reserveCapacity(s.count / 2); var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j }
        return out
    }
}
