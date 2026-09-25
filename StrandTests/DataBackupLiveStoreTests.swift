import XCTest
import SQLite3
import WhoopProtocol
import WhoopStore
@testable import Strand

/// Backups and restores run while the app's own pools are open on the live file, with committed rows
/// that may still be in the write-ahead log and readers holding older snapshots.
final class DataBackupLiveStoreTests: XCTestCase {

    private var tmp: URL!
    private var suites: [String] = []

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
        for name in suites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        suites = []
    }

    private func freshDefaults() throws -> UserDefaults {
        let name = "backup-live-\(UUID().uuidString)"
        guard let d = UserDefaults(suiteName: name) else { throw TestError("no suite defaults") }
        suites.append(name)
        return d
    }

    /// A valid, checkpointed `.noopbak` of an empty store.
    private func makeBackup() async throws -> URL {
        let source = tmp.appendingPathComponent("source.sqlite")
        do {
            let store = try await WhoopStore(path: source.path)
            try await store.checkpointWAL()
        }
        let backup = tmp.appendingPathComponent("backup.noopbak")
        try DataBackup.writeBackupForTesting(databaseAt: source, to: backup)
        return backup
    }

    /// W02-002: the pre-import snapshot is the user's only copy of the store a restore replaces, so it
    /// must hold the commits still in the WAL that the swap deletes.
    func testPreImportSnapshotHoldsCommitsStillInTheWal() async throws {
        let live = tmp.appendingPathComponent("whoop.sqlite")
        let store = try await WhoopStore(path: live.path)
        let rows = (0..<50).map { HRSample(ts: 1_000 + $0, bpm: 60) }
        _ = try await store.insert(Streams(hr: rows), deviceId: "my-whoop")
        let walBytes = (try FileManager.default.attributesOfItem(atPath: live.path + "-wal")[.size]
                        as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(walBytes, 0, "precondition: the rows are committed but not checkpointed")

        let backup = try await makeBackup()
        guard case .imported(let sidecar) = DataBackup.restore(from: backup, toDatabaseAt: live.path,
                                                               settingsDefaults: try freshDefaults()) else {
            return XCTFail("restore of a valid backup failed")
        }
        XCTAssertNotEqual(sidecar, live, "a live database existed, so a snapshot must have been taken")
        XCTAssertEqual(try hrRows(in: sidecar), 50, "the pre-import snapshot must hold every committed row")
        withExtendedLifetime(store) {}
    }

    /// W02-002 V2 follow-up: when the live file cannot be snapshotted (here it is not a database at all),
    /// the restore keeps it byte for byte instead. A failed snapshot used to leave an empty side file that
    /// then blocked that copy, so the restore aborted.
    func testALiveFileThatCannotBeSnapshottedIsKeptByteForByte() async throws {
        let live = tmp.appendingPathComponent("whoop.sqlite")
        let garbage = Data(repeating: 0x5A, count: 64 * 1024)
        try garbage.write(to: live)
        let backup = try await makeBackup()

        guard case .imported(let sidecar) = DataBackup.restore(from: backup, toDatabaseAt: live.path,
                                                               settingsDefaults: try freshDefaults()) else {
            return XCTFail("the restore must not abort because the old file could not be snapshotted")
        }
        XCTAssertEqual(try Data(contentsOf: sidecar), garbage)
    }

    /// W02-003: a folder backup taken while another connection holds an older snapshot and a writer keeps
    /// committing restores to every row committed before the backup started. Before the fix the export
    /// zipped the live main file after a checkpoint the reader had cut short, which left it malformed.
    func testBackupHoldsEveryCommittedRowWhileAReaderAndAWriterAreActive() async throws {
        let live = tmp.appendingPathComponent("whoop.sqlite")
        let store = try await WhoopStore(path: live.path)
        _ = try await store.insert(Streams(hr: [HRSample(ts: 1_000, bpm: 60)]), deviceId: "my-whoop")
        let reader = try HeldReader(path: live.path)
        _ = try await store.insert(Streams(hr: [HRSample(ts: 1_001, bpm: 61),
                                                HRSample(ts: 1_002, bpm: 62)]), deviceId: "my-whoop")

        let backup = tmp.appendingPathComponent("folder.noopbak")
        let result = await DataBackup.writeBackup(
            snapshot: { url in try await store.writeSnapshot(to: url.path) },
            liveDatabaseAt: live.path, to: backup)
        _ = try await store.insert(Streams(hr: [HRSample(ts: 1_003, bpm: 63)]), deviceId: "my-whoop")
        reader.release()
        guard case .exported = result else { return XCTFail("backup failed: \(result)") }

        let restored = tmp.appendingPathComponent("restored.sqlite")
        guard case .imported = DataBackup.restore(from: backup, toDatabaseAt: restored.path,
                                                  settingsDefaults: try freshDefaults()) else {
            return XCTFail("the backup does not restore")
        }
        XCTAssertEqual(try hrRows(in: restored), 3, "the backup holds every row committed before it began")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())
            .filter { $0.hasPrefix("noop-export-") }
        XCTAssertEqual(leftovers, [], "the staged snapshot is removed after the archive is written")
    }

    // MARK: - Helpers

    /// A second connection holding a read transaction open, the way the other pool's reader does.
    private final class HeldReader {
        private var db: OpaquePointer?

        init(path: String) throws {
            guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
                  sqlite3_exec(db, "BEGIN; SELECT count(*) FROM hrSample;", nil, nil, nil) == SQLITE_OK else {
                throw TestError("reader failed")
            }
        }

        func release() {
            guard db != nil else { return }
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
            sqlite3_close(db)
            db = nil
        }

        deinit { release() }
    }

    private func hrRows(in url: URL) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw TestError("open failed: \(url.lastPathComponent)")
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM hrSample", -1, &stmt, nil) == SQLITE_OK else {
            throw TestError("prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw TestError("step failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private struct TestError: Error, CustomStringConvertible {
        let description: String
        init(_ m: String) { description = m }
    }
}
