import Foundation
import WhoopProtocol

/// Curated, SAFE WHOOP command set for *sending* to the strap.
///
/// Raw values are the on-wire command codes (from whoomp/scripts/packet.py `CommandNumber`).
/// This is intentionally a *subset*: DESTRUCTIVE commands that wipe data or brick the strap
/// (firmware load/DFU, force-trim, ship-mode, fuel-gauge reset) stay deliberately EXCLUDED so the
/// in-app command sender can never form those bytes.
///
/// TWO restart opcodes are included, both non-destructive (a restart keeps the strap's stored data)
/// and both user-initiated + confirmation-gated, never sent automatically:
///   - `rebootStrap` (29): the normal Restart. NOOP already triggers a reboot today via
///     `setAdvertisingNameHarvard`. See `BLEManager.rebootStrap()`.
///   - `powerCycleStrap` (32): a harder restart, kept as a protocol fact from the WHOOP 4.0
///     reboot probe (Test Centre → Connection, 4.0 only). The 4.0 ignores opcode 29/empty (#235) and
///     the correct frame is unknown, so the probe tries this alongside 29-with-payload on real 4.0
///     reboot investigation. Nothing sends it.
/// See the "Destructive commands" note in docs/PROTOCOL.md.
public enum WhoopCommand: UInt8, CaseIterable {
    case toggleRealtimeHR      = 3
    case reportVersionInfo     = 7
    case setClock              = 10
    case getClock              = 11
    /// ABORT_HISTORICAL_TRANSMITS (20) — ask the strap to stop streaming the offload it is part-way
    /// through. NON-DESTRUCTIVE, and specifically not a trim: the strap only frees banked records when
    /// NOOP acks a HISTORY_END, so anything unacked when the abort lands stays in flash and re-offloads
    /// on the next sync. Nothing is deleted and no cursor moves.
    ///
    /// The counterpart to `sendHistoricalData` (22), which NOOP has always had with no way to stop it:
    /// until now a drain ran to completion, the 15-minute timeout, or a dropped link.
    ///
    /// `BLEManager.abortBackfill()` tears the session down LOCALLY whether or not the strap honours the
    /// opcode, so a firmware that ignores 20 degrades to exactly today's behaviour rather than leaving
    /// the UI stuck. Confirmed in use on WHOOP 4.0 by OpenStrap Edge (`Cmd.abortHistoricalTransmits`);
    /// the 5/MG form is the same opcode over puffin framing and is NOT hardware-confirmed here.
    case abortHistoricalTransmits = 20
    case sendHistoricalData    = 22
    case historicalDataResult  = 23
    case getBatteryLevel       = 26
    /// REBOOT_STRAP (29) — restart the strap. Payload is an **empty body** (the official app's builder
    /// `rh0.C45476d0` passes a null payload). The strap drops the BLE link and re-advertises after boot;
    /// **stored data is kept** (non-destructive), but any in-flight offload is interrupted (chunk-acked,
    /// so nothing is lost — it re-offloads on reconnect). The 5/MG puffin form is
    /// **hardware-confirmed** (fw 50.40.1.0, #227). `BLEManager.rebootStrap()` logs the
    /// strap's COMMAND_RESPONSE + a no-disconnect watchdog so a strap log shows which case it hit.
    /// User-initiated + confirmation-gated only; never sent automatically. Driven only by `BLEManager.rebootStrap()`.
    case rebootStrap           = 29
    /// POWER_CYCLE_STRAP (32) — a harder restart than REBOOT_STRAP (a full power cycle of the strap
    /// SoC vs a warm reboot). Non-destructive: stored data lives in flash and survives, the strap
    /// re-advertises after boot. Kept as a protocol fact from the WHOOP 4.0 reboot investigation
    /// (#235: a real 4.0 silently ignores opcode 29/empty, and the correct 4.0 reboot frame is unknown).
    /// NOT hardware-confirmed on any family, and nothing in NOOP sends it,
    /// itself gated behind Test Centre → Connection + a confirmation. Never sent automatically.
    case powerCycleStrap       = 32
    case getDataRange          = 34
    case getHelloHarvard       = 35
    /// WHOOP 5.0/MG hello (the puffin generation's GET_HELLO). The response carries the device name
    /// and the firmware version (`fw_version` a.b.c.d), which we surface on the Devices card. A WHOOP
    /// 4.0 answers "unsupported" and ignores it, so this is only sent to a 5/MG strap. Read-only.
    case getHello              = 145
    case getAdvertisingNameHarvard = 76
    /// SET_ADVERTISING_NAME_HARVARD (77) — renamed the strap's BLE advertising name on a WHOOP 4.0
    /// (Harvard). Kept as a protocol fact: NOOP no longer sends it, since a 5/MG uses puffin
    /// framing and a different device-config path. Reversible (rename again any time). Driven only by
    /// `BLEManager.renameStrap(_:)`.
    case setAdvertisingNameHarvard = 77
    case startRawData          = 81
    case stopRawData           = 82
    /// UNCONFIRMED number (#592): no build in this repo's history has ever SENT 96 (`git log -S` finds no
    /// send site), so the value rests on whoomp's table alone — an independent APK decompile reads this
    /// family 11 lower (85/86/87). Two mechanisms could explain that shift without whoomp being wrong: the
    /// EVENT space has HIGH_FREQ_SYNC_PROMPT/ENABLED/DISABLED at exactly 96/97/98 (a decompile reading a
    /// neighbouring table lands −11), or enum ordinals vs wire values (ordinal drift grows with value,
    /// matching the reporter's low anchor 29 agreeing while 96 reads −11). Unresolved — see #592.
    case enterHighFreqSync     = 96
    /// Leave high-frequency-sync mode. Sent defensively on connect to release a strap left parked in
    /// high-freq by a PREVIOUS app (not this codebase — see 96's note; straps found parked in the field
    /// were a real failure mode per the sync-hardening notes). Payload [0x00]. Safe/reversible. Sent on
    /// every connect; note the release EFFECT on a genuinely-parked strap is not separately documented, so
    /// this exercises the opcode without fully confirming its semantics (#592).
    case exitHighFreqSync      = 97
    /// PARTIAL hardware support (#592): sent to a real WHOOP 5 (fw 50.38.1.0) and ANSWERED — but with a
    /// short stub (see Interpreter.decodeWhoop5CommandResponse's note), which could be either
    /// valid-but-minimal (REPORT_VERSION_INFO, definitely valid, also stubs on that firmware) or a generic
    /// unknown-command ack. Not yet probed on a 4.0, where EXTENDED_BATTERY_INFORMATION events carry real
    /// payloads. If probing (#592): send THIS curated number first and capture the response — do NOT lead
    /// with the decompile's 87, an opcode unknown to this table (the curated-safe-subset rule).
    case getExtendedBatteryInfo = 98
    /// The 5/MG battery pack's fuel gauge, read THROUGH the strap — the pack talks to the strap over its
    /// own link, so there is no peripheral to connect to and nothing to scan for. `BatteryPackInfo` has
    /// decoded this reply since the offsets were captured; until now nothing sent the command, so the
    /// decoder had no caller. A 4.0 never answers it (its pack is voltage-only via 98).
    case getBatteryPackInfo = 151
    /// #690: read-only body-location/status probe. Documented in the WHOOP protocol; driven only by the
    /// user-triggered, Test-Centre-gated probeBodyLocationAndStatus(). Decoded to a diagnostic report only.
    case getBodyLocationAndStatus = 84
    // ---- keep both: fork main's feature-flag enumeration probe AND the MG ECG family ----
    /// START_FF_KEY_EXCHANGE (117 / 0x75) — ask the strap how many feature flags its firmware knows.
    /// READ-ONLY: the reply carries a count, and nothing on the strap changes. Payload `[0x01]` (the
    /// inner b3 byte the SET_CONFIG family and GET_HELLO use). This is the READ half of the flag surface
    /// NOOP has only ever written (`setConfig`/120): the protocol's own `CommandNumber` table names
    /// 117/118 alongside 119/120, and only the SET pair was implemented. Driven ONLY by
    /// `BLEManager.probeFeatureFlags()` — user-initiated, Test Centre → Connection gated. Parsing lives in
    /// `FeatureFlagProbe` (pure, unit-tested). (#761, and #103 which it exists to answer.)
    case startFeatureFlagKeyExchange = 117
    /// SEND_NEXT_FF (118 / 0x76) — advance the strap's own key cursor and report one flag NAME.
    /// READ-ONLY: names only, no values, nothing written. Payload `[0x01]`; the body is a CURSOR, not an
    /// index, so the same frame is repeated to walk the list. Bounded by `FeatureFlagProbe.maxFlags` and
    /// by the strap's own end marker. Driven ONLY by `BLEManager.probeFeatureFlags()`. (#761)
    case sendNextFeatureFlag = 118

