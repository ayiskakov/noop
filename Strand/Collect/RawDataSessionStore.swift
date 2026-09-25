import Combine
import Foundation
import WhoopStore

/// Persistent, user-controlled 5/MG capture sessions. This is the iOS/macOS twin of Android's
/// GroundTruthCollector: it records bounded raw-data windows with optional comments.
@MainActor
final class RawDataSessionStore: ObservableObject {
    struct Event: Codable, Identifiable, Equatable {
        var id = UUID()
        var atMs: Int64
        let kind: String
        var markerId: String?
        var markerType: String?
        var text: String?
    }

    struct Session: Codable, Identifiable, Equatable {
        let id: String
        let deviceId: String
        let startedAtMs: Int64
        var endedAtMs: Int64?
        var capturedStartedAtMs: Int64?
        var capturedEndedAtMs: Int64?
        var comment: String
        var exported: Bool
        var lastExportedAtMs: Int64?
        var events: [Event]

        var active: Bool { endedAtMs == nil }
    }

    @Published private(set) var sessions: [Session] = []
    var active: Session? { sessions.first(where: \.active) }

    /// Where the sessions' IMU buffers are banked; tests pass a throwaway store.
    let imu: ImuSessionFileStore
    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(directory override: URL? = nil, fileManager: FileManager = .default, imu: ImuSessionFileStore = .shared) {
        self.imu = imu
        let base = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                         appropriateFor: nil, create: true)) ?? fileManager.temporaryDirectory
        directory = override ?? base.appendingPathComponent("OpenWhoop/RawDataSessions", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        reload()
    }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: nil)) ?? []
        sessions = urls.filter { $0.pathExtension == "json" }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? decoder.decode(Session.self, from: $0) }
            .sorted { $0.startedAtMs > $1.startedAtMs }
    }

    @discardableResult
    func start(deviceId: String, now: Date = Date()) -> Session? {
        guard active == nil else { return nil }
        let millis = Int64(now.timeIntervalSince1970 * 1_000)
        let started = Event(atMs: millis, kind: "start")
        let session = Session(id: String(millis), deviceId: deviceId, startedAtMs: millis,
                              endedAtMs: nil, capturedStartedAtMs: millis, capturedEndedAtMs: nil,
                              comment: "", exported: false, lastExportedAtMs: nil, events: [started])
        sessions.insert(session, at: 0)
        persist(session)
        imu.start(id: session.id, deviceId: deviceId, fromMs: millis)
        return session
    }

    func stop(now: Date = Date()) {
        let activeId = active?.id
        mutateActive { session in
            let millis = Int64(now.timeIntervalSince1970 * 1_000)
            session.endedAtMs = millis
            session.capturedEndedAtMs = millis
            session.events.append(Event(atMs: millis, kind: "stop"))
        }
        if let activeId { imu.complete(id: activeId, toMs: Int64(now.timeIntervalSince1970 * 1_000)) }
    }

    @discardableResult
    func createHistorical(deviceId: String, from: Date, to: Date) -> Session? {
        let fromMs = Int64(from.timeIntervalSince1970 * 1_000)
        let toMs = Int64(to.timeIntervalSince1970 * 1_000)
        guard validRange(fromMs, toMs) else { return nil }
        let id = String(Int64(Date().timeIntervalSince1970 * 1_000))
        let events = [Event(atMs: fromMs, kind: "start"), Event(atMs: toMs, kind: "stop")]
        let session = Session(id: id, deviceId: deviceId, startedAtMs: fromMs, endedAtMs: toMs,
                              capturedStartedAtMs: nil, capturedEndedAtMs: nil, comment: "",
                              exported: false, lastExportedAtMs: nil, events: events)
        sessions.insert(session, at: 0); persist(session)
        imu.register(id: id, deviceId: deviceId, fromMs: fromMs, toMs: toMs)
        return session
    }

    func setRange(sessionId: String, from: Date, to: Date) {
        let fromMs = Int64(from.timeIntervalSince1970 * 1_000)
        let toMs = Int64(to.timeIntervalSince1970 * 1_000)
        guard validRange(fromMs, toMs) else { return }
        mutate(sessionId) { session in
            guard !session.active else { return }
            session = Session(id: session.id, deviceId: session.deviceId, startedAtMs: fromMs,
                              endedAtMs: toMs, capturedStartedAtMs: session.capturedStartedAtMs,
                              capturedEndedAtMs: session.capturedEndedAtMs, comment: session.comment,
                              exported: false, lastExportedAtMs: nil, events: session.events)
        }
        if let session = sessions.first(where: { $0.id == sessionId }) {
            imu.register(id: sessionId, deviceId: session.deviceId, fromMs: fromMs, toMs: toMs)
        }
    }

    func setComment(_ comment: String, sessionId: String) {
        mutate(sessionId) { $0.comment = String(comment.prefix(4_000)) }
    }

    @discardableResult
    func addMarker(sessionId: String, at: Date, type: String, text: String) -> Event? {
        guard Self.markerTypes.contains(type) else { return nil }
        var added: Event?
        mutate(sessionId) { session in
            let atMs = Self.clamp(Int64(at.timeIntervalSince1970 * 1_000), to: session)
            let marker = Event(atMs: atMs, kind: "marker", markerId: UUID().uuidString,
                               markerType: type, text: String(text.prefix(500)))
            session.events.append(marker)
            added = marker
        }
        return added
    }

    func updateMarker(sessionId: String, markerId: String, at: Date, type: String, text: String) {
        guard Self.markerTypes.contains(type) else { return }
        mutate(sessionId) { session in
            guard let index = session.events.firstIndex(where: { $0.markerId == markerId }) else { return }
            session.events[index].atMs = Self.clamp(Int64(at.timeIntervalSince1970 * 1_000), to: session)
            session.events[index].markerType = type
            session.events[index].text = String(text.prefix(500))
        }
    }

    func deleteMarker(sessionId: String, markerId: String) {
        mutate(sessionId) { $0.events.removeAll { $0.kind == "marker" && $0.markerId == markerId } }
    }

    func markExported(_ sessionId: String, now: Date = Date()) {
        mutate(sessionId) {
            $0.exported = true
            $0.lastExportedAtMs = Int64(now.timeIntervalSince1970 * 1_000)
        }
    }

    @discardableResult
    func removeMetadata(_ sessionId: String,
                        removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) -> Bool {
        guard sessions.first(where: { $0.id == sessionId })?.active == false else { return false }
        guard imu.deleteFiles(sessionId, removeItem: removeItem) else { return false }
        imu.remove(id: sessionId)
        do {
            let metadata = file(sessionId)
            if FileManager.default.fileExists(atPath: metadata.path) { try removeItem(metadata) }
        } catch { return false }
        sessions.removeAll { $0.id == sessionId }
        return true
    }

    private func mutateActive(_ body: (inout Session) -> Void) {
        guard let index = sessions.firstIndex(where: \.active) else { return }
        body(&sessions[index])
        persist(sessions[index])
    }

    private func mutate(_ id: String, _ body: (inout Session) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        body(&sessions[index])
        persist(sessions[index])
    }

    private func persist(_ session: Session) {
        guard let data = try? encoder.encode(session) else { return }
        try? data.write(to: file(session.id), options: .atomic)
    }

    private func file(_ id: String) -> URL { directory.appendingPathComponent("session-\(id).json") }

    private func validRange(_ from: Int64, _ to: Int64) -> Bool {
        from > 0 && from <= to && to - from <= 7 * 24 * 60 * 60 * 1_000
    }

    static let markerTypes = ["moment", "start", "end", "issue"]

    private static func clamp(_ atMs: Int64, to session: Session) -> Int64 {
        min(max(atMs, session.startedAtMs), session.endedAtMs ?? Int64(Date().timeIntervalSince1970 * 1_000))
    }

    func exportEntries(for session: Session, sensorAvailable: Bool = false) -> [FileExport.BundleEntry] {
        var meta: [String: Any] = [
            "schema_version": 3, "capture_kind": "whoop_5mg_raw_data",
            "session_id": session.id, "device_id": session.deviceId,
            "started_at_ms": session.startedAtMs, "ended_at_ms": session.endedAtMs ?? session.startedAtMs,
            "comment": session.comment,
            "sensor_export_available": sensorAvailable,
            "device_family": "iOS",
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            "markers": session.events.filter {
                $0.kind == "marker" && $0.atMs >= session.startedAtMs
                    && $0.atMs <= (session.endedAtMs ?? session.startedAtMs)
            }.map { marker in
                ["id": marker.markerId ?? "", "at_ms": marker.atMs,
                 "type": marker.markerType ?? "moment", "text": marker.text ?? ""] as [String: Any]
            },
        ]
        if let value = session.capturedStartedAtMs { meta["captured_started_at_ms"] = value }
        if let value = session.capturedEndedAtMs { meta["captured_ended_at_ms"] = value }
        let metaData = (try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        let endMs = session.endedAtMs ?? session.startedAtMs
        let publicEvents = [Event(atMs: session.startedAtMs, kind: "start")]
            + session.events.filter {
                $0.kind == "marker" && $0.atMs >= session.startedAtMs && $0.atMs <= endMs
            }.sorted { $0.atMs < $1.atMs }
            + [Event(atMs: endMs, kind: "stop")]
        let eventData = publicEvents.compactMap { event -> Data? in
            var row: [String: Any] = ["at_ms": event.atMs, "kind": event.kind]
            if event.kind == "marker" {
                if let value = event.markerId { row["marker_id"] = value }
                if let value = event.markerType { row["marker_type"] = value }
                if let value = event.text { row["text"] = value }
            }
            return try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        }.reduce(into: Data()) { $0.append($1); $0.append(0x0A) }
        return [
            .init(name: "meta.json", data: metaData),
            .init(name: "events.jsonl", data: eventData),
        ]
    }
}

