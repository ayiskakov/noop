import Foundation

/// Which Whoop hardware generation a connection / capture belongs to.
///
/// NOOP supports exactly one: WHOOP 5.0 / MG. The type is kept (rather than collapsed away) because
/// every frame, capture and registry row still has to say WHICH hardware it belongs to — a WHOOP 4.0
/// strap is still *recognised* on the air (`WhoopGattServiceFamily.whoop4`), it is simply not
/// connectable, and a reader that finds `.whoop5` on a row knows that was asserted rather than assumed.
///
/// This package is platform-pure: it never imports CoreBluetooth. The app layer is responsible
/// for turning the UUID *strings* exposed here into `CBUUID` values. Keeping CBUUID out of this
/// module lets the protocol code run on any platform (and in CLI tools / tests) unchanged.
public enum DeviceFamily: String, Sendable, CaseIterable {
    /// Whoop 5.0 / MG — CRC16-Modbus header check, "puffin" packet types.
    case whoop5
}

/// WHOOP custom GATT service families visible in advertisements.
///
/// Only `.maverickGooseFD4B` is connectable in NOOP. The other services are protocol facts from
/// reverse engineering and are diagnostic-only: `.whoop4` is the WHOOP 4.0 service, recognised so a
/// 4.0 strap is reported as detected-but-unsupported instead of silently ignored; the rest have no
/// mapped connection framing. `.puffin1150` is intentionally qualified because NOOP already uses
/// "puffin" for the fd4b/Maverick-Goose packet framing.
public enum WhoopGattServiceFamily: String, Sendable, CaseIterable {
    case whoop4
    case maverickGooseFD4B
    case puffin1150
    case monument
    case symphony

    public var displayName: String {
        switch self {
        case .whoop4: return "WHOOP 4.0"
        case .maverickGooseFD4B: return "WHOOP 5.0 / MG fd4b (Maverick/Goose)"
        case .puffin1150: return "WHOOP PUFFIN service 1150"
        case .monument: return "WHOOP MONUMENT"
        case .symphony: return "WHOOP SYMPHONY"
        }
    }

    public var serviceUUIDString: String {
        switch self {
        case .whoop4: return "61080001-8d6d-82b8-614a-1c8cb0f8dcc6"
        case .maverickGooseFD4B: return "fd4b0001-cce1-4033-93ce-002d5875f58a"
        case .puffin1150: return "11500001-6215-11ee-8c99-0242ac120002"
        case .monument: return "8a580001-2fe8-4796-9267-b87a2b0c8234"
        case .symphony: return "59830001-5955-419b-bb8d-c8262926af23"
        }
    }

    public var characteristicUUIDStrings: [String] {
        switch self {
        case .maverickGooseFD4B: return DeviceFamily.whoop5.characteristicUUIDStrings
        case .whoop4:
            return Self.unsupportedCharacteristicUUIDStrings(
                prefix: "6108", suffix: "8d6d-82b8-614a-1c8cb0f8dcc6")
        case .puffin1150:
            return Self.unsupportedCharacteristicUUIDStrings(
                prefix: "1150", suffix: "6215-11ee-8c99-0242ac120002")
        case .monument:
            return Self.unsupportedCharacteristicUUIDStrings(
                prefix: "8a58", suffix: "2fe8-4796-9267-b87a2b0c8234")
        case .symphony:
            return Self.unsupportedCharacteristicUUIDStrings(
                prefix: "5983", suffix: "5955-419b-bb8d-c8262926af23")
        }
    }

    public var connectableDeviceFamily: DeviceFamily? {
        switch self {
        case .maverickGooseFD4B: return .whoop5
        case .whoop4, .puffin1150, .monument, .symphony: return nil
        }
    }

    public var isConnectable: Bool { connectableDeviceFamily != nil }

    public var diagnosticUnsupportedMessage: String {
        "\(displayName) detected but unsupported; NOOP will not connect or send commands."
    }

    public static var unsupportedFamilies: [WhoopGattServiceFamily] {
        allCases.filter { !$0.isConnectable }
    }