    // MARK: WHOOP MG ECG ("Labrador") family — experimental, MG-only, opt-in
    //
    // All four numbers are already in this repo's protocol table (`CommandNumber` in
    // whoop_protocol.json) from the upstream whoomp/goose work. They are SAFE and REVERSIBLE: three are
    // data-stream toggles, and the fourth writes one persistent wrist-selection value that is re-writable
    // at any time. NONE of them wipes data, reflashes, ship-modes, force-trims or otherwise permanently
    // alters the strap, so the curated-safe-subset rule (docs/CONTRIBUTING.md §BLE safety contract) holds.
    //
    // The number→meaning mapping is a WORKING HYPOTHESIS, not confirmed: §6 of docs/PROTOCOL.md lists
    // FIVE ECG/HeartKey names against these four codes, 139 is not contiguous with 123–125, and the
    // table is 4.0-derived while 5/MG is known to remap some opcodes (MAVERICK answers SET_CLOCK at 146,
    // not 10). See PROTOCOL.md §9.1 for the full caveat. That is precisely why these are probe-only and
    // why the probe reports UNSUPPORTED as its own outcome rather than folding it into a "blocked" story.
    //
    // NOT hardware-confirmed on any strap — whether an MG's firmware honours them is exactly what the
    // gated, user-initiated probe discovers. Payload for all four is `Whoop5Ecg.commandPayload(arg:)`
    // = `[revision, arg]`. Driven only by `BLEManager.ecg*`, itself behind the MG-gated Experimental
    // opt-in; never sent automatically, never on a plain 5.0 or a 4.0.