/// The end of a live 5/MG raw-data session (W06-025). The strap produces each one-second IMU buffer several
/// seconds after that second (5.7 s from timestamp to arrival in a 2026-09-25 session, its clock just set),
/// and a stop discards the buffers it has not produced yet, live and in its own history. Stopping the stream
/// the moment Stop was pressed therefore lost the session's last seconds, and every session read
/// "incomplete". The collector waits for the buffer of the last full second first, bounded so a stalled
/// stream still stops.
enum RawSessionTail {
    static let timeout: TimeInterval = 10
    static let pollInterval: TimeInterval = 0.25

    enum Outcome: Equatable {
        /// Nothing was awaited: the session holds no full second, or no stop will go out to discard its tail.
        case notAwaited
        /// The buffer for the session's last full second was banked before the stop.
        case delivered
        /// The wait ended without it, `missing` seconds short (nil when no buffer was banked at all): the
        /// capture was disarmed, as a disconnect does, after which no stop can go out; or the wait timed out.
        case short(missing: Int?, disarmed: Bool)
    }

    /// Why a stop sends no STOP_RAW_DATA.
    enum Unsent: Equatable {
        /// No capture is armed on this link: none was, or a disconnect cleared it.
        case notArmed
        /// Continuous raw capture is on, so the stream keeps running.
        case continuousCapture
    }

