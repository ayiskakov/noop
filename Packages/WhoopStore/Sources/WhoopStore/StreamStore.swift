import Foundation
import GRDB
import WhoopProtocol

private struct RRBatchSecond: Hashable {
    let ts: Int
    let transport: Int
}

/// One line of the R16 ECG-record export (#891): the device, the strap-second, the SIGNED 18-bit
/// waveform, and the record's own acquisition context. One JSON object per `ecgCandidateSample` row.
/// See `WhoopStore.writeEcgCandidateExportJSONL`. UNVALIDATED instrumentation — not an ECG, heart rate
/// or diagnosis.
///
/// `declaredCount` ships beside `samples` so an analysis reading this file offline can check the record
/// for loss without the database — the exact check that would have caught the superseded decoder
/// discarding 42.8 % of every capture.
private struct EcgCandidateExportLine: Encodable {
    let deviceId: String
    let ts: Int
    let samples: [Int]
    let recordIndex: Int?
    let declaredCount: Int
    let sampleFlags: [Int]
    let contactFlags: [Int]
    let quality: Int
    let stateBits: Int
    let classifierResult: Int
    let classifierState: Int
    let progress: Int
    let leadOffCount: Int
    let leadOffI: [Int]
    let leadOffQ: [Int]
}

extension WhoopStore {
    /// Deterministic JSON for an event payload (sorted keys so the same payload always
    /// serializes byte-identically, important for the natural-key dedupe and parity).
    static func encodePayload(_ payload: [String: ParsedValue]) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    /// Pack a decoded v26 PPG waveform's samples as little-endian i16 (2 bytes/sample) — a single
    /// compact BLOB per (deviceId, ts) row instead of 24 scalar rows (issue #156 follow-up, v27). Any
    /// sample count is handled (a truncated frame can decode fewer than 24); each value is truncated to
    /// Int16's range, matching the wire format it came from (`readI16` in the decoder never produces
    /// anything wider).
    static func packPpgSamples(_ samples: [Int]) -> Data {
        var buf = Data(capacity: samples.count * 2)
        for s in samples {
            let v = Int16(truncatingIfNeeded: s)
            buf.append(UInt8(truncatingIfNeeded: v))
            buf.append(UInt8(truncatingIfNeeded: v >> 8))
        }
        return buf
    }