    /// SELECT_WRIST (123 / 0x7B) — tell the strap which wrist it is worn on: `01 01` right, `01 02` left
    /// (`docs/PROTOCOL_ECG.md`; the argument lives in `Whoop5Ecg.WristSelection`). Reversible — send it
    /// again with the other wrist. Persistence across a reconnect is not established, so the guided ECG
    /// capture re-sends the wearer's wrist before every start.
    case selectWrist = 123
    /// TOGGLE_LABRADOR_DATA_GENERATION (124 / 0x7C) — the ECG subsystem's main control
    /// (`01 01` stop, `01 02` start; see `Whoop5Ecg.ControlSignal`). Reversible: stop is the OFF path.
    case toggleLabradorDataGeneration = 124
    /// TOGGLE_LABRADOR_RAW_SAVE (125 / 0x7D) — ask the strap to PERSIST raw ECG records for later
    /// offload. A data-retention toggle; sending 0 turns it back off. It writes no setting that
    /// outlives the session's own opt-in.
    case toggleLabradorRawSave = 125
    /// TOGGLE_LABRADOR_FILTERED (139 / 0x8B) — stream the filtered ECG packets live. Reversible.
    case toggleLabradorFiltered = 139
    /// GET_DEVICE_CONFIG_VALUE (121 / 0x79) — ask for ONE device-config value by key name.
    /// READ-ONLY: nothing on the strap changes. Payload `[0x01]` + the key ASCII NUL-padded to 32 bytes,
    /// the SET side's own name field minus its value byte. This is the read half of the DEVICE-CONFIG
    /// namespace — the one `setDeviceConfig`/119 writes and that the #761 enumerate pair (117/118, feature
    /// flags only) never reached. **May not be implemented in firmware**; establishing that is the point.
    /// Driven ONLY by `BLEManager.probeDeviceConfigValues()` — user-initiated, Test Centre → Connection
    /// gated. Parsing lives in `DeviceConfigReadProbe` (pure, unit-tested). (#103, follow-up to #761.)
    case getDeviceConfigValue = 121
    /// GET_FF_VALUE (128 / 0x80) — ask for ONE feature-flag value by key name.
    /// READ-ONLY, same body shape as 121. The read half of the flag surface NOOP has only ever written
    /// (`setConfig`/120): #761 read the flag NAMES, this reads a named flag's VALUE. **May not be
    /// implemented in firmware.** Driven ONLY by `BLEManager.probeDeviceConfigValues()`. (#103)
    case getFeatureFlagValue = 128
    case toggleIMUMode         = 106
    case enableOpticalData     = 107
    /// SET_CONFIG / SET_FF_VALUE (0x78) — write one persistent device feature-flag. Used by the
    /// WHOOP 5.0/MG "enable R22 packets" sequence that switches on the deep biometric streams the
    /// strap otherwise withholds from third-party apps (documented independently by judes.club and
    /// Asherlc/dofek; see Whoop5Config). Payload = `[0x01] + Whoop5Config.payload(name:value:)`
    /// (a 40-byte NUL-padded ASCII flag name + an ASCII '1'/'2' value byte). Reversible — it only
    /// toggles which data the strap emits, and is gated behind an opt-in. iOS/Android only on real
    /// hardware (macOS cannot complete the authenticated bond required to write commands).
    case setConfig             = 120
    /// SET_DEVICE_CONFIG (0x77) — writes ONE persistent device-config value (distinct from the
    /// feature-flag SET_CONFIG/0x78). Used for the "Broadcast HR" flag (`whoop_live_hr_in_adv_ind_pkt`),
    /// which makes the strap advertise its HR as a standard 0x180D BLE sensor. Reversible; gated behind
    /// the broadcast-HR opt-in. iOS/Android only (macOS can't bond a 5/MG). (#181)
    case setDeviceConfig       = 119
    /// Fire a preset haptic pattern. Payload = `[patternId, numLoops, 0, 0, 0]` (5 bytes, from
    /// the device's preset table). patternId indexes the device's preset patterns (GET_ALL_HAPTICS_PATTERN
    /// reports 7 on harvard); the official app fires id=2. Safe/reversible — just buzzes the motor.
    case runHapticsPattern     = 79
    /// Stop an in-progress haptic pattern. Payload `[0x00]`. Safe/reversible.
    case stopHaptics           = 122
    /// The REAL control for the type-43 "R10/R11" realtime-raw stream (payload [0x01]=on / [0x00]=off).
    /// STOP_RAW_DATA(82) does NOT affect it; this one does. Sending [0x00] on connect stops the ~2/s
    /// raw flood that otherwise eats BLE airtime and dominates the strap's flash (blocking dense
    /// biometric retention + disconnected operation). Safe/reversible (just a data stream). Verified
    /// on-device: 2.1/s → 0/s, and it persists across reconnect.
    case sendR10R11Realtime    = 63