    /// Ends the live session in `store` at `pressedAt`, then stops the stream once its tail is banked.
    /// The session is saved as ended before the wait (W06-036): a collector opened during the wait loads it
    /// ended, so it can neither re-arm the stream for it nor stop it a second time and move its end. The tail
    /// still banks, because the session's IMU window closes at the press, after its last full second, and it
    /// is written to disk once the stream has stopped. The wait runs only while `armed` says a stop will go
    /// out, since only a stop discards the tail (W06-039).
    @MainActor
    static func stop(_ store: RawDataSessionStore, pressedAt: Date, armed: () -> Bool,
                     stopStream: (Outcome) async -> Void,
                     timeout: TimeInterval = RawSessionTail.timeout, now: () -> Date = Date.init,
                     sleep: (TimeInterval) async -> Void = RawSessionTail.pause) async {
        guard let active = store.active else { return }
        store.stop(now: pressedAt)
        var outcome = Outcome.notAwaited
        if armed(), let bounds = RawDataCollectorView.fullSecondBounds(
            fromMs: active.startedAtMs, toMs: Int64(pressedAt.timeIntervalSince1970 * 1_000)) {
            outcome = await wait(for: bounds.to, newest: { store.imu.newestBankedTs(active.id) },
                                 armed: armed, timeout: timeout, now: now, sleep: sleep)
        }
        await stopStream(outcome)
        store.imu.prepareForRead(active.id)
    }

    /// Waits until the buffer for `lastSecond` is banked, the capture is disarmed, or `timeout` passes.
    @MainActor
    static func wait(for lastSecond: Int, newest: () -> Int64?, armed: () -> Bool,
                     timeout: TimeInterval = RawSessionTail.timeout, now: () -> Date = Date.init,
                     sleep: (TimeInterval) async -> Void = RawSessionTail.pause) async -> Outcome {
        let deadline = now().addingTimeInterval(timeout)
        while true {
            if let banked = newest(), banked >= Int64(lastSecond) { return .delivered }
            let missing = newest().map { lastSecond - Int($0) }
            if !armed() { return .short(missing: missing, disarmed: true) }
            if now() >= deadline { return .short(missing: missing, disarmed: false) }
            await sleep(pollInterval)
        }
    }

    /// Sleeps `seconds`, even in a cancelled task: `Task.sleep` would throw at once there, and the wait would
    /// poll the main actor without pause until its deadline (W06-042). A cancelled stop still ends on time.
    static func pause(_ seconds: TimeInterval) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.resume() }
        }
    }

    /// The strap-log line for a stop with this outcome. It states what was banked and when no stop went
    /// out, never why the strap was late.
    static func stopLogLine(_ outcome: Outcome, unsent: Unsent? = nil) -> String {
        var line: String
        switch outcome {
        case .notAwaited: line = "Raw-data session: stopped"
        case .delivered: line = "Raw-data session: stopped after the last full second was banked"
        case .short(let missing, let disarmed):
            let what = missing.map { "\($0) s short of the last full second" } ?? "with no IMU buffer banked"
            let why = disarmed ? "when the capture was disarmed" : "after waiting \(Int(timeout)) s"
            line = "Raw-data session: stopped \(what), \(why)"
        }
        switch unsent {
        case nil: break
        case .notArmed: line += "; no stop sent: no capture is armed on this link"
        case .continuousCapture: line += "; no stop sent: continuous raw capture is on"
        }
        return line
    }
}
