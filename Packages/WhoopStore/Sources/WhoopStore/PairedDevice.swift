import Foundation

/// A device the user has paired. `id` is the same string used as `deviceId` in every sample table's
/// `(deviceId, ts)` key — so a device's raw samples are already isolated by id, with no per-row source
/// column needed. The existing WHOOP keeps id "my-whoop" (no sample migration).
public struct PairedDevice: Equatable, Sendable, Identifiable {
    public let id: String                 // == deviceId in sample tables; e.g. "my-whoop", "apple-watch-1"
    public var brand: String              // "WHOOP", "Apple"
    public var model: String              // "WHOOP 5.0 / MG", "Apple Watch"
    public var nickname: String?          // user-renamable; nil → show brand+model
    public var peripheralId: String?      // CBPeripheral.identifier.uuidString (iOS/Mac); nil until adopted
    public var sourceKind: SourceKind
    public var capabilities: Set<Metric>
    public var status: DeviceStatus
    public var addedAt: Int               // unix seconds
    public var lastSeenAt: Int

    public init(id: String, brand: String, model: String, nickname: String? = nil,
                peripheralId: String? = nil,
                sourceKind: SourceKind, capabilities: Set<Metric>, status: DeviceStatus,
                addedAt: Int, lastSeenAt: Int) {
        self.id = id; self.brand = brand; self.model = model; self.nickname = nickname
        self.peripheralId = peripheralId
        self.sourceKind = sourceKind; self.capabilities = capabilities; self.status = status
        self.addedAt = addedAt; self.lastSeenAt = lastSeenAt
    }

    /// A user nickname wins; otherwise "Brand Model" — but collapse to just the model when it already
    /// carries the brand (so a WHOOP whose model is also "WHOOP" reads "WHOOP", not "WHOOP WHOOP", and a
    /// "WHOOP 5.0 / MG" model reads "WHOOP 5.0 / MG").
    public var displayName: String {
        if let nickname { return nickname }
        if model.isEmpty || model == brand { return brand }
        if model.localizedCaseInsensitiveContains(brand) { return model }
        return "\(brand) \(model)"
    }

    /// True for a data-partition source (a cloud API pull or a file/CSV import) rather than a live,
    /// connectable device. UI that offers "make active" must exclude these: activating one would demote
    /// whatever live device (WHOOP, a BLE strap, Apple Watch) currently drives BLE routing + day-owner
    /// priority 0 — an import source has no live connection to hand that role to.
    public var isImportSource: Bool { sourceKind == .cloudImport || sourceKind == .fileImport }
}

public enum DeviceStatus: String, Sendable, CaseIterable { case active, paired, archived }

public enum SourceKind: String, Sendable, CaseIterable {
    case liveBLE, historyBLE, cloudImport, fileImport
    /// A live FTMS (Fitness Machine Service, 0x1826) gym machine — treadmill / indoor bike / rower /
    /// cross-trainer. Streams a live machine-data + HR session that records via the existing live-workout
    /// path. Additive: existing rows never carry this; only the gym-equipment wizard writes it.
    case ftms
    /// Apple Watch streamed via HealthKit (live HealthKit observer + background delivery). Apple-only,
    /// no Android twin. Additive: only the Apple Watch device registration writes it.
    case liveAppleWatch
    /// A GPX/TCX/FIT activity file imported under the `activity-file` device (#137). Distinct from
    /// `fileImport` (a whole-day WHOOP CSV export) so the day-owner resolver can rank it BELOW day-spanning
    /// imports: a 90-minute ride must never displace a full-day source that has HR for the same day. It
    /// wins ownership only when nothing else has data (a genuinely strap-less day), where its measured HR
    /// lights the day Effort. Additive (no DB migration): only the activity-file importer writes it.
    case activityFile
}

/// Canonical metric a source can provide. Drives capability-aware UI + the day-owner resolver.
public enum Metric: String, Sendable, CaseIterable, Codable {
    case hr, hrv, spo2, skinTemp, steps, sleep, strainLoad
}
