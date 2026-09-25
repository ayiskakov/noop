import XCTest
import SQLite3
import ZIPFoundation
import WhoopStore
@testable import Strand

/// Phase 1 exit gate of the whole-project review (`docs/review/README.md`): real backups migrate to the
/// head schema without losing a row, and a `.noopbak` export → import round trip reproduces every table
/// and every whitelisted setting.
///
/// Runs only when `NOOP_GATE_BACKUPS` names one or more `.noopbak` files, colon-separated; otherwise it
/// skips, so CI and ordinary runs never see it. The files are the owner's data and never enter git:
///
///     TEST_RUNNER_NOOP_GATE_BACKUPS=/path/a.noopbak:/path/b.noopbak xcodebuild … test \
///       -only-testing:StrandTests/RealBackupGateTests
///
/// Rows are compared by an order-independent digest over every column, so the check says whether the
/// data survived, never what it holds. Output is limited to table and row counts.
final class RealBackupGateTests: XCTestCase {

    private var tmp: URL!
    private var suites: [String] = []

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("real-backup-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
        for name in suites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        suites = []
    }

    func testRealBackupsMigrateToHeadAndRoundTrip() async throws {
        guard let list = ProcessInfo.processInfo.environment["NOOP_GATE_BACKUPS"], !list.isEmpty else {
            throw XCTSkip("Set NOOP_GATE_BACKUPS to run the real-backup gate")
        }
        for (i, path) in list.split(separator: ":").enumerated() {
            try await checkBackup(URL(fileURLWithPath: String(path)), index: i)
        }
    }

