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
            snapshot: { url in (try? await store.writeSnapshot(to: url.path)) != nil },
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
