import XCTest
import GRDB
@testable import WhoopStore

final class DeviceRegistryStoreTests: XCTestCase {
    private func makeDB() throws -> DatabaseQueue {
        let dbq = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(dbq)   // applies through v15, seeds 'my-whoop' active
        return dbq
    }

    /// #1518: a stored row carrying whitespace still names real capabilities, and every one of them must
    /// survive the decode.
    ///
    /// Written with raw SQL on purpose: `add` always joins canonical rawValues, so it cannot reproduce the
    /// state this guards. A spaced token reaches the column from history — the v36 migration rewrote rows
    /// in place before #1495 taught it to trim, so an upgraded install can be holding exactly this — or
    /// from a restored backup.
    ///
    /// Before the fix `Metric(rawValue:)` matched exactly, so every spaced token failed to parse and
    /// `compactMap` dropped it: this row decoded to `{hr}` alone, silently losing three capabilities.
    func testDecodeTrimsWhitespaceBearingCapabilityTokens() throws {
        let dbq = try makeDB()
        try dbq.write { db in
            try db.execute(sql: "UPDATE pairedDevice SET capabilities = ? WHERE id = 'my-whoop'",
                           arguments: ["hr, hrv,\tskinTemp , spo2 , sleep"])
        }
        let store = DeviceRegistryStore(dbQueue: dbq)
        let device = try XCTUnwrap(store.all().first(where: { $0.id == "my-whoop" }))
        // spo2 is absent because a WHOOP row drops calibrated SpO₂ (#548) — not because it failed to parse.
        XCTAssertEqual(device.capabilities, [.hr, .hrv, .skinTemp, .sleep])
    }