    // MARK: Alarm commands (confirmed for interoperability)
    /// Arm the strap's FIRMWARE alarm for a specific UTC time. The strap will buzz at that time
    /// even if the app is backgrounded or killed (event STRAP_DRIVEN_ALARM_EXECUTED=57).
    /// Payload: `setAlarmPayload(epochSec:)` → [0x01] + u32 LE + [0x00, 0x00] + [0x00, 0x00] (9 bytes).
    /// IMPORTANT: always send SET_CLOCK (cmd 10) immediately before this to ensure the strap RTC
    /// is UTC-correct, otherwise the alarm fires at the wrong wall-clock time.
    case setAlarmTime          = 66
    /// Read the currently armed firmware alarm time. Payload [0x01].
    /// The strap replies with the armed epoch on the cmd-notify characteristic.
    case getAlarmTime          = 67
    /// Trigger an app-driven immediate alarm buzz now (event APP_DRIVEN_ALARM_EXECUTED=58).
    /// Payload [0x01]. Use `runHapticsPattern` with patternId=2 for a haptic-only alternative.
    case runAlarm              = 68
    /// Cancel / disarm the currently-armed firmware alarm. Payload [0x01].
    case disableAlarm          = 69

    /// Human-readable label for the command sender UI.
    public var label: String {
        switch self {
        case .toggleRealtimeHR:      return "Toggle Realtime HR"
        case .reportVersionInfo:     return "Report Version Info"
        case .setClock:              return "Set Clock"
        case .getClock:              return "Get Clock"
        case .abortHistoricalTransmits: return "Abort Historical Transmits"
        case .sendHistoricalData:    return "Send Historical Data"
        case .historicalDataResult:  return "Historical Data Result"
        case .getBatteryLevel:       return "Get Battery Level"
        case .rebootStrap:           return "Reboot Strap"
        case .powerCycleStrap:       return "Power Cycle Strap"
        case .getDataRange:          return "Get Data Range"
        case .getHelloHarvard:       return "Get Hello (Harvard)"
        case .getHello:              return "Get Hello (5/MG)"
        case .getAdvertisingNameHarvard: return "Get Advertising Name (Harvard)"
        case .setAdvertisingNameHarvard: return "Set Advertising Name (Harvard)"
        case .startRawData:          return "Start Raw Data"
        case .stopRawData:           return "Stop Raw Data"
        case .enterHighFreqSync:     return "Enter High-Freq Sync"
        case .exitHighFreqSync:      return "Exit High-Freq Sync"
        case .getExtendedBatteryInfo:return "Get Extended Battery Info"
        case .getBatteryPackInfo:    return "Get Battery Pack Info"
        case .getBodyLocationAndStatus:return "Get Body Location And Status"
        case .startFeatureFlagKeyExchange: return "Start Feature-Flag Key Exchange"
        case .sendNextFeatureFlag:   return "Send Next Feature Flag"
        case .selectWrist:           return "Select Wrist (MG ECG, persistent)"
        case .toggleLabradorDataGeneration: return "ECG Data Generation (MG)"
        case .toggleLabradorRawSave: return "ECG Raw Save (MG)"
        case .toggleLabradorFiltered:return "ECG Filtered Stream (MG)"
        case .getDeviceConfigValue:  return "Get Device Config Value"
        case .getFeatureFlagValue:   return "Get Feature Flag Value"
        case .toggleIMUMode:         return "Toggle IMU Mode"
        case .enableOpticalData:     return "Enable Optical Data"
        case .setConfig:             return "Set Config (R22 feature flag)"
        case .setDeviceConfig:       return "Set Device Config (broadcast HR)"
        case .runHapticsPattern:     return "Run Haptics Pattern"
        case .stopHaptics:           return "Stop Haptics"
        case .sendR10R11Realtime:    return "R10/R11 Realtime (raw stream)"
        case .setAlarmTime:          return "Set Alarm Time"
        case .getAlarmTime:          return "Get Alarm Time"
        case .runAlarm:              return "Run Alarm"
        case .disableAlarm:          return "Disable Alarm"
        }
    }

