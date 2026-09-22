import CoreBluetooth
import WhoopProtocol

/// Which strap the user is pairing. NOOP supports exactly one: WHOOP 5.0 / MG. The enum is kept
/// (rather than collapsed to a constant) because the picker key `selectedWhoopModel` is persisted and
/// a stored value still has to decode to SOMETHING on relaunch and restore.
public enum WhoopModel: String, CaseIterable, Identifiable, Hashable {
    case whoop5mg = "WHOOP 5.0 / MG"

    public var id: String { rawValue }
    public var displayName: String { rawValue }

    /// The protocol-layer device family this model maps to — drives framing, characteristic UUIDs,
    /// and the CLIENT_HELLO handshake.
    public var deviceFamily: DeviceFamily { .whoop5 }

    /// The model the user last chose, read from the same key the pickers write
    /// (`@AppStorage("selectedWhoopModel")`). Used as the default for scans the user
    /// didn't directly trigger — BLE state restoration, power-on reconnect. A stale value from an
    /// older install (e.g. "WHOOP 4.0") no longer decodes and falls back to the one supported model.
    public static var persisted: WhoopModel {
        UserDefaults.standard.string(forKey: "selectedWhoopModel").flatMap(WhoopModel.init(rawValue:)) ?? .whoop5mg
    }

    /// The BLE service to scan for, and to discover after connecting, for this model.
    /// Mirrors `BLEManager.whoop5Service` (kept inline here so the enum stays nonisolated —
    /// `BLEManager` is `@MainActor`). CBUUID compares by value, so it matches the manager's
    /// constant in every `switch`/scan filter.
    public var scanService: CBUUID { CBUUID(string: "fd4b0001-cce1-4033-93ce-002d5875f58a") }
}