    private func checkBackup(_ backup: URL, index: Int) async throws {
        let label = "backup \(index)"
        let dir = tmp.appendingPathComponent("b\(index)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 1. Import through the app's restore core into a throwaway path.
        let first = dir.appendingPathComponent("first.sqlite")
        let firstDefaults = try freshDefaults()
        guard case .imported = DataBackup.restore(from: backup, toDatabaseAt: first.path,
                                                  settingsDefaults: firstDefaults) else {
            return XCTFail("\(label): restore failed")
        }
        let shipped = try settingsEntry(of: backup)
        let settings = BackupSettings.snapshot(from: firstDefaults)
        XCTAssertEqual(NSDictionary(dictionary: settings), NSDictionary(dictionary: shipped),
                       "\(label): the settings a restore applies read back as the settings the backup carried")

        let columnsBefore = try columns(of: first)
        let migrationsBefore = try strings(in: first, sql: "SELECT identifier FROM grdb_migrations")
        let before = try digests(of: first, restrictTo: columnsBefore)

        // 2. Open with the real store: runs every pending migration, then flush the WAL into the file.
        do {
            let store = try await WhoopStore(path: first.path)
            try await store.checkpointWAL()
        }
        let migrationsAfter = try strings(in: first, sql: "SELECT identifier FROM grdb_migrations")
        let head = try await headMigrations(in: dir)
        XCTAssertEqual(migrationsAfter, head, "\(label): migrated to head in order")
        XCTAssertEqual(Array(migrationsAfter.prefix(migrationsBefore.count)), migrationsBefore,
                       "\(label): the backup's migrations are a prefix of head")
        let applied = Set(migrationsAfter).subtracting(migrationsBefore)
        let rewritten = Set(applied.flatMap { Self.documentedRewrites[$0] ?? [] })
        let afterMigration = try digests(of: first, restrictTo: columnsBefore)
        for (table, digest) in before where table != "grdb_migrations" && !rewritten.contains(table) {
            XCTAssertEqual(afterMigration[table], digest,
                           "\(label): table \(table) changed while migrating to head")
        }

        // 3. Export the migrated store with the applied settings, exactly as the app's writer does.
        let exported = dir.appendingPathComponent("round-trip.noopbak")
        try DataBackup.writeBackupForTesting(databaseAt: first, to: exported, settings: settings)

        // 4. Import the export into a second throwaway path and compare everything.
        let second = dir.appendingPathComponent("second.sqlite")
        let secondDefaults = try freshDefaults()
        guard case .imported = DataBackup.restore(from: exported, toDatabaseAt: second.path,
                                                  settingsDefaults: secondDefaults) else {
            return XCTFail("\(label): re-import of the exported backup failed")
        }
        let full = try digests(of: first, restrictTo: try columns(of: first))
        let roundTripped = try digests(of: second, restrictTo: try columns(of: first))
        XCTAssertEqual(Set(roundTripped.keys), Set(full.keys), "\(label): same tables after the round trip")
        for (table, digest) in full {
            XCTAssertEqual(roundTripped[table], digest, "\(label): table \(table) changed in the round trip")
        }
        XCTAssertEqual(NSDictionary(dictionary: BackupSettings.snapshot(from: secondDefaults)),
                       NSDictionary(dictionary: settings), "\(label): settings changed in the round trip")

        let rows = full.values.reduce(0) { $0 + $1.rows }
        print("RealBackupGate \(label): \(migrationsBefore.count) → \(migrationsAfter.count) migrations, "
              + "\(full.count) tables, \(rows) rows, \(settings.count) settings compared")
    }

    // MARK: - Helpers

    /// Tables a migration rewrites on purpose, by migration identifier. Each entry must cite the
    /// migration's own comment for why the rewrite is not a loss; any other table must come through a
    /// migration byte for byte.
    private static let documentedRewrites: [String: [String]] = [
        // Purges v47 rows packed as unsigned 16-bit (see the v48 comment in Database.swift).
        "v48-ecg-candidate-signed": ["ecgCandidateSample"],
        // Purges v48 rows that dropped samples on a misread flag (see the v49 comment).
        "v49-ecg-r16-record": ["ecgCandidateSample"],
    ]

    private struct TableDigest: Equatable {
        let rows: Int
        let digest: UInt64
    }

    /// The migration identifiers a brand-new store records, in order: the head schema.
    private func headMigrations(in dir: URL) async throws -> [String] {
        let fresh = dir.appendingPathComponent("fresh.sqlite")
        do {
            let store = try await WhoopStore(path: fresh.path)
            try await store.checkpointWAL()
        }
        return try strings(in: fresh, sql: "SELECT identifier FROM grdb_migrations")
    }

    private func freshDefaults() throws -> UserDefaults {
        let name = "real-backup-gate-\(UUID().uuidString)"
        guard let d = UserDefaults(suiteName: name) else { throw GateError("no suite defaults") }
        suites.append(name)
        return d
    }

    /// The whitelisted settings the backup's `settings.json` carries, decoded the way a restore reads them.
    private func settingsEntry(of backup: URL) throws -> [String: Any] {
        let archive = try XCTUnwrap(Archive(url: backup, accessMode: .read))
        guard let entry = archive[BackupSettings.entryName] else { return [:] }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return BackupSettings.decode(data)
    }

    private func open(_ url: URL) throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            throw GateError("cannot open \(url.lastPathComponent)")
        }
        return db
    }

    private func strings(in url: URL, sql: String) throws -> [String] {
        let db = try open(url)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw GateError(sql) }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return out
    }

    /// Column names per user table, in declaration order.
    private func columns(of url: URL) throws -> [String: [String]] {
        var out: [String: [String]] = [:]
        let tables = try strings(in: url, sql: """
            SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
            """)
        for table in tables {
            out[table] = try strings(in: url, sql: "SELECT name FROM pragma_table_info('\(table)')")
        }
        return out
    }

    /// An order-independent digest of each table over the given columns: FNV-1a 64 per row over each
    /// value's storage class and bytes, summed with wrapping arithmetic, plus the row count.
    private func digests(of url: URL, restrictTo columns: [String: [String]]) throws -> [String: TableDigest] {
        let db = try open(url)
        defer { sqlite3_close(db) }
        var out: [String: TableDigest] = [:]
        for (table, cols) in columns where !cols.isEmpty {
            let list = cols.map { "\"\($0)\"" }.joined(separator: ", ")
            var stmt: OpaquePointer?
            let sql = "SELECT \(list) FROM \"\(table)\""
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw GateError(sql) }
            defer { sqlite3_finalize(stmt) }
            var rows = 0
            var sum: UInt64 = 0
            while sqlite3_step(stmt) == SQLITE_ROW {
                var h: UInt64 = 0xcbf2_9ce4_8422_2325
                func mixByte(_ byte: UInt8) { h = (h ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
                func mixInt<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { $0.forEach(mixByte) } }
                for c in 0..<Int32(cols.count) {
                    let type = sqlite3_column_type(stmt, c)
                    mixByte(UInt8(type))
                    switch type {
                    case SQLITE_INTEGER: mixInt(sqlite3_column_int64(stmt, c))
                    case SQLITE_FLOAT: mixInt(sqlite3_column_double(stmt, c).bitPattern)
                    case SQLITE_TEXT, SQLITE_BLOB:
                        let n = Int(sqlite3_column_bytes(stmt, c))
                        mixInt(Int64(n))
                        if n > 0, let p = sqlite3_column_blob(stmt, c) {
                            UnsafeRawBufferPointer(start: p, count: n).forEach(mixByte)
                        }
                    default: break
                    }
                }
                sum = sum &+ h
                rows += 1
            }
            out[table] = TableDigest(rows: rows, digest: sum)
        }
        return out
    }

    private struct GateError: Error { let message: String; init(_ m: String) { message = m } }
}