    public static var unsupportedServiceUUIDStrings: [String] {
        unsupportedFamilies.map(\.serviceUUIDString)
    }

    public static func forServiceUUIDString(_ uuid: String?) -> WhoopGattServiceFamily? {
        guard let normalized = uuid?.lowercased() else { return nil }
        return allCases.first { $0.serviceUUIDString == normalized }
    }

    public static func firstUnsupported(in serviceUUIDStrings: [String]) -> WhoopGattServiceFamily? {
        serviceUUIDStrings.compactMap { forServiceUUIDString($0) }.first { !$0.isConnectable }
    }

    private static func unsupportedCharacteristicUUIDStrings(prefix: String, suffix: String) -> [String] {
        ["0002", "0003", "0004", "0005", "0007"].map { "\(prefix)\($0)-\(suffix)" }
    }
}

public struct WhoopGattScanDecision: Equatable, Sendable {
    public var shouldConnect: Bool
    public var unsupportedFamily: WhoopGattServiceFamily?

    public init(shouldConnect: Bool, unsupportedFamily: WhoopGattServiceFamily? = nil) {
        self.shouldConnect = shouldConnect
        self.unsupportedFamily = unsupportedFamily
    }
}

/// Decide whether an advertisement found by the broadened diagnostic scan should enter GATT.
///
/// Empty service lists preserve the pre-diagnostic behaviour because some platform callbacks omit the
/// advertised service UUIDs even though the service-filtered scan matched. When services are present,
/// only the selected connectable service may connect; unsupported families are reported for logging.
public func whoopGattScanDecision(
    selectedServiceUUIDString: String,
    advertisedServiceUUIDStrings: [String]
) -> WhoopGattScanDecision {
    let advertised = Set(advertisedServiceUUIDStrings.map { $0.lowercased() })
    if advertised.isEmpty || advertised.contains(selectedServiceUUIDString.lowercased()) {
        return WhoopGattScanDecision(shouldConnect: true)
    }
    return WhoopGattScanDecision(
        shouldConnect: false,
        unsupportedFamily: WhoopGattServiceFamily.firstUnsupported(in: Array(advertised))
    )
}

public extension DeviceFamily {
    /// Positive registry evidence for unit/source decisions. Returns nil unless the row POSITIVELY
    /// identifies a 5.0/MG WHOOP: the legacy "WHOOP" label predates the wizard and was written
    /// identically for every generation, so it identifies none, and a non-WHOOP brand identifies none
    /// either. Callers that need a concrete family for an unidentified row coalesce this themselves.
    static func confirmedRegistryFamily(model: String?, brand: String?) -> DeviceFamily? {
        if let brand, !brand.isEmpty, brand.caseInsensitiveCompare("WHOOP") != .orderedSame { return nil }
        switch model?.lowercased() {
        case "5.0", "5.0 mg", "whoop 5.0", "whoop 5.0 / mg", "mg", "whoop5": return .whoop5
        default: return nil
        }
    }

    /// Brand-aware family resolution (#1086). Returns `nil` for a positively non-WHOOP brand (e.g. a
    /// legacy "Oura" or "Apple" row left over from an older install) — `DeviceFamily` cannot represent
    /// "not a WHOOP", and letting such a device fall through to `.whoop5` is exactly the #171 mistake
    /// (a family question answered by a fall-through rather than by evidence). The row already carries
    /// the answer in `PairedDevice.brand`.
    ///
    /// A nil/empty brand carries no non-WHOOP signal, so it resolves to the one supported family.
    /// Callers that need a concrete family for a non-WHOOP device coalesce the nil to `.whoop5`,
    /// matching the prior behaviour exactly.
    static func forRegistryDevice(model: String?, brand: String?) -> DeviceFamily? {
        if let brand, !brand.isEmpty, brand.caseInsensitiveCompare("WHOOP") != .orderedSame {
            return nil
        }
        return .whoop5
    }