    func testSeededWhoopIsActive() throws {
        let store = DeviceRegistryStore(dbQueue: try makeDB())
        let devices = try store.all()
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.id, "my-whoop")
        XCTAssertEqual(try store.activeDeviceId(), "my-whoop")
    }

    func testSetActiveEnforcesSingleActive() throws {
        let store = DeviceRegistryStore(dbQueue: try makeDB())
        try store.add(PairedDevice(id: "polar-1", brand: "Polar", model: "H10", sourceKind: .liveBLE,
                                   capabilities: [.hr, .hrv], status: .paired, addedAt: 1, lastSeenAt: 1))
        try store.setActive("polar-1")
        XCTAssertEqual(try store.activeDeviceId(), "polar-1")
        let statuses = Dictionary(uniqueKeysWithValues: try store.all().map { ($0.id, $0.status) })
        XCTAssertEqual(statuses["polar-1"], .active)
        XCTAssertEqual(statuses["my-whoop"], .paired)   // the previously-active device was demoted
        XCTAssertEqual(try store.all().filter { $0.status == .active }.count, 1)  // I1
    }

    func testArchiveKeepsRowAndClearsActive() throws {
        let store = DeviceRegistryStore(dbQueue: try makeDB())
        try store.archive("my-whoop")
        XCTAssertEqual(try store.all().first?.status, .archived)   // I4: row kept
        XCTAssertNil(try store.activeDeviceId())
    }

    // #1193: unlike `archive` (which keeps the row so it lingers in "Removed"), `remove` hard-deletes the
    // registry entry so a duplicate/stale strap can be purged entirely — and touches only the given id.
    func testRemoveDeletesOnlyTheGivenRegistryRow() throws {
        let store = DeviceRegistryStore(dbQueue: try makeDB())
        try store.add(PairedDevice(id: "whoop-DEAD", brand: "WHOOP", model: "4.0", sourceKind: .liveBLE,
                                   capabilities: [.hr], status: .archived, addedAt: 2, lastSeenAt: 2))
        XCTAssertEqual(Set(try store.all().map(\.id)), ["my-whoop", "whoop-DEAD"])
        try store.remove("whoop-DEAD")
        XCTAssertEqual(try store.all().map(\.id), ["my-whoop"])     // duplicate purged, seed untouched
    }

    func testRemoveIsANoOpForAnAbsentId() throws {
        let store = DeviceRegistryStore(dbQueue: try makeDB())
        try store.remove("whoop-never-existed")                    // must not throw
        XCTAssertEqual(try store.all().map(\.id), ["my-whoop"])
    }

    func testSeededWhoopHasNilPeripheralId() throws {
        // v16 applies cleanly: the seeded my-whoop row exists with peripheralId nil (it connects to
        // "any WHOOP" today; it adopts its peripheral id later).
        let store = DeviceRegistryStore(dbQueue: try makeDB())
        let seeded = try store.all().first
        XCTAssertEqual(seeded?.id, "my-whoop")
        XCTAssertNil(seeded?.peripheralId)
    }

    func testPeripheralIdRoundTripsThroughAddAndAll() throws {
        let store = DeviceRegistryStore(dbQueue: try makeDB())
        let pid = "8E1A2B3C-4D5E-6F70-8192-A3B4C5D6E7F8"
        try store.add(PairedDevice(id: "whoop-\(pid)", brand: "WHOOP", model: "WHOOP 5.0",
                                   peripheralId: pid, sourceKind: .liveBLE,
                                   capabilities: [.hr, .hrv], status: .paired, addedAt: 10, lastSeenAt: 10))
        let fetched = try store.all().first { $0.id == "whoop-\(pid)" }
        XCTAssertEqual(fetched?.peripheralId, pid)
    }

    func testSetPeripheralIdUpdatesIt() throws {
        let store = DeviceRegistryStore(dbQueue: try makeDB())
        XCTAssertNil(try store.all().first { $0.id == "my-whoop" }?.peripheralId)
        let pid = "11111111-2222-3333-4444-555555555555"
        try store.setPeripheralId("my-whoop", peripheralId: pid)
        XCTAssertEqual(try store.all().first { $0.id == "my-whoop" }?.peripheralId, pid)
        // passing nil un-adopts it
        try store.setPeripheralId("my-whoop", peripheralId: nil)
        XCTAssertNil(try store.all().first { $0.id == "my-whoop" }?.peripheralId)
    }

    func testDeviceForPeripheralIdFindsIt() throws {
        let store = DeviceRegistryStore(dbQueue: try makeDB())
        let pid = "ABCDEF01-2345-6789-ABCD-EF0123456789"
        XCTAssertNil(try store.device(forPeripheralId: pid))   // none adopted yet
        try store.setPeripheralId("my-whoop", peripheralId: pid)
        XCTAssertEqual(try store.device(forPeripheralId: pid)?.id, "my-whoop")
        XCTAssertNil(try store.device(forPeripheralId: "no-such-peripheral"))
    }

    // ah-delete (#616): deleteAllData(deviceId: "apple-health") clears every row stored under the
    // Apple-Health source across the deviceId-keyed tables, while leaving another device's rows untouched.
    func testDeleteAllDataClearsOnlyTheTargetDevicesRows() throws {
        let dbq = try makeDB()
        let store = DeviceRegistryStore(dbQueue: dbq)

        // Seed apple-health + my-whoop rows in two device-scoped tables (appleDaily + metricSeries).
        try dbq.write { db in
            for dev in ["apple-health", "my-whoop"] {
                try db.execute(sql: "INSERT INTO appleDaily (deviceId, day, steps) VALUES (?, ?, ?)",
                               arguments: [dev, "2026-06-15", 1234])
                try db.execute(sql: "INSERT INTO metricSeries (deviceId, day, key, value) VALUES (?, ?, ?, ?)",
                               arguments: [dev, "2026-06-15", "steps", 1234.0])
            }
        }

        func count(_ table: String, _ deviceId: String) throws -> Int {
            try dbq.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE deviceId = ?",
                                 arguments: [deviceId]) ?? 0
            }
        }

        // Both devices start with a row in each table.
        XCTAssertEqual(try count("appleDaily", "apple-health"), 1)
        XCTAssertEqual(try count("metricSeries", "apple-health"), 1)
        XCTAssertEqual(try count("appleDaily", "my-whoop"), 1)

        try store.deleteAllData(deviceId: "apple-health")

        // The apple-health rows are gone everywhere; my-whoop's rows survive.
        XCTAssertEqual(try count("appleDaily", "apple-health"), 0)
        XCTAssertEqual(try count("metricSeries", "apple-health"), 0)
        XCTAssertEqual(try count("appleDaily", "my-whoop"), 1)
        XCTAssertEqual(try count("metricSeries", "my-whoop"), 1)

        // The registry row itself is never touched by a delete-data op (the seeded my-whoop remains).
        XCTAssertEqual(try store.all().count, 1)
        XCTAssertEqual(try store.activeDeviceId(), "my-whoop")
    }

    // W02-005: the engine writes a device's derived days, sleeps, workouts and metric series under its
    // computed sibling `<id>-noop`. "Delete all of this device's data" must clear that sibling too, or the
    // scores computed from the deleted recordings stay on disk and on screen.
    func testDeleteAllDataAlsoClearsTheComputedSibling() throws {
        let dbq = try makeDB()
        let store = DeviceRegistryStore(dbQueue: dbq)
        try dbq.write { db in
            for dev in ["my-whoop", "my-whoop-noop", "apple-health", "apple-health-noop"] {
                try db.execute(sql: "INSERT INTO metricSeries (deviceId, day, key, value) VALUES (?, ?, ?, ?)",
                               arguments: [dev, "2026-06-15", "recovery", 50.0])
            }
        }
        func count(_ deviceId: String) throws -> Int {
            try dbq.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM metricSeries WHERE deviceId = ?",
                                 arguments: [deviceId]) ?? 0
            }
        }

        try store.deleteAllData(deviceId: "my-whoop")

        XCTAssertEqual(try count("my-whoop"), 0)
        XCTAssertEqual(try count("my-whoop-noop"), 0, "the computed sibling belongs to the deleted device")
        XCTAssertEqual(try count("apple-health"), 1, "another device's rows survive")
        XCTAssertEqual(try count("apple-health-noop"), 1, "another device's computed rows survive")
    }

    private func seedComputed(_ dbq: DatabaseQueue, _ deviceId: String) throws {
        try dbq.write { db in
            try db.execute(sql: "INSERT INTO metricSeries (deviceId, day, key, value) VALUES (?, '2026-06-15', 'recovery', 50)",
                           arguments: [deviceId])
            try db.execute(sql: "INSERT INTO sleepSession (deviceId, startTs, endTs, userEdited) VALUES (?, 1000, 2000, 0)",
                           arguments: [deviceId])
            try db.execute(sql: "INSERT INTO sleepSession (deviceId, startTs, endTs, userEdited) VALUES (?, 5000, 6000, 1)",
                           arguments: [deviceId])
        }
    }

    private func rows(_ dbq: DatabaseQueue, _ table: String, _ deviceId: String) throws -> Int {
        try dbq.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE deviceId = ?", arguments: [deviceId]) ?? 0
        }
    }

    /// V2 regression guard for W02-005: after a strap is re-added (`my-whoop` archived, `whoop-<uuid>`
    /// active) the canonical `my-whoop-noop` also holds the days scored from the new strap, so deleting
    /// `my-whoop`'s data must leave it alone.
    func testDeletingTheCanonicalDeviceKeepsASharedComputedNamespace() throws {
        let dbq = try makeDB()
        let store = DeviceRegistryStore(dbQueue: dbq)
        try store.add(PairedDevice(id: "whoop-new", brand: "WHOOP", model: "WHOOP 5.0 / MG", sourceKind: .liveBLE,
                                   capabilities: [.hr], status: .paired, addedAt: 1, lastSeenAt: 1))
        try seedComputed(dbq, "my-whoop-noop")

        try store.deleteAllData(deviceId: "my-whoop")

        XCTAssertEqual(try rows(dbq, "metricSeries", "my-whoop-noop"), 1)
        XCTAssertEqual(try rows(dbq, "sleepSession", "my-whoop-noop"), 2)
    }

    /// With the canonical device registered alone, its computed rows are its own and go; a night the user
    /// edited or added stays.
    func testDeletingTheOnlyDeviceKeepsUserEditedNights() throws {
        let dbq = try makeDB()
        let store = DeviceRegistryStore(dbQueue: dbq)
        try seedComputed(dbq, "my-whoop-noop")

        try store.deleteAllData(deviceId: "my-whoop")

        XCTAssertEqual(try rows(dbq, "metricSeries", "my-whoop-noop"), 0)
        XCTAssertEqual(try rows(dbq, "sleepSession", "my-whoop-noop"), 1, "only the user-edited night stays")
    }

    /// A non-canonical device's computed sibling is its own, whatever else is registered.
    func testDeletingAnotherDeviceClearsItsOwnComputedSibling() throws {
        let dbq = try makeDB()
        let store = DeviceRegistryStore(dbQueue: dbq)
        try seedComputed(dbq, "whoop-new-noop")

        try store.deleteAllData(deviceId: "whoop-new")

        XCTAssertEqual(try rows(dbq, "metricSeries", "whoop-new-noop"), 0)
        XCTAssertEqual(try rows(dbq, "sleepSession", "whoop-new-noop"), 1)
    }

    // MARK: W07-002 — the shared canonical namespace, attributed per cell

    /// Seeds the canonical computed namespace the way the engine leaves it with two straps registered:
    /// day A scored from `whoop-new`, day B from `my-whoop`, day M mixed (recovery from a legacy snapshot of
    /// `my-whoop`, strain from `whoop-new`), day L from before provenance existed, and a weekly VO₂max cell on
    /// day A whose source is an estimator, not a device. An unattributed cell sits on days A, B and M, as a
    /// value a later pass stopped producing does. Sleeps and a detected workout carry no day key, so they
    /// are attributed by whose heart rate covers them.
    private func seedSharedNamespace(_ dbq: DatabaseQueue) throws {
        try dbq.write { db in
            // Day R: whoop-new scored a night but no Charge, so only a Rest-point cell names it.
            try db.execute(sql: "INSERT INTO dailyMetric (deviceId, day, totalSleepMin) VALUES ('my-whoop-noop', 'R', 400)")
            try db.execute(sql: "INSERT INTO metricSeries (deviceId, day, key, value) VALUES ('my-whoop-noop', 'R', 'sleep_performance', 70)")
            try db.execute(sql: "INSERT INTO scoreInputProvenance (deviceId, day, key, sourceId) VALUES ('my-whoop-noop', 'R', 'sleep_performance', 'whoop-new')")
            for day in ["A", "B", "M", "L"] {
                try db.execute(sql: "INSERT INTO dailyMetric (deviceId, day, recovery, strain) VALUES ('my-whoop-noop', ?, 60, 10)",
                               arguments: [day])
                try db.execute(sql: "INSERT INTO metricSeries (deviceId, day, key, value) VALUES ('my-whoop-noop', ?, 'sleep_performance', 80)",
                               arguments: [day])
            }
            try db.execute(sql: "INSERT INTO metricSeries (deviceId, day, key, value) VALUES ('my-whoop-noop', 'A', 'vo2max_est', 45)")
            // Unattributed cells: a value a later pass stopped producing (it keeps its value, loses its
            // provenance) on day A, day M and day B, and the Healthspan model marker on its sentinel day.
            for day in ["A", "M", "B"] {
                try db.execute(sql: "INSERT INTO metricSeries (deviceId, day, key, value) VALUES ('my-whoop-noop', ?, 'spo2_candidate', 95)",
                               arguments: [day])
            }
            try db.execute(sql: "INSERT INTO metricSeries (deviceId, day, key, value) VALUES ('my-whoop-noop', '1970-01-01', 'healthspan_model', 2)")
            let cells: [(String, String, String)] = [
                ("A", "recovery", "whoop-new"), ("A", "strain", "whoop-new"), ("A", "sleep_performance", "whoop-new"),
                ("A", "vo2max_est", "nes"),
                ("B", "recovery", "my-whoop"), ("B", "strain", "my-whoop"), ("B", "sleep_performance", "my-whoop"),
                ("M", "recovery", "my-whoop"), ("M", "strain", "whoop-new"), ("M", "sleep_performance", "whoop-new"),
            ]
            for (day, key, source) in cells {
                try db.execute(sql: "INSERT INTO scoreInputProvenance (deviceId, day, key, sourceId) VALUES ('my-whoop-noop', ?, ?, ?)",
                               arguments: [day, key, source])
            }
            // Heart rate: whoop-new alone over 1000…2000, both straps over 3000…4000, my-whoop alone over 7000…8000.
            for (dev, ts) in [("whoop-new", 1500), ("whoop-new", 3500), ("my-whoop", 3600), ("whoop-new", 5500), ("my-whoop", 7500)] {
                try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES (?, ?, 60)", arguments: [dev, ts])
            }
            for (start, end, edited) in [(1000, 2000, 0), (3000, 4000, 0), (5000, 6000, 1), (7000, 8000, 0)] {
                try db.execute(sql: "INSERT INTO sleepSession (deviceId, startTs, endTs, userEdited) VALUES ('my-whoop-noop', ?, ?, ?)",
                               arguments: [start, end, edited])
            }
            // Detected bouts as they are banked (sport "detected", a computed source), and a legacy manual
            // workout under the canonical id that only whoop-new's heart rate covers (W07-037): user data.
            for (start, end) in [(1000, 2000), (7000, 8000)] {
                try db.execute(sql: "INSERT INTO workout (deviceId, startTs, endTs, sport, source) VALUES ('my-whoop-noop', ?, ?, 'detected', 'my-whoop-noop')",
                               arguments: [start, end])
            }
            try db.execute(sql: "INSERT INTO workout (deviceId, startTs, endTs, sport, source) VALUES ('my-whoop-noop', 1100, 1900, 'Running', 'manual')")
        }
    }

    private func canonicalCells(_ dbq: DatabaseQueue) throws -> (days: [String], series: [String], sleeps: [Int], workouts: [Int]) {
        try dbq.read { db in
            (try String.fetchAll(db, sql: "SELECT day FROM dailyMetric WHERE deviceId = 'my-whoop-noop' ORDER BY day"),
             try String.fetchAll(db, sql: "SELECT day || ':' || key FROM metricSeries WHERE deviceId = 'my-whoop-noop' ORDER BY day, key"),
             try Int.fetchAll(db, sql: "SELECT startTs FROM sleepSession WHERE deviceId = 'my-whoop-noop' ORDER BY startTs"),
             try Int.fetchAll(db, sql: "SELECT startTs FROM workout WHERE deviceId = 'my-whoop-noop' ORDER BY startTs"))
        }
    }

    /// Deleting a re-added strap's data takes the scores computed from it out of the canonical namespace:
    /// the cells its provenance names, the day rows it alone supplied, and the sleeps and detected workouts
    /// only its heart rate covers. Another strap's cells, a mixed day's row, a day with no provenance, the
    /// estimator-sourced VO₂max cell and a night the user edited all stay.
    func testDeletingAReAddedStrapClearsTheCanonicalCellsAttributedToIt() throws {
        let dbq = try makeDB()
        let store = DeviceRegistryStore(dbQueue: dbq)
        try store.add(PairedDevice(id: "whoop-new", brand: "WHOOP", model: "WHOOP 5.0 / MG", sourceKind: .liveBLE,
                                   capabilities: [.hr], status: .active, addedAt: 1, lastSeenAt: 1))
        try seedSharedNamespace(dbq)

        try store.deleteAllData(deviceId: "whoop-new")

        let left = try canonicalCells(dbq)
        XCTAssertEqual(left.days, ["B", "L"],
                       "day A was whoop-new's alone; day M's row is whoop-new's too (its strain cell), only its legacy recovery is not (W07-035)")
        XCTAssertEqual(left.series, ["1970-01-01:healthspan_model", "B:sleep_performance",
                                     "B:spo2_candidate", "L:sleep_performance"],
                       "the unattributed cells of the days whoop-new owned go with them, and the weekly VO2max with Fitness Age (W07-036)")
        XCTAssertEqual(left.sleeps, [3000, 5000, 7000], "a night only whoop-new's heart rate covers goes; an edited one stays")
        XCTAssertEqual(left.workouts, [1100, 7000], "a manual workout is user data and stays (W07-037)")
    }

    /// The same rule from the other side: deleting the canonical strap's data while a re-added strap is
    /// registered takes only the canonical strap's cells.
    func testDeletingTheCanonicalStrapClearsOnlyItsCellsFromASharedNamespace() throws {
        let dbq = try makeDB()
        let store = DeviceRegistryStore(dbQueue: dbq)
        try store.add(PairedDevice(id: "whoop-new", brand: "WHOOP", model: "WHOOP 5.0 / MG", sourceKind: .liveBLE,
                                   capabilities: [.hr], status: .active, addedAt: 1, lastSeenAt: 1))
        try seedSharedNamespace(dbq)

        try store.deleteAllData(deviceId: "my-whoop")

        let left = try canonicalCells(dbq)
        XCTAssertEqual(left.days, ["A", "L", "M", "R"])
        let m = try dbq.read { db in
            try Row.fetchOne(db, sql: "SELECT recovery, strain FROM dailyMetric WHERE deviceId = 'my-whoop-noop' AND day = 'M'")
        }
        XCTAssertNil(m?["recovery"] as Double?, "day M's recovery was a legacy snapshot of my-whoop's (W07-035)")
        XCTAssertEqual(m?["strain"] as Double?, 10, "day M's own scores are whoop-new's and stay")
        XCTAssertEqual(left.series, ["1970-01-01:healthspan_model", "A:sleep_performance", "A:spo2_candidate",
                                     "A:vo2max_est", "L:sleep_performance", "M:sleep_performance", "M:spo2_candidate",
                                     "R:sleep_performance"])
        XCTAssertEqual(left.sleeps, [1000, 3000, 5000])
        XCTAssertEqual(left.workouts, [1000, 1100])
    }

    // Regression guard (audit finding): every table with a `deviceId` column MUST appear in
    // `deviceScopedTables`, or `deleteAllData` silently leaves that device's rows behind — a privacy
    // defect for a delete-means-gone app. Enumerate the live schema and fail if any deviceId-keyed table
    // is uncovered, so a future migration that adds one can't reintroduce the gap.
    func testDeviceScopedTablesCoversEveryDeviceIdKeyedTable() throws {
        let dbq = try makeDB()
        let uncovered = try dbq.read { db -> [String] in
            let tables = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
            """)
            var missing: [String] = []
            for table in tables {
                let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
                let hasDeviceId = cols.contains { ($0["name"] as String?) == "deviceId" }
                if hasDeviceId && !DeviceRegistryStore.deviceScopedTables.contains(table) {
                    missing.append(table)
                }
            }
            return missing
        }
        XCTAssertTrue(uncovered.isEmpty,
                      "deviceId-keyed tables missing from deviceScopedTables (deleteAllData would skip them): \(uncovered)")
    }

    func testDayOwnershipUpsertAndRead() throws {
        let store = DeviceRegistryStore(dbQueue: try makeDB())
        try store.setDayOwner(day: "2026-06-15", deviceId: "my-whoop", locked: true)
        XCTAssertEqual(try store.dayOwner("2026-06-15")?.deviceId, "my-whoop")
        XCTAssertEqual(try store.dayOwner("2026-06-15")?.locked, true)
        XCTAssertNil(try store.dayOwner("2000-01-01"))
        // upsert: re-writing the same day replaces the owner + locked flag (no duplicate row)
        try store.setDayOwner(day: "2026-06-15", deviceId: "polar-1", locked: false)
        XCTAssertEqual(try store.dayOwner("2026-06-15")?.deviceId, "polar-1")
        XCTAssertEqual(try store.dayOwner("2026-06-15")?.locked, false)
    }

    // MARK: #771 — adopt the strap's stable serial id (scoped to the active CB-UUID row only).

    private func addStrap(_ store: DeviceRegistryStore, _ id: String, model: String = "WHOOP 5.0 / MG",
                          peripheralId: String? = nil, status: DeviceStatus, addedAt: Int) throws {
        try store.add(PairedDevice(id: id, brand: "WHOOP", model: model, peripheralId: peripheralId ?? String(id.dropFirst(6)),
                                   sourceKind: .liveBLE, capabilities: [.hr, .sleep], status: status,
                                   addedAt: addedAt, lastSeenAt: addedAt))
    }
    private func hrCount(_ dbq: DatabaseQueue, _ id: String) throws -> Int {
        try dbq.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM hrSample WHERE deviceId = ?", arguments: [id]) ?? 0 }
    }

    func testAdoptSerialRenamesWhenSerialIsNew() throws {
        let dbq = try makeDB(); let store = DeviceRegistryStore(dbQueue: dbq)
        let cbuuid = "whoop-4DD70E24", serial = "whoop-2H3B2405003655"
        try addStrap(store, cbuuid, peripheralId: "4DD70E24", status: .paired, addedAt: 100)
        try store.setActive(cbuuid)
        try dbq.write { try $0.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('whoop-4DD70E24', 10, 55)") }

        XCTAssertTrue(try store.adoptSerialIdentity(from: cbuuid, to: serial))

        XCTAssertEqual(try hrCount(dbq, serial), 1)          // data moved onto the serial id
        XCTAssertEqual(try hrCount(dbq, cbuuid), 0)
        let ids = Set(try store.all().map(\.id))
        XCTAssertEqual(ids, ["my-whoop", serial])            // provisional CB-UUID row renamed away
        let row = try store.all().first { $0.id == serial }
        XCTAssertEqual(row?.peripheralId, "4DD70E24")        // BLE identity carried over → reconnect works
        XCTAssertEqual(row?.model, "WHOOP 5.0 / MG")
    }

    /// The computed sibling must travel with the pairing.
    ///
    /// Every strap owns a second id, `<deviceId>-noop`, holding the days/workouts/series the engine
    /// DERIVES. It never equals `activeId`, so an exact-match re-key left it behind while the next scoring
    /// pass wrote under `<serialId>-noop` — stranding the computed history under an id nothing reads
    /// again, which is the orphaned-history failure adoption exists to prevent. A ring has no computed
    /// sibling, so the shipped strap path could never surface this.
    func testAdoptSerialCarriesTheComputedSibling() throws {
        let dbq = try makeDB(); let store = DeviceRegistryStore(dbQueue: dbq)
        let cbuuid = "whoop-4DD70E24", serial = "whoop-MGB1234567"
        try addStrap(store, cbuuid, peripheralId: "4DD70E24", status: .paired, addedAt: 100)
        try store.setActive(cbuuid)
        try dbq.write { db in
            try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('whoop-4DD70E24', 10, 55)")
            // the DERIVED half, under the computed sibling
            try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('whoop-4DD70E24-noop', 11, 56)")
        }

        XCTAssertTrue(try store.adoptSerialIdentity(from: cbuuid, to: serial))

        XCTAssertEqual(try hrCount(dbq, serial), 1)
        XCTAssertEqual(try hrCount(dbq, cbuuid), 0)
        XCTAssertEqual(try hrCount(dbq, serial + "-noop"), 1, "computed rows must follow the pairing")
        XCTAssertEqual(try hrCount(dbq, cbuuid + "-noop"), 0, "and must not be left behind")
    }

    /// A PK clash on the COMPUTED side resolves the same way as on the real id: canonical wins, source is
    /// cleared, nothing is duplicated. Worth pinning separately because the clash is reachable only after
    /// a re-pair that already scored days under the serial's own computed sibling.
    func testAdoptSerialMergesComputedSiblingsOnClash() throws {
        let dbq = try makeDB(); let store = DeviceRegistryStore(dbQueue: dbq)
        let cbuuid = "whoop-0102A826", serial = "whoop-MGB7654321"
        try addStrap(store, serial, peripheralId: "OLDPID", status: .paired, addedAt: 100)
        try addStrap(store, cbuuid, peripheralId: "0102A826", status: .paired, addedAt: 200)
        try store.setActive(cbuuid)
        try dbq.write { db in
            try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('whoop-MGB7654321-noop', 10, 50)")
            try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('whoop-0102A826-noop', 20, 60)")
        }

        try store.adoptSerialIdentity(from: cbuuid, to: serial)

        XCTAssertEqual(try hrCount(dbq, serial + "-noop"), 2)
        XCTAssertEqual(try hrCount(dbq, cbuuid + "-noop"), 0)
    }

    func testAdoptSerialMergesWhenSerialAlreadyExists() throws {
        let dbq = try makeDB(); let store = DeviceRegistryStore(dbQueue: dbq)
        let serial = "whoop-2H3B2405003655", cbuuid2 = "whoop-0102A826"
        try addStrap(store, serial, peripheralId: "OLDPID", status: .paired, addedAt: 100)   // prior pairing
        try addStrap(store, cbuuid2, peripheralId: "0102A826", status: .paired, addedAt: 200)
        try store.setActive(cbuuid2)
        try dbq.write { db in
            try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('whoop-2H3B2405003655', 10, 50)")
            try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('whoop-0102A826', 20, 60)")
        }
        try store.adoptSerialIdentity(from: cbuuid2, to: serial)

        XCTAssertEqual(try hrCount(dbq, serial), 2)          // both beats now under the serial id
        XCTAssertEqual(try hrCount(dbq, cbuuid2), 0)
        XCTAssertEqual(Set(try store.all().map(\.id)), ["my-whoop", serial])
        let row = try store.all().first { $0.id == serial }
        XCTAssertEqual(row?.peripheralId, "0102A826")        // fresh pairing's BLE identity carried onto serial
    }

    func testAdoptSerialLeavesOtherPairingsUntouched() throws {
        let dbq = try makeDB(); let store = DeviceRegistryStore(dbQueue: dbq)
        let other = "whoop-99B6BA9D", cbuuid = "whoop-D6235E4F", serial = "whoop-2H3B2405003655"
        try addStrap(store, other, status: .archived, addedAt: 50)     // a past pairing, NOT to be touched
        try addStrap(store, cbuuid, peripheralId: "D6235E4F", status: .paired, addedAt: 300)
        try store.setActive(cbuuid)
        try dbq.write { db in
            try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('whoop-99B6BA9D', 1, 44)")
            try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('whoop-D6235E4F', 2, 70)")
        }
        try store.adoptSerialIdentity(from: cbuuid, to: serial)

        // The other pairing's row + data survive verbatim; only the active CB-UUID was folded into the serial.
        XCTAssertEqual(try hrCount(dbq, other), 1)
        XCTAssertNotNil(try store.all().first { $0.id == other })
        XCTAssertEqual(try hrCount(dbq, serial), 1)
        XCTAssertEqual(Set(try store.all().map(\.id)), ["my-whoop", other, serial])
    }

    func testAdoptSerialNoOpWhenSameOrAbsent() throws {
        let store = DeviceRegistryStore(dbQueue: try makeDB())
        XCTAssertFalse(try store.adoptSerialIdentity(from: "whoop-X", to: "whoop-X"))       // same id
        XCTAssertFalse(try store.adoptSerialIdentity(from: "whoop-absent", to: "whoop-Y"))  // no active row
    }
}