    // MARK: Payload builders

    /// SET_ALARM_TIME (66) payload: Rev1 form.
    /// Layout: `[0x01] + <epoch u32 LE> + [0x00, 0x00] + [0x00, 0x00]` = 9 bytes total.
    /// The leading 0x01 is the sub-command / form byte; bytes 5-6 are subseconds (always 0 — this is a
    /// minute-precision alarm); bytes 7-8 are a haptic-mode field. Always send SET_CLOCK (cmd 10) first
    /// so the strap RTC is UTC-correct, otherwise the alarm fires at the wrong wall-clock time.
    ///
    /// The earlier 7-byte form dropped the trailing 2-byte haptic-mode field. On #428 the strap ACKed
    /// that shorter frame and logged "armed" but never buzzed (no STRAP_DRIVEN_ALARM_EXECUTED event).
    /// @ujix's btsnoop capture of the official WHOOP app on a real 4.0 (PR #535) shows the official app
    /// always sends 9 bytes — the two trailing zero bytes are the missing haptic-mode field. The byte
    /// layout is now pinned by SetAlarmPayloadTests against that capture.
    ///
    /// CONFIRMED WORKING on WHOOP 4.0: the capture author tested this 9-byte frame on a real strap and
    /// the alarm buzzes at the specified time (PR #535, 2026-06-20) - wire capture plus on-device
    /// verification. That's one device/firmware, so the UI keeps a "keep a backup alarm" caveat for
    /// anything critical. Do NOT guess additional fields beyond the captured frame.
    public static func setAlarmPayload(epochSec: UInt32) -> [UInt8] {
        [0x01,
         UInt8(epochSec & 0xFF),
         UInt8((epochSec >> 8) & 0xFF),
         UInt8((epochSec >> 16) & 0xFF),
         UInt8((epochSec >> 24) & 0xFF),
         0x00, 0x00, // subseconds (always 0 — minute precision)
         0x00, 0x00] // haptic-mode field (from @ujix's official-app wire capture, #535)
    }

}