    /// Is this registry row positively a 5.0/MG-family WHOOP? For callers asking a YES/NO *identity*
    /// question rather than needing a concrete family to compute with.
    ///
    /// The distinction matters because the two kinds of caller must treat `forRegistryDevice`'s `nil`
    /// oppositely, and only one of them may coalesce it: a caller that needs a concrete family for
    /// arithmetic may default to `.whoop5`, while `?? .whoop5` on an IDENTITY question answers **yes**
    /// for a leftover non-WHOOP row — the #171 fall-through wearing #1086's clothes, where the brand
    /// said "not a WHOOP" and the coalesce threw that evidence away.
    ///
    /// Exists so the second kind cannot be written as `forRegistryDevice(…) ?? .whoop5 == .whoop5`,
    /// which reads plausible and is wrong.
    static func isWhoop5Registry(model: String?, brand: String?) -> Bool {
        forRegistryDevice(model: model, brand: brand) == .whoop5
    }

    /// Primary GATT service UUID *string* for this family (lowercase, as advertised).
    /// The app layer wraps this in `CBUUID(string:)`.
    var serviceUUIDString: String { "fd4b0001-cce1-4033-93ce-002d5875f58a" }

    /// Characteristic UUID *strings* this family uses, in stable ascending order.
    /// Plain strings (no CBUUID) on purpose.
    var characteristicUUIDStrings: [String] {
        [
            "fd4b0002-cce1-4033-93ce-002d5875f58a",
            "fd4b0003-cce1-4033-93ce-002d5875f58a",
            "fd4b0004-cce1-4033-93ce-002d5875f58a",
            "fd4b0005-cce1-4033-93ce-002d5875f58a",
            "fd4b0007-cce1-4033-93ce-002d5875f58a",
        ]
    }

    /// The command/write characteristic UUID *string* (the …0002 endpoint that CLIENT_HELLO and
    /// command frames are written to).
    var commandCharacteristicUUIDString: String { "fd4b0002-cce1-4033-93ce-002d5875f58a" }

    /// Static CLIENT_HELLO frame written immediately after GATT discovery to start a session.
    ///
    /// A fully-formed type-35 (COMMAND) frame with CRC16-Modbus header and CRC32 payload trailer.
    /// Transcribed verbatim from the Goose reverse-engineering
    /// (`GooseHello.clientHelloFrameHex` = "aa0108000001e67123019101363e5c8d").
    var clientHello: [UInt8]? { DeviceFamily.whoop5ClientHello }

    /// Whoop 5.0 CLIENT_HELLO bytes (16 bytes). Exposed as a named constant for test/debug use.
    static let whoop5ClientHello: [UInt8] = [
        0xAA, 0x01, 0x08, 0x00, 0x00, 0x01, 0xE6, 0x71,
        0x23, 0x01, 0x91, 0x01, 0x36, 0x3E, 0x5C, 0x8D,
    ]
}

// MARK: - Puffin packet type names

/// Whoop 5.0 introduces "puffin" packet types that mirror existing 4.0 types but on the new
/// transport. These map onto the canonical base type names so they decode like their 4.0
/// counterparts instead of falling through to an "unknown"/"typeN" label.
public enum PuffinPacketType {
    /// Puffin command response — behaves like COMMAND_RESPONSE (type 36).
    public static let puffinCommandResponse: Int = 38
    /// Puffin metadata — behaves like METADATA (type 49).
    public static let puffinMetadata: Int = 56
}

/// Canonical type name for a packet type byte, aliasing the Whoop 5.0 "puffin" types onto the
/// base names they share decoding semantics with:
/// - 38 (PUFFIN_COMMAND_RESPONSE) → "COMMAND_RESPONSE"
/// - 56 (PUFFIN_METADATA)         → "METADATA"
///
/// For every other type this defers to the schema's own `typeName`, so existing behaviour is
/// unchanged. This guarantees the puffin types never decode as "unknown" even if the schema's
/// PacketType enum lacks them.
public func canonicalTypeName(_ t: Int, schema: Schema) -> String {
    switch t {
    case PuffinPacketType.puffinCommandResponse: return "COMMAND_RESPONSE"
    case PuffinPacketType.puffinMetadata: return "METADATA"
    default: return schema.typeName(t)
    }
}
