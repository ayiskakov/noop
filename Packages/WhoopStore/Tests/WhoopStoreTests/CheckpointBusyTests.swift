import XCTest
import SQLite3
import WhoopProtocol
@testable import WhoopStore

/// W02-003: a backup copies the main database file alone, so `checkpointWAL()` must not report success
/// while committed pages are still only in the WAL. The two app pools share one file, so a reader on the
/// other pool can hold a snapshot that stops a TRUNCATE checkpoint from finishing.
final class CheckpointBusyTests: XCTestCase {

    private func tempPath() -> String {
        NSTemporaryDirectory() + "whoopstore-ckpt-\(UUID().uuidString).sqlite"
    }

    private func removeDB(_ path: String) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    /// A second connection holding a read transaction open, the way the other pool's reader does.
    private final class HeldReader {
        private var db: OpaquePointer?

        init(path: String) throws {
            guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
                throw NSError(domain: "HeldReader", code: 1)
            }
            // The snapshot starts at the first read inside the transaction and lasts until it ends.
            guard sqlite3_exec(db, "BEGIN; SELECT count(*) FROM hrSample;", nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "HeldReader", code: 2)
            }
        }

        func release() {
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
            sqlite3_close(db)
            db = nil
        }
    }

    private func hrRows(inMainFileOf path: String) throws -> Int {
        // Copy the main file alone, as the backup writer does, and count what it holds.
        let copy = tempPath()
        defer { removeDB(copy) }
        try FileManager.default.copyItem(atPath: path, toPath: copy)
        var db: OpaquePointer?
        guard sqlite3_open_v2(copy, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw NSError(domain: "copy", code: 1)
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM hrSample", -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "copy", code: 2)
        }
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_ROW else {
            throw NSError(domain: "copy", code: Int(rc),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    func testCheckpointThrowsWhileAReaderHoldsAnOlderSnapshot() async throws {
        let path = tempPath()
        defer { removeDB(path) }
        let store = try await WhoopStore(path: path)
        _ = try await store.insert(Streams(hr: [HRSample(ts: 1_000, bpm: 60)]), deviceId: "dev")

        let reader = try HeldReader(path: path)
        defer { reader.release() }
        _ = try await store.insert(Streams(hr: [HRSample(ts: 1_001, bpm: 61),
                                                HRSample(ts: 1_002, bpm: 62)]), deviceId: "dev")

        // Before the fix this returned normally after the busy timeout, and the main file copied alone
        // was malformed (SQLITE_CORRUPT): the checkpoint had written only the pages whose newest frame
        // predates the reader's mark.
        var threw = false
        do { try await store.checkpointWAL() } catch { threw = true }
        XCTAssertTrue(threw, "checkpointWAL must throw while a reader stops it from finishing")
    }

    func testCheckpointSucceedsAndCarriesEveryRowWithNoReader() async throws {
        let path = tempPath()
        defer { removeDB(path) }
        let store = try await WhoopStore(path: path)
        _ = try await store.insert(Streams(hr: [HRSample(ts: 1_000, bpm: 60),
                                                HRSample(ts: 1_001, bpm: 61)]), deviceId: "dev")
        try await store.checkpointWAL()
        XCTAssertEqual(try hrRows(inMainFileOf: path), 2)
    }

    /// The backup path: a snapshot taken while a reader holds an older snapshot and a writer keeps
    /// committing is a whole, readable database with every row committed before it started.
    func testSnapshotIsWholeWhileAReaderAndAWriterAreActive() async throws {
        let path = tempPath()
        let copy = tempPath()
        defer { removeDB(path); removeDB(copy) }
        let store = try await WhoopStore(path: path)
        _ = try await store.insert(Streams(hr: [HRSample(ts: 1_000, bpm: 60)]), deviceId: "dev")
        let reader = try HeldReader(path: path)
        defer { reader.release() }
        _ = try await store.insert(Streams(hr: [HRSample(ts: 1_001, bpm: 61),
                                                HRSample(ts: 1_002, bpm: 62)]), deviceId: "dev")

        try await store.writeSnapshot(to: copy)
        _ = try await store.insert(Streams(hr: [HRSample(ts: 1_003, bpm: 63)]), deviceId: "dev")

        XCTAssertEqual(try hrRows(inFile: copy), 3, "the snapshot holds every row committed before it")
    }

    private func hrRows(inFile path: String) throws -> Int {
        var db: OpaquePointer?
        // Read-write: the copy keeps the source's WAL flag, as the live main file (and every earlier
        // backup) does, and a read-only open of a WAL-flagged file with no -shm cannot start.
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw NSError(domain: "snapshot", code: 1)
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM hrSample", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else {
            sqlite3_finalize(stmt)
            throw NSError(domain: "snapshot", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        defer { sqlite3_finalize(stmt) }
        return Int(sqlite3_column_int64(stmt, 0))
    }
}