    /// Inverse of `packPpgSamples`. A trailing odd byte (a corrupt/truncated blob) is dropped rather
    /// than thrown — a read path never crashes on a malformed row.
    static func unpackPpgSamples(_ data: Data) -> [Int] {
        let bytes = [UInt8](data)
        var out = [Int](); out.reserveCapacity(bytes.count / 2)
        var i = 0
        while i + 1 < bytes.count {
            let u = UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8)
            out.append(Int(Int16(bitPattern: u)))
            i += 2
        }
        return out
    }

    /// Pack a decoded v16 MAX86176 FIFO candidate's samples as little-endian SIGNED 32-bit values
    /// (4 bytes/sample) — a single compact BLOB per (deviceId, ts) row (#891, v47).
    ///
    /// WIDER THAN `packPpgSamples`'s i16, deliberately. A v16 sample is 18-bit two's-complement (see
    /// `decodeWhoop5HistoricalV16`), so its domain is −131,072…131,071 and an i16 field cannot hold it
    /// without clipping. Clipping is not an option HERE specifically: this table's entire purpose is that
    /// a future analysis can run over the ORIGINAL samples, and a large deflection — the very feature such
    /// an analysis would look for — is exactly what would be clipped. The observed capture fits in i16
    /// comfortably (−12,365…1,007), but storing to the observed range rather than the wire range is how a
    /// format quietly becomes lossy the first time the signal does something interesting.
    static func packEcgCandidateSamples(_ samples: [Int]) -> Data {
        var buf = Data(capacity: samples.count * 4)
        for s in samples {
            let v = UInt32(bitPattern: Int32(truncatingIfNeeded: s))
            buf.append(UInt8(truncatingIfNeeded: v))
            buf.append(UInt8(truncatingIfNeeded: v >> 8))
            buf.append(UInt8(truncatingIfNeeded: v >> 16))
            buf.append(UInt8(truncatingIfNeeded: v >> 24))
        }
        return buf
    }

    /// Inverse of `packEcgCandidateSamples` — reads each group of 4 back as a SIGNED 32-bit value.
    /// A trailing partial group (a corrupt/truncated blob) is dropped rather than thrown, like
    /// `unpackPpgSamples`.
    static func unpackEcgCandidateSamples(_ data: Data) -> [Int] {
        let bytes = [UInt8](data)
        var out = [Int](); out.reserveCapacity(bytes.count / 4)
        var i = 0
        while i + 3 < bytes.count {
            let v = UInt32(bytes[i]) | (UInt32(bytes[i + 1]) << 8)
                | (UInt32(bytes[i + 2]) << 16) | (UInt32(bytes[i + 3]) << 24)
            out.append(Int(Int32(bitPattern: v)))
            i += 4
        }
        return out
    }

    /// Pack the per-sample `flag6` bits as one BIT PER SAMPLE, LSB-first within each byte.
    ///
    /// Bit-packed rather than a byte per sample because the array is the same length as the waveform:
    /// a byte each would cost 500 bytes against the waveform's 2,000, and this flag is uninterpreted —
    /// it should not cost a quarter of the row it annotates.
    static func packEcgSampleFlags(_ flags: [Bool]) -> Data {
        var buf = Data(repeating: 0, count: (flags.count + 7) / 8)
        for (i, f) in flags.enumerated() where f { buf[i / 8] |= UInt8(1 << (i % 8)) }
        return buf
    }

    /// Inverse of `packEcgSampleFlags`. `count` is supplied by the caller (from the waveform's own
    /// length) because the packing rounds up to a byte and so cannot carry its own length: without it,
    /// a 500-flag array would read back as 504.
    static func unpackEcgSampleFlags(_ data: Data, count: Int) -> [Bool] {
        guard count > 0 else { return [] }
        let bytes = [UInt8](data)
        var out = [Bool](); out.reserveCapacity(count)
        for i in 0..<count {
            let byte = i / 8
            out.append(byte < bytes.count && bytes[byte] & UInt8(1 << (i % 8)) != 0)
        }
        return out
    }

    /// Pack the slower contact stream (at most 11 entries) into one integer bitmask, bit k = entry k.
    static func packEcgContactMask(_ flags: [Bool]) -> Int {
        var mask = 0
        for (i, f) in flags.enumerated() where f && i < 64 { mask |= 1 << i }
        return mask
    }

    /// Inverse of `packEcgContactMask`. `count` comes from the row's `leadOffCount`, for the same reason
    /// the sample flags need one: a mask of 0 is indistinguishable from an empty stream otherwise, and
    /// "every group was out of contact" and "there was no contact stream" are different facts.
    static func unpackEcgContactMask(_ mask: Int, count: Int) -> [Bool] {
        guard count > 0 else { return [] }
        return (0..<min(count, 64)).map { mask & (1 << $0) != 0 }
    }

    /// Pack the signed I/Q lead-off diagnostic halfwords as little-endian i16 — the same encoding as
    /// `packPpgSamples`, and the width they arrive on the wire in.
    static func packEcgLeadOff(_ values: [Int]) -> Data {
        var buf = Data(capacity: values.count * 2)
        for v in values {
            let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
            buf.append(UInt8(truncatingIfNeeded: u))
            buf.append(UInt8(truncatingIfNeeded: u >> 8))
        }
        return buf
    }

    /// Inverse of `packEcgLeadOff`. A trailing odd byte is dropped rather than thrown.
    static func unpackEcgLeadOff(_ data: Data?) -> [Int] {
        guard let data else { return [] }
        let bytes = [UInt8](data)
        var out = [Int](); out.reserveCapacity(bytes.count / 2)
        var i = 0
        while i + 1 < bytes.count {
            out.append(Int(Int16(bitPattern: UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8))))
            i += 2
        }
        return out
    }

    /// #423: pack the raw-IMU i16 columns to a little-endian BLOB (same wire encoding as `packPpgSamples`,
    /// an `[Int16]` source — the 6×100 columns ax…az,gx…gz). Byte-identical to Kotlin `packImuColumns`.
    static func packImuColumns(_ cols: [Int16]) -> Data {
        var buf = Data(capacity: cols.count * 2)
        for v in cols { buf.append(UInt8(truncatingIfNeeded: v)); buf.append(UInt8(truncatingIfNeeded: v >> 8)) }
        return buf
    }

    /// Inverse of `packImuColumns`; a trailing odd byte is dropped so a malformed row never crashes a read.
    static func unpackImuColumns(_ data: Data) -> [Int16] {
        let bytes = [UInt8](data)
        var out = [Int16](); out.reserveCapacity(bytes.count / 2)
        var i = 0
        while i + 1 < bytes.count { out.append(Int16(bitPattern: UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8))); i += 2 }
        return out
    }

    /// Rolling retention for the v27 PPG waveform table (twin of Kotlin `PPG_WAVEFORM_RETENTION_ROWS`),
    /// added for #1911. This table was previously the only UNBOUNDED blob table, and it carries by far the
    /// largest PER-ROW cost of any decoded stream: ~120 B against ~30 B for a scalar row.
    ///
    /// It is NOT the store's fastest-growing table, and this note must not be read as saying so. v26 runs
    /// only in optical windows, roughly 28,800 rows/day by #1911's own figures, where `rrInterval` banks
    /// ~100,000/day and remains the higher-volume table by bytes. Capping this one bounds the worst row,
    /// not the bulk of #1911's ~93 MB/day.
    ///
    /// **A NEWEST-N-ROWS CAP, DELIBERATELY NOT A TIME-WINDOW DROP.** #1911 proposes "dropped after the hot
    /// window", justifying it as "diagnostic-only". That justification is wrong, and the migration note on
    /// `ppgWaveformSample` in `Database.swift` is the authority: these rows are kept precisely so a better
    /// estimator, HRV-from-PPG, or a waveform viewer can later run over the ORIGINAL samples rather than
    /// the derived bpm. Deleting by wall-clock age would empty the table for exactly the user a future
    /// estimator needs most — a sporadic wearer, whose v26 seconds are spread thin over months — and a
    /// waveform, unlike an HR series, has no aggregate that survives it. Newest-N instead bounds the bytes
    /// while ALWAYS leaving a full working set to analyse, which is the same trade `v18AuxRetentionRows`
    /// below makes for the same reason.
    ///
    /// 604,800 = 7 × 86,400, matching the aux cap's "a week of strap-seconds" semantic and #1911's own
    /// 7-day hot window. The ceiling is larger than the aux table's because the row is: ~120 B/row (a 48 B
    /// packed-i16 blob for 24 samples, plus row and primary-key-index overhead) puts it at **~70 MB per
    /// device**, against ~50 MB for aux. That is the bound worth quoting; the wall-clock
    /// span is longer than the arithmetic suggests, because v26 only runs in optical windows. At #1911's
    /// ~28,800 rows/day the cap holds about **three weeks** of typical wear, and proportionally more for a
    /// sporadic wearer, which is exactly the population an age-based cutoff would have emptied. Retuning is
    /// a one-constant change with no migration once a device `row_bytes` measurement lands, and RELAXING a
    /// cap is always cheaper than imposing one on a user with a year of history.
    public static let ppgWaveformRetentionRows = 604_800

    /// Rows to bank before sweeping `ppgWaveformSample` again, same amortisation as
    /// `v18AuxPruneEveryRows` below and the same magnitude for the same reason: the sweep walks up to
    /// `ppgWaveformRetentionRows` index entries, so running it per insert batch is the cost. The table may
    /// sit this many rows (plus the crossing batch) above the cap in exchange, roughly a MB against its
    /// ~70 MB bound.
    ///
    /// WHAT THIS BUDGET DOES NOT GUARANTEE, and the reason the cap above is stated as a size rather than a
    /// "hard ceiling": the counter is in-memory and per store instance, so a process restart resets it.
    /// The sweep is the ONLY thing enforcing retention on this table — `Collector.prune` covers the raw
    /// outbox alone, and the `*ByTs` deletes belong to `TimestampHeal`, not to retention — so a store that
    /// never banks this many rows in one process lifetime never sweeps at all. It is not a concern for the
    /// normal shape (the budget accumulates across every batch of a session, and one night's offload banks
    /// ~28,800 rows, crossing it twice over), but a store fed only short bursts between app kills can drift
    /// above the cap indefinitely. `v18AuxPruneEveryRows` below has the identical property; a sweep forced
    /// once per session would close it for both, and belongs in a change that covers both.
    public static let ppgWaveformPruneEveryRows = 10_000

    /// Rolling retention for the v47 ECG-candidate table (#891) — the same newest-N-rows SHAPE as
    /// `ppgWaveformRetentionRows` and the same reasoning (bound the bytes of an UNVALIDATED blob table
    /// nothing reads yet, never age-drop: a sporadic wearer's v16 seconds are spread thin, and an age cut
    /// would empty the table for exactly the person a future analysis needs).
    ///
    /// The ROW COUNT is deliberately NOT copied from the ppg cap, because these rows are far heavier and
    /// a cap is a byte budget wearing a row count. A v26 ppg row holds 24 deltas (~48 B packed); a v16 row
    /// holds ~500 FIFO samples at 4 B each (~2 KB packed), so ppg's 604,800 rows would be well over a
    /// gigabyte against ppg's own ~29 MB. 43,200 holds ~86 MB — the same byte budget this constant carried
    /// when the samples were packed as i16, halved in rows when widening them to i32 doubled the row.
    ///
    /// 43,200 is not a duration. Reading it as "12 hours" assumes one record per strap-second, and the two
    /// captured records are 23 seconds apart, so the real cadence is unknown and likely far sparser — in
    /// which case this is many days of v16 activity, not half of one. The KOTLIN twin is pending.
    public static let ecgCandidateRetentionRows = 43_200

    /// Rows to bank before sweeping `ecgCandidateSample` again — same amortisation as
    /// `ppgWaveformPruneEveryRows`, and the same in-memory-per-instance caveat (a store fed only short
    /// bursts between kills can drift above the cap; the sweep is the only thing enforcing retention here).
    public static let ecgCandidatePruneEveryRows = 10_000

    /// Buffer size at which a streamed export flushes to disk (#891). Big enough that a multi-GB export is
    /// not one write syscall per row, small enough that peak memory is bounded regardless of table size —
    /// the whole point of streaming the export rather than building it in memory.
    static let exportFlushBytes = 256 * 1024

    /// v31 rolling retention for the v18 aux-slot table (twin of Kotlin `V18_AUX_RETENTION_ROWS`).
    ///
    /// Raw instrumentation must be capped rather than unbounded. Nothing reads these rows yet, so a cap is far
    /// cheaper to RELAX later than to impose once users have a year of history. Unbounded, this table is
    /// the one genuinely new source of row growth in v31 (the four named channels only WIDEN rows that
    /// were already being written: ~14 bytes on a `gravitySample`/`skinTempSample`/`sleepStateSample` row
    /// that exists either way, adding no rows at all).
    ///
    /// 604,800 = 7 × 86,400, i.e. a week of strap-seconds if the strap emitted v18 every second of every
    /// day. At ~85 B/row (a ≤30 B blob plus row and primary-key-index overhead) that is a **~50 MB hard
    /// ceiling**; in practice v18 seconds are a fraction of a day, so the same cap spans considerably
    /// longer in wall-clock terms. Per device, newest-first — a multi-device store gets the cap each.
    ///
    /// This does re-introduce a bounded version of the loss this migration exists to stop: a slot older
    /// than the window is gone again. That is the deliberate trade — a census needs weeks of records, not
    /// years, and the alternative is an invisible table that can outgrow everything a user actually reads.
    public static let v18AuxRetentionRows = 604_800

    /// Rows to bank before running the retention sweep again. The sweep walks up to
    /// `v18AuxRetentionRows` index entries, so running it per insert batch was the cost; the table may sit
    /// this many rows (plus the crossing batch) above the cap in exchange, well under a MB against its
    /// ~50 MB ceiling.
    public static let v18AuxPruneEveryRows = 10_000

    /// Insert or update a device row (natural key = id).
    public func upsertDevice(id: String, mac: String?, name: String?) async throws {
        let now = Int(Date().timeIntervalSince1970)
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO device (id, mac, name, firstSeen, lastSeen)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    mac = excluded.mac,
                    name = excluded.name,
                    lastSeen = excluded.lastSeen
                """, arguments: [id, mac, name, now, now])
        }
    }

    /// Idempotent upsert of decoded streams by natural key. Returns the number of rows
    /// ACTUALLY inserted per stream (0 for rows that already existed).
    ///
    /// `v18Aux` joined the tuple for #103. It was deliberately left out as "persist-only" alongside
    /// steps/sleepState/ppgHr/ppgWaveform, which was right while nothing needed the number — but the link
    /// census reports the offload's banked channels, and on a 5/MG every channel IN the tuple is a
    /// 4.0-only table. So the census could only ever print zeros for that family while this stream banked
    /// hundreds of thousands of rows, and a 5/MG owner read the result as "my SpO2 is not being
    /// collected". It is in the tuple so that line can count the rows it is actually talking about, on the
    /// same ACCEPTED-rows basis as every other entry — not a decoded count wearing the same label.
    ///
    /// NOTE: the `synced` column (added by migration v5 for a since-removed server-upload feature)
    /// is intentionally NOT written here, it is unused and defaults to 0. The column is left in the
    /// schema to avoid a DROP COLUMN migration over existing data; nothing reads it.
    @discardableResult
    public func insert(_ streams: Streams, deviceId: String) async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int, v18Aux: Int) {
        try await insert(streams, deviceId: deviceId,
                         v18AuxRetentionRows: WhoopStore.v18AuxRetentionRows,
                         v18AuxPruneEveryRows: WhoopStore.v18AuxPruneEveryRows,
                         ppgWaveformRetentionRows: WhoopStore.ppgWaveformRetentionRows,
                         ppgWaveformPruneEveryRows: WhoopStore.ppgWaveformPruneEveryRows)
    }

    /// `insert(_:deviceId:)` with the v31 aux-table cap made explicit. Internal and a SEPARATE overload
    /// rather than a defaulted parameter on the public entry point: `StoreWriting` / `BackfillStoreWriting`
    /// require `insert(_:deviceId:)` exactly, and a Swift witness must match the requirement's parameter
    /// list — a default argument does not satisfy it. Exists so a test can prove the rolling delete with a
    /// small cap instead of writing 600k rows; every production caller goes through the wrapper above.
    ///
    /// The two v18-aux caps are required because eleven existing call sites already pass them; the two
    /// ppg-waveform caps added for #1911 are DEFAULTED so those same call sites keep compiling untouched.
    /// A default is fine on this overload (unlike the public entry point, per the note above) because
    /// nothing witnesses it against a protocol requirement.
    @discardableResult
    func insert(_ streams: Streams, deviceId: String, v18AuxRetentionRows: Int,
                v18AuxPruneEveryRows: Int,
                ppgWaveformRetentionRows: Int = WhoopStore.ppgWaveformRetentionRows,
                ppgWaveformPruneEveryRows: Int = WhoopStore.ppgWaveformPruneEveryRows,
                ecgCandidateRetentionRows: Int = WhoopStore.ecgCandidateRetentionRows,
                ecgCandidatePruneEveryRows: Int = WhoopStore.ecgCandidatePruneEveryRows) async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int, v18Aux: Int) {
        // Banked rows, accumulated across batches so the sweep does not run on every one.
        var v18Written = 0
        var ppgWaveformWritten = 0
        var ecgCandidateWritten = 0
        let result: (Int, Int, Int, Int, Int, Int, Int, Int) = try syncWrite { db in
            var hr = 0, rr = 0, ev = 0, bat = 0
            var spo2 = 0, skin = 0, resp = 0, grav = 0
            // Reuse one prepared statement per table instead of recompiling the same SQL on every
            // row. This is the hottest write path (every Collector.flush + every Backfiller chunk
            // over potentially millions of historical rows). cachedStatement persists the compiled
            // statement on the connection across insert() calls too. Each loop is guarded so empty
            // streams (the common live case) compile nothing.
            if !streams.hr.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO hrSample (deviceId, ts, bpm) VALUES (?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.hr {
                    try stmt.execute(arguments: [deviceId, s.ts, s.bpm])
                    hr += db.changesCount
                }
            }
            if !streams.rr.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO rrInterval (deviceId, ts, rrMs, seq, ord, srcChannel)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts, rrMs, seq) DO NOTHING
                    """)
                // v24 (#163): number EQUAL (ts, rrMs) beats 0, 1, … within this batch so both survive;
                // distinct beats keep seq 0 and their own (ts, rrMs, 0) key, so a distinct beat is never
                // dropped even across batches (rrMs stays in the key). Re-syncing identical rows reproduces
                // the same (ts, rrMs, seq) → still idempotent. Nested dict = (ts, rrMs) occurrence counter.
                //
                // v30 (#823): `ord` is the beat's position among ALL beats sharing this ts in this batch —
                // its emission order. `seq` cannot express it (it keys on (ts, rrMs), so distinct beats in
                // a second are all 0). Not in the key, never changes which rows survive; it exists so reads
                // return beats in heart order rather than sorted by value, which biases RMSSD down. Same
                // batch-local caveat as seq: a second split across two live flushes restarts ord at 0 and
                // DO NOTHING keeps the first row. The historical path delivers a second atomically.
                // Twin of Kotlin assignRrSeq.
                //
                // `srcChannel` carries Oura optical channels or WHOOP 5 transport provenance. WHOOP 4
                // and legacy rows stay NULL. Like `ord` it is OUTSIDE the key: two observations of a beat can
                // yield the same (ts, rrMs), and keying on the label would store both — which is precisely
                // the double-count this fixes. A collision never inserts another beat. A newly observed
                // canonical WHOOP 5 transport can promote the existing source and order below; the read
                // filter separates sources across the full requested interval.
                let promote = try db.cachedStatement(sql: """
                    UPDATE rrInterval SET srcChannel = :source, ord = :ord
                    WHERE deviceId = :device AND ts = :ts AND rrMs = :rr AND seq = :seq
                    AND ((:source = 5 AND (srcChannel IS NULL OR srcChannel IN (6, 7)))
                      OR (:source = 7 AND (srcChannel IS NULL OR srcChannel = 6)))
                    """)
                var seqByTsRr: [RRBatchSecond: [Int: Int]] = [:]
                var ordByTs: [RRBatchSecond: Int] = [:]
                for r in streams.rr {
                    // A second's native historical array is atomic. A standard packet in the same
                    // batch must not change its order or the occurrence number of an equal interval.
                    let key = RRBatchSecond(ts: r.ts,
                        transport: r.srcChannel?.isWhoop5Transport == true ? r.srcChannel!.rawValue : 0)
                    let seq = seqByTsRr[key]?[r.rrMs] ?? 0
                    seqByTsRr[key, default: [:]][r.rrMs] = seq + 1
                    let ord = ordByTs[key] ?? 0
                    ordByTs[key] = ord + 1
                    try stmt.execute(arguments: [deviceId, r.ts, r.rrMs, seq, ord,
                                                 r.srcChannel?.rawValue])
                    let inserted = db.changesCount
                    rr += inserted
                    if inserted == 0, let source = r.srcChannel,
                       source == .whoop5Historical || source == .whoop5Standard {
                        // Canonical precedence is history > standard > native/legacy. The winning
                        // observation supplies its order; values/keys and Oura labels remain intact.
                        // Cache fingerprints witness both canonical-source counts independently of inserts.
                        try promote.execute(arguments: ["source": source.rawValue, "ord": ord,
                            "device": deviceId, "ts": r.ts, "rr": r.rrMs, "seq": seq])
                    }
                }
            }
            if !streams.events.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO event (deviceId, ts, kind, payloadJSON) VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts, kind) DO NOTHING
                    """)
                for e in streams.events {
                    let json = try WhoopStore.encodePayload(e.payload)
                    try stmt.execute(arguments: [deviceId, e.ts, e.kind, json])
                    ev += db.changesCount
                }
            }
            if !streams.battery.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO battery (deviceId, ts, soc, mv, charging) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for b in streams.battery {
                    try stmt.execute(arguments: [deviceId, b.ts, b.soc, b.mv, b.charging])
                    bat += db.changesCount
                }
            }
            if !streams.spo2.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO spo2Sample (deviceId, ts, red, ir) VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.spo2 {
                    try stmt.execute(arguments: [deviceId, s.ts, s.red, s.ir])
                    spo2 += db.changesCount
                }
            }
            // `aux1Raw`/`aux2Raw` (v31) are the two auxiliary thermal channels riding the same v18 record
            // as the primary reading. nil (a WHOOP 4.0, or a byte that failed the decoder's thermal gate)
            // stores SQL NULL, so an absent channel stays absent.
            if !streams.skinTemp.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO skinTempSample (deviceId, ts, raw, aux1Raw, aux2Raw) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.skinTemp {
                    try stmt.execute(arguments: [deviceId, s.ts, s.raw, s.aux1Raw, s.aux2Raw])
                    skin += db.changesCount
                }
            }
            if !streams.resp.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO respSample (deviceId, ts, raw) VALUES (?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.resp {
                    try stmt.execute(arguments: [deviceId, s.ts, s.raw])
                    resp += db.changesCount
                }
            }
            // `dynAccel` (v31) is the strap's OWN gravity-removed motion magnitude for the same second —
            // stored BESIDE the vector, never in place of it, and read by nothing. nil (a WHOOP 4.0, or an
            // f32 outside the decoder's [0, 8] g gate) stores SQL NULL.
            if !streams.gravity.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO gravitySample (deviceId, ts, x, y, z, dynAccel) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.gravity {
                    try stmt.execute(arguments: [deviceId, s.ts, s.x, s.y, s.z, s.dynAccel])
                    grav += db.changesCount
                }
            }
            // WHOOP5 step counter (#78). Persist-only, the count is not surfaced in the return tuple
            // (no consumer reads it; keeping the 8-field tuple avoids touching any caller/test).
            // `activityClass` (#316, v19 column) is the @63 activity-class enum (0=still/1=walk/2=run) the
            // decoder already carries on each StepSample; it was dropped here before v19. Bound as `s.activityClass`
            //, nil (the byte was 0xFF/invalid/absent) stores SQL NULL, so an absent class stays absent.
            if !streams.steps.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO stepSample (deviceId, ts, counter, activityClass) VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                var insertedSteps = 0
                var insertedStepTimestamps: [Int] = []
                for s in streams.steps {
                    try stmt.execute(arguments: [deviceId, s.ts, s.counter, s.activityClass])
                    let inserted = db.changesCount
                    insertedSteps += inserted
                    if inserted > 0 { insertedStepTimestamps.append(s.ts) }
                }
                stepDataRevision.record(deviceId: deviceId, insertedTimestamps: insertedStepTimestamps)
            }
            // Band sleep_state (#175). Persist-only, same as steps — the strap's OWN @81 high-nibble state
            // (0 wake/1 still/2 asleep/3 up), decoded and streamed but dropped at storage until now. Keyed by
            // (deviceId, ts); ON CONFLICT DO NOTHING keeps the first-seen state for a second so a re-sync is
            // idempotent. The raw 0-3 code is stored verbatim — a strap that never reports it inserts nothing.
            // `rawByte` (v31) is the WHOLE @81 byte; `state` remains exactly its high nibble, so every
            // existing #175 consumer is bit-identical. nil stores SQL NULL.
            if !streams.sleepState.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO sleepStateSample (deviceId, ts, state, rawByte) VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.sleepState {
                    try stmt.execute(arguments: [deviceId, s.ts, s.state, s.rawByte])
                }
            }
            // PPG-derived HR from the v26 optical buffer (#156). Persist-only, same as steps, the count
            // is not added to the 8-field return tuple (the Backfiller call site reads that tuple by name;
            // extending it would ripple), so it is inserted without being counted. ON CONFLICT DO NOTHING
            // keeps the FIRST estimate for a second; the measured hrSample is never touched here.
            if !streams.ppgHr.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO ppgHrSample (deviceId, ts, bpm, conf) VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.ppgHr {
                    try stmt.execute(arguments: [deviceId, s.ts, s.bpm, s.conf])
                }
            }
            // RAW v26 optical PPG waveform (#156 follow-up) — the samples `ppgHr` above is derived FROM.
            // Persist-only, same as steps/sleepState/ppgHr: not added to the 8-field return tuple. ON
            // CONFLICT DO NOTHING keeps the FIRST-seen waveform for a second, matching every other
            // per-second stream's dedupe rule. Packed into one compact BLOB per row (see
            // `packPpgSamples`) rather than 24 scalar rows, so this insert is O(records), not O(samples).
            if !streams.ppgWaveform.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO ppgWaveformSample (deviceId, ts, samples, burstIndex, baseCode)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.ppgWaveform {
                    try stmt.execute(arguments: [deviceId, s.ts, WhoopStore.packPpgSamples(s.samples),
                                                 s.burstIndex, s.baseCode])
                    ppgWaveformWritten += 1
                }
            }
            // R16 raw ECG records (#891) — EXPLICITLY UNVALIDATED instrumentation, persisted exactly
            // like ppgWaveform above: persist-only (not in the 8-field return tuple), ON CONFLICT DO
            // NOTHING keeps the first-seen record for a second, waveform packed into one compact BLOB per
            // row (see `packEcgCandidateSamples`). NOT an ECG / heart rate / diagnosis; nothing reads it
            // into a score.
            if !streams.ecgCandidate.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO ecgCandidateSample
                        (deviceId, ts, samples, recordIndex, declaredCount, quality, stateBits,
                         classifierResult, classifierState, progress, leadOffCount, contactMask,
                         sampleFlags, leadOffI, leadOffQ)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.ecgCandidate {
                    try stmt.execute(arguments: [
                        deviceId, s.ts,
                        WhoopStore.packEcgCandidateSamples(s.samples),
                        s.recordIndex, s.declaredCount, s.quality, s.stateBits,
                        s.classifierResult, s.classifierState, s.progress, s.leadOffCount,
                        WhoopStore.packEcgContactMask(s.contactFlags),
                        WhoopStore.packEcgSampleFlags(s.sampleFlags),
                        WhoopStore.packEcgLeadOff(s.leadOffI),
                        WhoopStore.packEcgLeadOff(s.leadOffQ)])
                    ecgCandidateWritten += 1
                }
            }
            // Every remaining v18 slot (v31), one compact blob per strap-second. Persist-only, same as
            // steps/sleepState/ppgHr/ppgWaveform: not added to the 8-field return tuple. A sample whose
            // slots are all absent packs to empty and is SKIPPED rather than banking a meaningless row —
            // which is also what keeps a WHOOP 4.0 offload from writing here at all.
            if !streams.v18Aux.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO v18AuxSample (deviceId, ts, fields) VALUES (?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.v18Aux {
                    let blob = V18AuxCodec.pack(s)
                    if blob.isEmpty { continue }
                    try stmt.execute(arguments: [deviceId, s.ts, blob])
                    v18Written += db.changesCount   // accepted, not offered: DO NOTHING on a re-offload (W02-012)
                }
            }
            return (hr, rr, ev, bat, spo2, skin, resp, grav)
        }

        // Rolling retention is amortised. The delete finds the Nth-newest row by rank, so it walks up to
        // `v18AuxRetentionRows` index entries. The 604,800-row cap is swept
        // once per `v18AuxPruneEveryRows` rows instead, which keeps newest-N-rows exactly (a time window
        // would not — a sporadically-worn strap's rows span far more than a week, and the census wants
        // that). Counter is per device because the delete is.
        if v18Written > 0 {
            let banked = (v18AuxRowsSincePrune[deviceId] ?? 0) + v18Written
            v18AuxRowsSincePrune[deviceId] = banked
            // BEST-EFFORT, and it has to be: the rows above are already committed, because the sweep is
            // now its own transaction rather than riding the insert's. A throw here would surface as an
            // insert failure and make Backfiller re-send a chunk it has already banked. Leaving the budget
            // unspent instead means the next batch simply retries the sweep.
            if banked >= v18AuxPruneEveryRows,
               (try? syncWrite { db in
                   try db.execute(sql: """
                       DELETE FROM v18AuxSample WHERE deviceId = ? AND ts < (
                           SELECT MIN(ts) FROM (
                               SELECT ts FROM v18AuxSample WHERE deviceId = ? ORDER BY ts DESC LIMIT ?))
                       """, arguments: [deviceId, deviceId, v18AuxRetentionRows])
               }) != nil {
                v18AuxRowsSincePrune[deviceId] = 0
            }
        }
        // #1911 rolling retention for the waveform blobs, amortised and best-effort on exactly the same
        // terms as the aux sweep above (see `ppgWaveformRetentionRows` for why this is a newest-N cap and
        // not an age-based drop). Its own counter and its own transaction: a batch routinely writes one of
        // these two tables and not the other, and a failed sweep here must not fail an insert whose rows
        // are already committed — leaving the budget unspent simply retries on the next batch.
        if ppgWaveformWritten > 0 {
            let banked = (ppgWaveformRowsSincePrune[deviceId] ?? 0) + ppgWaveformWritten
            ppgWaveformRowsSincePrune[deviceId] = banked
            if banked >= ppgWaveformPruneEveryRows,
               (try? syncWrite { db in
                   try db.execute(sql: """
                       DELETE FROM ppgWaveformSample WHERE deviceId = ? AND ts < (
                           SELECT MIN(ts) FROM (
                               SELECT ts FROM ppgWaveformSample WHERE deviceId = ? ORDER BY ts DESC LIMIT ?))
                       """, arguments: [deviceId, deviceId, ppgWaveformRetentionRows])
               }) != nil {
                ppgWaveformRowsSincePrune[deviceId] = 0
            }
        }
        // #891 rolling retention for the ECG-candidate blobs, amortised and best-effort on exactly the same
        // terms as the ppg-waveform sweep above (see `ecgCandidateRetentionRows`): its own counter, its own
        // transaction, and the DELETE scoped by deviceId so one strap's sweep never evicts another's rows.
        if ecgCandidateWritten > 0 {
            let banked = (ecgCandidateRowsSincePrune[deviceId] ?? 0) + ecgCandidateWritten
            ecgCandidateRowsSincePrune[deviceId] = banked
            if banked >= ecgCandidatePruneEveryRows,
               (try? syncWrite { db in
                   try db.execute(sql: """
                       DELETE FROM ecgCandidateSample WHERE deviceId = ? AND ts < (
                           SELECT MIN(ts) FROM (
                               SELECT ts FROM ecgCandidateSample WHERE deviceId = ? ORDER BY ts DESC LIMIT ?))
                       """, arguments: [deviceId, deviceId, ecgCandidateRetentionRows])
               }) != nil {
                ecgCandidateRowsSincePrune[deviceId] = 0
            }
        }
        // `v18Written` is accumulated by the write closure above and counted OUTSIDE it (the retention
        // sweep runs in its own transaction), so it is appended here rather than returned from `syncWrite`.
        // Rows ACCEPTED, exactly like the eight that precede it: a reconnect re-offloading records already
        // on disk adds nothing here, which is the property the census depends on.
        return (result.0, result.1, result.2, result.3, result.4, result.5, result.6, result.7, v18Written)
    }

    // MARK: - Raw sensor CSV export (diagnostic)

    /// Long-format CSV column order. One stream's columns are filled per row; the rest stay blank.
    private static let rawCSVHeader =
        "unix_s,iso_utc,stream,hr_bpm,rr_ms,grav_x,grav_y,grav_z,step_counter," +
        "ppg_bpm,ppg_conf,spo2_red,spo2_ir,skintemp_raw,resp_raw,band_sleep_state,event_kind,event_payload"

    /// One assembled CSV line: the 16 columns AFTER the `unix_s,iso_utc` prefix, joined with commas.
    /// `cols[0]` is the `stream` name; `cols[1...15]` are the per-stream value slots, only the ones
    /// that belong to this row's stream are non-empty.
    private struct RawCSVRow {
        let ts: Int
        var cols: [String]
        init(ts: Int) { self.ts = ts; self.cols = Array(repeating: "", count: 16) }
    }

    /// Export the decoded per-sample sensor streams NOOP already stores to ONE combined long-format CSV
    /// (header + one row per sample, all streams interleaved and sorted by ts ascending). On-device,
    /// plain text, no BLE hex, a diagnostic so power users / external devs can prototype sleep/activity/
    /// VBT algorithms on real data without a BLE stream (#308/#276/#322).
    ///
    /// `since` is a unix-seconds floor (caller passes now-24h); rows with `ts >= since` for `deviceId`
    /// are included. Writes to a temp file and returns its URL (caller hands it to the share/save flow).
    public func exportRawCSV(deviceId: String, since: TimeInterval) async throws -> URL {
        let floor = Int(since)
        let rows: [RawCSVRow] = try syncRead { db in
            var out: [RawCSVRow] = []

            // hr: stream=hr → hr_bpm (col 3).
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, bpm FROM hrSample WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "hr"
                row.cols[1] = WhoopStore.intStr(r["bpm"])
                out.append(row)
            }
            // rr: stream=rr → rr_ms (col 4). Same-second beats need the #823 tiebreak here too, and
            // more so: bare "ORDER BY ts" left their order UNDEFINED, so a raw export could differ
            // between runs over identical data. Emission order first, then the pre-v30 fallback.
            //
            // DELIBERATELY UNFILTERED by `srcChannel`, unlike the scoring read (#1071). This is the raw
            // dump: both optical channels are real measurements, and the whole point of keeping the
            // second one is that it can be inspected against the first. A raw export that silently hid
            // half the stored rows would make the duplication that motivated v32 un-diagnosable from an
            // export — which is exactly how it WAS diagnosed.
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, rrMs FROM rrInterval WHERE deviceId = ? AND ts >= ? " +
                "ORDER BY ts, ord, rrMs, seq",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "rr"
                row.cols[2] = WhoopStore.intStr(r["rrMs"])
                out.append(row)
            }
            // gravity: stream=gravity → grav_x/y/z (cols 5–7).
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, x, y, z FROM gravitySample WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "gravity"
                row.cols[3] = WhoopStore.dblStr(r["x"])
                row.cols[4] = WhoopStore.dblStr(r["y"])
                row.cols[5] = WhoopStore.dblStr(r["z"])
                out.append(row)
            }
            // steps: stream=steps → step_counter (col 8).
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, counter FROM stepSample WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "steps"
                row.cols[6] = WhoopStore.intStr(r["counter"])
                out.append(row)
            }
            // ppghr: stream=ppghr → ppg_bpm/ppg_conf (cols 9–10).
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, bpm, conf FROM ppgHrSample WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "ppghr"
                row.cols[7] = WhoopStore.dblStr(r["bpm"])
                row.cols[8] = WhoopStore.dblStr(r["conf"])
                out.append(row)
            }
            // spo2: stream=spo2 → spo2_red/spo2_ir (cols 11–12).
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, red, ir FROM spo2Sample WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "spo2"
                row.cols[9] = WhoopStore.intStr(r["red"])
                row.cols[10] = WhoopStore.intStr(r["ir"])
                out.append(row)
            }
            // skintemp: stream=skintemp → skintemp_raw (col 13).
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, raw FROM skinTempSample WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "skintemp"
                row.cols[11] = WhoopStore.intStr(r["raw"])
                out.append(row)
            }
            // resp: stream=resp → resp_raw (col 14).
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, raw FROM respSample WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "resp"
                row.cols[12] = WhoopStore.intStr(r["raw"])
                out.append(row)
            }
            // band sleep_state (#175): stream=band_sleep_state → band_sleep_state (col 15). The strap's
            // OWN @81 high-nibble state (0 wake/1 still/2 asleep/3 up), carried verbatim.
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, state FROM sleepStateSample WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "band_sleep_state"
                row.cols[13] = WhoopStore.intStr(r["state"])
                out.append(row)
            }
            // event: stream=event → event_kind/event_payload (cols 16–17). Payload is free-form JSON,
            // so it always goes through the CSV-quote escaper (commas/quotes/newlines).
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, kind, payloadJSON FROM event WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "event"
                row.cols[14] = WhoopStore.csvField(r["kind"] ?? "")
                row.cols[15] = WhoopStore.csvField(r["payloadJSON"] ?? "")
                out.append(row)
            }

            // Stable sort by ts ascending. `sorted` is not guaranteed stable, but ties only occur across
            // different streams at the same second, any interleaving of those is acceptable here.
            out.sort { $0.ts < $1.ts }
            return out
        }

        // Stream the rows straight to disk through a FileHandle, flushing in ~64 KB chunks, instead of
        // building the whole CSV as one in-memory String: a busy 24 h export otherwise held tens of MB
        // twice, the assembled String plus its UTF-8 Data copy that `write(to:)` makes, and could OOM
        // (#406, parity with the Android exporter's streaming fix).
        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(identifier: "UTC")
        iso.formatOptions = [.withInternetDateTime]

        let stamp = Int(Date().timeIntervalSince1970)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-raw-sensors-\(stamp).csv")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        try handle.write(contentsOf: Data((WhoopStore.rawCSVHeader + "\n").utf8))
        var buf = String()
        buf.reserveCapacity(72 * 1024)
        for row in rows {
            let isoStr = iso.string(from: Date(timeIntervalSince1970: TimeInterval(row.ts)))
            buf += "\(row.ts),\(isoStr),"
            buf += row.cols.joined(separator: ",")
            buf += "\n"
            if buf.utf8.count >= 64 * 1024 {
                try handle.write(contentsOf: Data(buf.utf8))
                buf.removeAll(keepingCapacity: true)
            }
        }
        if !buf.isEmpty { try handle.write(contentsOf: Data(buf.utf8)) }
        return url
    }

    /// Format an Int-valued GRDB column (blank for NULL) without the "Optional(...)" wrapper text.
    private static func intStr(_ v: Int?) -> String { v.map(String.init) ?? "" }

    /// Format a Double-valued GRDB column (blank for NULL). Plain decimal, `String(Double)` is
    /// round-trippable and locale-independent, which the comma-delimited CSV needs.
    private static func dblStr(_ v: Double?) -> String { v.map { String($0) } ?? "" }

    /// RFC-4180 CSV field: wrap in double quotes and double any embedded quote ONLY when the value
    /// contains a comma, quote, or newline. Used for the free-form event columns.
    private static func csvField(_ s: String) -> String {
        guard s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Test helpers

    public func storageStats_rowCountsForTest() async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
        // Bind each count to its own `let` before assembling the tuple. Returning the whole tuple of
        // inline `try Int.fetchOne(...) ?? 0` expressions made Swift's type-checker time out on some
        // toolchains/machines (reported by a contributor building locally); splitting it is
        // behaviour-identical and trivial to type-check.
        try syncRead { db in
            let hr = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hrSample") ?? 0
            let rr = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rrInterval") ?? 0
            let events = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event") ?? 0
            let battery = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM battery") ?? 0
            let spo2 = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM spo2Sample") ?? 0
            let skinTemp = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM skinTempSample") ?? 0
            let resp = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM respSample") ?? 0
            let gravity = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM gravitySample") ?? 0
            return (hr, rr, events, battery, spo2, skinTemp, resp, gravity)
        }
    }

    public func stepCountForTest() async throws -> Int {
        try syncRead { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM stepSample") ?? 0 }
    }

    /// The strap's OWN banked band sleep_state samples (#175) in `[from, to]` for one device, ascending by
    /// ts. Each `(ts, state)` is the raw @81 high-nibble code (0 wake/1 still/2 asleep/3 up) carried
    /// verbatim off the offload stream. Empty when the strap never reported it (a WHOOP 4.0, or a not-yet-
    /// offloaded window). Feeds the Deep Timeline band-state track and the per-session grid the H7 guard reads.
    public func sleepStateSamples(deviceId: String, from: Int, to: Int, limit: Int = 200_000) async throws
        -> [SleepStateSample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, state, rawByte FROM sleepStateSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                // rawByte (v31) is the whole @81 byte; nil on any pre-v31 row. `state` is unchanged, so
                // the H7 guard and the Deep Timeline track see exactly what they saw before.
                .map { SleepStateSample(ts: $0["ts"], state: $0["state"], rawByte: $0["rawByte"]) }
        }
    }

    public func sleepStateCountForTest() async throws -> Int {
        try syncRead { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sleepStateSample") ?? 0 }
    }

    /// The remaining 5/MG v18 per-second fields (v31) in `[from, to]` for one device, ascending by ts.
    /// Each row is one strap-second's slots, decoded from the compact blob by `V18AuxCodec`. Empty for a
    /// WHOOP 4.0 and for any window offloaded before v31. INSTRUMENTATION: no analytic calls this — it
    /// exists so the banked bytes are reachable for a census, and so the write path has a round-trip test.
    public func v18AuxSamples(deviceId: String, from: Int, to: Int, limit: Int = 200_000) async throws
        -> [V18AuxSample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, fields FROM v18AuxSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { V18AuxCodec.unpack($0["fields"] ?? Data(), ts: $0["ts"]) }
        }
    }

    public func v18AuxCountForTest() async throws -> Int {
        try syncRead { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v18AuxSample") ?? 0 }
    }

    public func ppgHrCountForTest() async throws -> Int {
        try syncRead { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ppgHrSample") ?? 0 }
    }

    /// The RAW v26 optical PPG waveform (#156 follow-up), one record per second, in `[from, to]` for one
    /// device, ascending by ts. `samples` are the raw i16 ADC counts the strap sent, unpacked from the
    /// compact on-disk BLOB (`packPpgSamples`/`unpackPpgSamples`). Empty when the strap never emitted
    /// v26 (the WHOOP 4.0 / v18-only common case) or the window has no v26-heavy stretch.
    public func ppgWaveformSamples(deviceId: String, from: Int, to: Int, limit: Int = 200_000) async throws
        -> [PpgWaveformSample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, samples, burstIndex, baseCode FROM ppgWaveformSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                // #2019: baseCode is SELECTed explicitly. This projection names its columns, so a new one
                // is invisible to it until it is listed — the write would have banked the base and every
                // read would have handed back nil, which is the same answer a legacy row gives and would
                // have looked like the column doing nothing.
                .map { PpgWaveformSample(ts: $0["ts"],
                                         samples: WhoopStore.unpackPpgSamples($0["samples"]),
                                         burstIndex: $0["burstIndex"],
                                         baseCode: $0["baseCode"]) }
        }
    }

    public func ppgWaveformCountForTest() async throws -> Int {
        try syncRead { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ppgWaveformSample") ?? 0 }
    }

    /// Full R16 records (#891) in `[from, to]` for one device, ascending by ts — waveform, status and
    /// lead-off diagnostics. EXPLICITLY UNVALIDATED: NOT an ECG, heart rate or diagnosis. Empty on every
    /// strap/layout but 5/MG v16.
    ///
    /// This is the HEAVY read — each row carries ~2 KB of waveform — so callers should bound it to a
    /// window they are about to draw, and use `ecgRecordingIndex` to decide what that window is.
    public func ecgCandidateSamples(deviceId: String, from: Int, to: Int, limit: Int = 200_000) async throws
        -> [EcgCandidateSample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, samples, recordIndex, declaredCount, quality, stateBits, classifierResult,
                       classifierState, progress, leadOffCount, contactMask, sampleFlags,
                       leadOffI, leadOffQ
                FROM ecgCandidateSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { row in
                    let samples = WhoopStore.unpackEcgCandidateSamples(row["samples"])
                    return EcgCandidateSample(
                        ts: row["ts"],
                        samples: samples,
                        recordIndex: row["recordIndex"],
                        declaredCount: row["declaredCount"],
                        // The flag array's length comes from the WAVEFORM, not from the blob: the bit
                        // packing rounds up to a byte, so the blob alone would report up to 7 flags that
                        // no sample owns.
                        sampleFlags: WhoopStore.unpackEcgSampleFlags(row["sampleFlags"] ?? Data(),
                                                                    count: samples.count),
                        contactFlags: WhoopStore.unpackEcgContactMask(row["contactMask"],
                                                                     count: row["leadOffCount"]),
                        quality: row["quality"],
                        stateBits: row["stateBits"],
                        classifierResult: row["classifierResult"],
                        classifierState: row["classifierState"],
                        progress: row["progress"],
                        leadOffCount: row["leadOffCount"],
                        leadOffI: WhoopStore.unpackEcgLeadOff(row["leadOffI"]),
                        leadOffQ: WhoopStore.unpackEcgLeadOff(row["leadOffQ"]))
                }
        }
    }

    /// One row's worth of R16 INDEX — everything needed to list and group recordings, and nothing that
    /// would require touching the waveform blob.
    ///
    /// The separation is the point. A recording is ~64 rows of ~2 KB each, and a table at
    /// `ecgCandidateRetentionRows` holds tens of thousands; building a recording list by reading full
    /// rows would load ~86 MB of waveform to display a list of dates. `storedCount` is computed as
    /// `length(samples) / 4` in SQL, which SQLite answers from the blob's header without reading its
    /// bytes.
    public struct EcgRecordIndexEntry: Equatable, Sendable {
        public let deviceId: String
        public let ts: Int
        /// The monotonic lifetime record index, or nil where the record's header could not be read.
        /// Contiguity in THIS is what defines one continuous recording — not contiguity in `ts`, which a
        /// strap-clock correction can break in the middle of a session.
        public let recordIndex: Int?
        /// Samples the record declared, and samples actually stored. These agree on every cleanly
        /// decoded record; storing both is what makes disagreement visible instead of silent.
        public let declaredCount: Int
        public let storedCount: Int
        public let quality: Int
        public let progress: Int
        public let leadOffCount: Int
        public let contactMask: Int

        public init(deviceId: String, ts: Int, recordIndex: Int?, declaredCount: Int, storedCount: Int,
                    quality: Int, progress: Int, leadOffCount: Int, contactMask: Int) {
            self.deviceId = deviceId
            self.ts = ts
            self.recordIndex = recordIndex
            self.declaredCount = declaredCount
            self.storedCount = storedCount
            self.quality = quality
            self.progress = progress
            self.leadOffCount = leadOffCount
            self.contactMask = contactMask
        }

        /// The record's contact entries, or `[]` where the record carried no slower stream.
        public var contactFlags: [Bool] {
            WhoopStore.unpackEcgContactMask(contactMask, count: leadOffCount)
        }
    }

    /// Every R16 row's index fields, ascending by (deviceId, ts), WITHOUT reading any waveform.
    ///
    /// Across all devices by default: a strap that was re-paired gets a new device id, and a recording
    /// made before that is still the same person's recording. Pass `deviceId` to narrow.
    public func ecgRecordingIndex(deviceId: String? = nil, limit: Int = 200_000) async throws
        -> [EcgRecordIndexEntry] {
        try syncRead { db in
            let sql = """
                SELECT deviceId, ts, recordIndex, declaredCount, length(samples) / 4 AS storedCount,
                       quality, progress, leadOffCount, contactMask
                FROM ecgCandidateSample
                \(deviceId == nil ? "" : "WHERE deviceId = ?")
                ORDER BY deviceId, ts LIMIT ?
                """
            let args: [DatabaseValueConvertible?] = deviceId == nil ? [limit] : [deviceId, limit]
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                .map { EcgRecordIndexEntry(deviceId: $0["deviceId"],
                                           ts: $0["ts"],
                                           recordIndex: $0["recordIndex"],
                                           declaredCount: $0["declaredCount"],
                                           storedCount: $0["storedCount"],
                                           quality: $0["quality"],
                                           progress: $0["progress"],
                                           leadOffCount: $0["leadOffCount"],
                                           contactMask: $0["contactMask"]) }
        }
    }

    public func ecgCandidateCountForTest() async throws -> Int {
        try syncRead { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ecgCandidateSample") ?? 0 }
    }

    /// Write newline-delimited JSON of every `ecgCandidateSample` row across all devices (#891) to `url`,
    /// one object per strap-second: `{"deviceId":…,"ts":…,"samples":[i18,…]}`, ascending by (deviceId, ts).
    /// Returns the number of rows written — 0 leaves an empty file, so the caller can delete it and no-op
    /// rather than share nothing. This is the Test Centre export path for the UNVALIDATED v16 candidate —
    /// the iOS/macOS analogue of Android's raw reject-archive export (on Apple v16 is decoded into this
    /// table, so it is NOT in the reject archive). NOT an ECG / heart rate / diagnosis; the samples are raw
    /// signed 18-bit MAX86176 FIFO values with no asserted scale. Read-only; touches no strap.
    ///
    /// Writes to a FILE rather than returning a `String`, and that is load-bearing rather than stylistic:
    /// a row holds ~500 samples, so a line is ~3 KB of JSON and a table at `ecgCandidateRetentionRows`
    /// serialises to tens of GB. Accumulating that in memory (and handing it to a writer that copies it
    /// again) is an out-of-memory kill on iOS, not a slow export. The cursor streams row-by-row into a
    /// bounded buffer that is flushed every `exportFlushBytes`, so peak memory is the buffer plus one row
    /// whatever the table holds. Sorted keys keep the file diffable.
    public func writeEcgCandidateExportJSONL(to url: URL) async throws -> Int {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        guard fm.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        return try syncRead { db in
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            var buf = Data()
            buf.reserveCapacity(WhoopStore.exportFlushBytes * 2)
            var rows = 0
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT deviceId, ts, samples, recordIndex, declaredCount, quality, stateBits,
                       classifierResult, classifierState, progress, leadOffCount, contactMask,
                       sampleFlags, leadOffI, leadOffQ
                FROM ecgCandidateSample ORDER BY deviceId, ts
                """)
            while let row = try cursor.next() {
                let samples = WhoopStore.unpackEcgCandidateSamples(row["samples"])
                let line = EcgCandidateExportLine(
                    deviceId: row["deviceId"], ts: row["ts"], samples: samples,
                    recordIndex: row["recordIndex"], declaredCount: row["declaredCount"],
                    // Flags export as 0/1 rather than true/false: the consumer is an offline numeric
                    // analysis, and a column of booleans in JSON is one more thing for it to coerce.
                    sampleFlags: WhoopStore.unpackEcgSampleFlags(row["sampleFlags"] ?? Data(),
                                                                 count: samples.count).map { $0 ? 1 : 0 },
                    contactFlags: WhoopStore.unpackEcgContactMask(row["contactMask"],
                                                                  count: row["leadOffCount"]).map { $0 ? 1 : 0 },
                    quality: row["quality"], stateBits: row["stateBits"],
                    classifierResult: row["classifierResult"], classifierState: row["classifierState"],
                    progress: row["progress"], leadOffCount: row["leadOffCount"],
                    leadOffI: WhoopStore.unpackEcgLeadOff(row["leadOffI"]),
                    leadOffQ: WhoopStore.unpackEcgLeadOff(row["leadOffQ"]))
                buf.append(try enc.encode(line))
                buf.append(0x0A)          // "\n"
                rows += 1
                if buf.count >= WhoopStore.exportFlushBytes {
                    try handle.write(contentsOf: buf)
                    buf.removeAll(keepingCapacity: true)
                }
            }
            if !buf.isEmpty { try handle.write(contentsOf: buf) }
            return rows
        }
    }

    public func deviceRowForTest(id: String) async throws -> (mac: String?, name: String?)? {
        try syncRead { db in
            guard let row = try Row.fetchOne(db,
                sql: "SELECT mac, name FROM device WHERE id = ?", arguments: [id]) else {
                return nil
            }
            return (row["mac"], row["name"])
        }
    }

    /// Write an R-R row the way a PRE-v30 build did: `ord` left NULL, emission order never recorded.
    /// The normal insert path always stamps `ord`, so there is otherwise no way to construct the
    /// legacy shape — and the read-order fallback for existing user data is exactly the branch most
    /// worth testing rather than assuming. Test-only (#823).
    public func insertLegacyRrWithoutOrdForTest(deviceId: String, ts: Int, rrMs: Int) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO rrInterval (deviceId, ts, rrMs, seq, ord) VALUES (?, ?, ?, 0, NULL)
                ON CONFLICT(deviceId, ts, rrMs, seq) DO NOTHING
                """, arguments: [deviceId, ts, rrMs])
        }
    }

    /// The stored `ord` values for one second, in read order. Test-only (#823).
    public func rrOrdValuesForTest(deviceId: String, ts: Int) async throws -> [Int?] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ord FROM rrInterval WHERE deviceId = ? AND ts = ?
                ORDER BY ts ASC, ord ASC, rrMs ASC, seq ASC
                """, arguments: [deviceId, ts]).map { $0["ord"] }
        }
    }

    /// Every STORED R-R row for a device as `(rrMs, srcChannel)`, bypassing the scoring read's channel
    /// filter. Test-only (#1071): the fix is "filter at read, keep both channels on disk", and the only
    /// way to assert the second half is to look at the table itself rather than through `rrIntervals`.
    public func rrRowsWithChannelForTest(deviceId: String) async throws -> [(rrMs: Int, srcChannel: Int?)] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT rrMs, srcChannel FROM rrInterval WHERE deviceId = ?
                ORDER BY ts ASC, ord ASC, rrMs ASC, seq ASC
                """, arguments: [deviceId]).map { (rrMs: $0["rrMs"], srcChannel: $0["srcChannel"]) }
        }
    }

    /// Run the `v35-rr-future-quarantine` backfill predicate with an EXPLICIT `now` (the migration itself
    /// uses `strftime('%s','now')`; a test needs a fixed instant). Marks every stored R-R beat whose ts is
    /// after `nowSeconds`. Test-only (#1073).
    public func markFutureRrSuspectForTest(nowSeconds: Int) async throws {
        try syncWrite { db in
            try db.execute(sql: "UPDATE rrInterval SET tsSuspect = 1 WHERE ts > ?", arguments: [nowSeconds])
        }
    }

    /// Every STORED R-R row for a device as `(ts, tsSuspect)`, bypassing the scoring read's filter — so a
    /// test can assert which rows were quarantined AND that none were deleted. Test-only (#1073).
    public func rrSuspectRowsForTest(deviceId: String) async throws -> [(ts: Int, tsSuspect: Int?)] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, tsSuspect FROM rrInterval WHERE deviceId = ? ORDER BY ts ASC
                """, arguments: [deviceId]).map { (ts: $0["ts"], tsSuspect: $0["tsSuspect"]) }
        }
    }
}
