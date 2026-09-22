import Foundation


// Standard zlib CRC-32 (reflected, poly 0xEDB88320), table built in code.
private let crc32Table: [UInt32] = {
    var table = [UInt32](repeating: 0, count: 256)
    for i in 0..<256 {
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
        }
        table[i] = c
    }
    return table
}()

/// Standard zlib CRC-32 over `bytes[from..<(to ?? count)]`. The optional range defaults to the whole
/// array (existing callers unchanged); the validator passes a range to checksum the inner record or
/// payload in place, skipping the per-frame sub-array copy that added up over a multi-night offload.
public func crc32(_ bytes: [UInt8], _ from: Int = 0, _ to: Int? = nil) -> UInt32 {
    let upper = to ?? bytes.count
    var crc: UInt32 = 0xFFFFFFFF
    var i = from
    while i < upper {
        crc = crc32Table[Int((crc ^ UInt32(bytes[i])) & 0xFF)] ^ (crc >> 8)
        i += 1
    }
    return crc ^ 0xFFFFFFFF
}

/// CRC16-Modbus (poly 0xA001, init 0xFFFF, reflected) over `bytes[from..<(to ?? count)]`. Used for the
/// Whoop 5.0 frame header check. The optional range defaults to the whole array; the validator passes
/// a range so the 6-byte header check needs no `Array(frame[0..<6])` copy.
public func crc16Modbus(_ bytes: [UInt8], _ from: Int = 0, _ to: Int? = nil) -> UInt16 {
    let upper = to ?? bytes.count
    var crc: UInt16 = 0xFFFF
    var i = from
    while i < upper {
        crc ^= UInt16(bytes[i])
        for _ in 0..<8 {
            if crc & 1 == 1 {
                crc = (crc >> 1) ^ 0xA001
            } else {
                crc >>= 1
            }
        }
        i += 1
    }
    return crc
}

/// Why a frame failed the envelope check — one value, never optional, so a consumer can report the
/// cause without verifying or parsing the frame a second time (the parse-once invariant).
///
/// `none` is the ONLY value that accompanies a positive verdict. Structural failures are decided
/// before the payload CRC is required, so every frame that reaches the payload-integrity decision
/// has a computable CRC32 by construction.
public enum FrameRejectReason: String, Codable, Equatable, Sendable, CaseIterable {
    /// The frame is intact: header checksum, payload CRC32 and the structural length all agree.
    case none
    /// No 0xAA start-of-frame byte — this byte run is not a frame at all.
    case noStartOfFrame
    /// Fewer bytes than the device family's smallest well-formed frame can have.
    case belowMinimumLength
    /// The byte count does not equal the total derived from the declared length field: the frame is
    /// truncated, or it carries trailing bytes past its own end.
    case lengthMismatch
    /// The CRC-16-Modbus header checksum disagreed.
    case headerChecksumMismatch
    /// The payload CRC32 was computed and disagreed.
    case payloadCRCMismatch
}

/// The lower bound a frame must clear before any of its bytes are read as fields.
///
/// WHOOP 5.0/MG: `[SOF][fmt][declLen u16][hdr u16][crc16 u16] + >=1 payload byte + [crc32 u32]` = 13.
/// 13 is an empirical acceptance policy, not an envelope necessity: Goose's `v5Payload` accepts a
/// 12-byte, zero-payload frame (`declaredLength == 4`). NOOP deliberately requires the inner type
/// byte. Real fixtures include 20-byte command responses plus 24- and 32-byte frames, but no captured
/// 12-byte zero-payload frame; those observations do not prove the boundary. Keep this assumption
/// explicit until hardware evidence changes it.
public enum FrameLimits {
    public static let whoop5MinimumFrameBytes = 13

    /// The minimum total frame size for `family`, in bytes.
    public static func minimumFrameBytes(for family: DeviceFamily) -> Int {
        switch family {
        case .whoop5: return whoop5MinimumFrameBytes
        }
    }
}

public struct FrameCheck: Equatable {
    /// The FULL verdict: start-of-frame, minimum length, exact length, header checksum and payload
    /// CRC32 together. True only when `reason == .none`.
    public let ok: Bool
    public let length: Int?
    /// The HEADER checksum outcome (CRC-16-Modbus over the first six bytes). Named `crc8OK` for
    /// source compatibility with every existing reader of this struct.
    public let crc8OK: Bool?
    public let crc32OK: Bool?
    /// Why `ok` is false; `.none` exactly when `ok` is true.
    public let reason: FrameRejectReason
    public init(ok: Bool, length: Int? = nil, crc8OK: Bool? = nil, crc32OK: Bool? = nil,
                reason: FrameRejectReason = .none) {
        self.ok = ok
        self.length = length
        self.crc8OK = crc8OK
        self.crc32OK = crc32OK
        self.reason = reason
    }
}

/// Turn the two checksum outcomes into ONE integrity reason after the caller has already established
/// the structural bounds. Taking a non-optional payload result makes the evaluation order explicit:
/// an uncomputable CRC is represented by the earlier structural reason, not a dead checksum case.
@inline(__always)
private func integrityRejectReason(headerCRCOK: Bool, payloadCRCOK: Bool) -> FrameRejectReason {
    if !headerCRCOK { return .headerChecksumMismatch }
    return payloadCRCOK ? .none : .payloadCRCMismatch
}

@inline(__always)
private func u16le(_ bytes: [UInt8], _ off: Int) -> Int {
    Int(bytes[off]) | (Int(bytes[off + 1]) << 8)
}

@inline(__always)
private func u32le(_ bytes: [UInt8], _ off: Int) -> UInt32 {
    UInt32(bytes[off]) | (UInt32(bytes[off + 1]) << 8)
        | (UInt32(bytes[off + 2]) << 16) | (UInt32(bytes[off + 3]) << 24)
}

/// Family-aware frame validation. The Whoop 5.0 envelope, reverse-engineered from Goose:
///
///   [0]   SOF 0xAA
///   [1]   format byte (0x01)
///   [2-3] declaredLength u16 LE  (= payload length + 4)
///   [4-5] header bytes
///   [6-7] CRC16-Modbus over frame[0..<6], u16 LE
///   [8..] payload (length = declaredLength - 4)
///   tail  CRC32 (zlib, LE) over the payload, 4 bytes
///   total = declaredLength + 8
///
/// The `crc8OK` field of the result carries the CRC16 header outcome, so callers keep a single
/// uniform "header CRC ok?" signal.
public func verifyFrame(_ frame: [UInt8], family: DeviceFamily) -> FrameCheck {
    switch family {
    case .whoop5:
        return verifyFrameWhoop5(frame)
    }
}

private func verifyFrameWhoop5(_ frame: [UInt8]) -> FrameCheck {
    guard frame.first == 0xAA else {
        return FrameCheck(ok: false, reason: .noStartOfFrame)
    }
    // NOOP's empirical 5/MG floor: envelope + at least the inner type byte + CRC32. The Goose
    // reference parser permits a 12-byte empty payload, but no such hardware frame is known here.
    guard frame.count >= FrameLimits.whoop5MinimumFrameBytes else {
        return FrameCheck(ok: false, reason: .belowMinimumLength)
    }
    // declaredLength counts payload + the 4-byte CRC32 trailer (mirrors Goose v5Frames/v5Payload).
    let declaredLength = u16le(frame, 2)
    let total = declaredLength + 8

    // Header CRC16-Modbus over the first 6 bytes, stored LE at frame[6..8]. Ranged, no copy.
    let wantHeaderCRC = crc16Modbus(frame, 0, 6)
    let gotHeaderCRC = UInt16(frame[6]) | (UInt16(frame[7]) << 8)
    let headerCRCOK = wantHeaderCRC == gotHeaderCRC

    if total < FrameLimits.whoop5MinimumFrameBytes {
        let diagnosticCRC32OK: Bool? = declaredLength >= 4 && total <= frame.count
            ? crc32(frame, 8, total - 4) == u32le(frame, total - 4)
            : nil
        return FrameCheck(ok: false, length: declaredLength, crc8OK: headerCRCOK,
                          crc32OK: diagnosticCRC32OK, reason: .belowMinimumLength)
    }
    if total != frame.count {
        // Preserve a CRC result for a surplus tail; truncation leaves it unavailable.
        let diagnosticCRC32OK: Bool? = total <= frame.count
            ? crc32(frame, 8, total - 4) == u32le(frame, total - 4)
            : nil
        return FrameCheck(ok: false, length: declaredLength, crc8OK: headerCRCOK,
                          crc32OK: diagnosticCRC32OK, reason: .lengthMismatch)
    }
    // Exact size plus the configured 13-byte floor proves at least one byte before the CRC trailer.
    let payloadEnd = total - 4
    let crc32OK = crc32(frame, 8, payloadEnd) == u32le(frame, payloadEnd)
    let reason = integrityRejectReason(headerCRCOK: headerCRCOK, payloadCRCOK: crc32OK)
    // Report the header outcome through crc8OK so callers have a single header-CRC signal.
    return FrameCheck(ok: reason == .none, length: declaredLength, crc8OK: headerCRCOK,
                      crc32OK: crc32OK, reason: reason)
}

/// EXPERIMENTAL: build a WHOOP 5.0/MG ("puffin") command frame in the CRC16 envelope (docs/PROTOCOL.md
/// §2.2). The inner record is `[type][seq][cmd] + payload`; `declLen = innerLen + 4` (the CRC32 tail);
/// the CRC16-Modbus covers the first six header bytes. `type` defaults to 35 (COMMAND) and `header`
/// to `[0x00, 0x01]`, mirroring the structure of the only puffin frame we know a real strap accepts
/// (the static CLIENT_HELLO). The returned frame round-trips through `verifyFrame(_:family:.whoop5)`.
/// Whether a 5/MG strap *acts* on a given command is exactly what experimentation discovers, so the
/// app gates any sending behind an opt-in switch and only writes to the puffin command characteristic.
public func puffinCommandFrame(cmd: UInt8, seq: UInt8, payload: [UInt8] = [0x00],
                               type: UInt8 = 35, header: [UInt8] = [0x00, 0x01]) -> [UInt8] {
    // Pad the inner record to a 4-byte boundary before length/CRC, exactly as the strap's maverick
    // framing does (pad4). No-op for the 4-aligned commands shipped so far (toggle HR, historical),
    // but REQUIRED for the 12-byte haptics payload (inner 15 → 16) — otherwise the declared length and
    // CRC32 cover the wrong byte count and the strap rejects the frame (#48).
    var inner: [UInt8] = [type, seq, cmd] + payload
    let pad = (4 - inner.count % 4) % 4
    if pad > 0 { inner += [UInt8](repeating: 0, count: pad) }
    let declLen = inner.count + 4
    var frame: [UInt8] = [0xAA, 0x01,
                          UInt8(declLen & 0xFF), UInt8((declLen >> 8) & 0xFF),
                          header[0], header[1]]
    let c16 = crc16Modbus(Array(frame[0..<6]))
    frame.append(UInt8(c16 & 0xFF)); frame.append(UInt8((c16 >> 8) & 0xFF))
    frame.append(contentsOf: inner)
    let c32 = crc32(inner)
    frame.append(UInt8(c32 & 0xFF)); frame.append(UInt8((c32 >> 8) & 0xFF))
    frame.append(UInt8((c32 >> 16) & 0xFF)); frame.append(UInt8((c32 >> 24) & 0xFF))
    return frame
}

/// Accumulate BLE notification fragments into complete frames.
/// A complete frame is `declLength + 8` bytes where declLength = u16 LE at buf[2..4], and never
/// smaller than the family minimum in `FrameLimits` — a start-of-frame declaring less is dropped and
/// the stream resyncs on the next one.
public final class Reassembler {
    // Backed by a flat byte buffer plus a read cursor rather than draining off the front. The earlier
    // form called buf.removeFirst(n), which shifts the whole tail down on every completed frame, so
    // draining one frame was O(n) and the historical offload (thousands of ~1.9 KB records over a
    // multi-night sync) paid it repeatedly. Here fragments append into [buf], [head] advances past
    // consumed bytes, and the leftover tail is compacted to the front once per feed(). Output frames are
    // byte-identical and in the same order. This mirrors the Android Reassembler window.
    private var buf: [UInt8] = []
    private var head = 0   // index of the first byte not yet consumed
    private let family: DeviceFamily

    /// ~4× the largest real WHOOP frame (~1920 B raw/historical). A declared total beyond this is a
    /// corrupt or misaligned length (a bit-flip, or a spurious 0xAA injected mid-frame), not a real
    /// frame — so drop that SOF and resync rather than wait forever for bytes that can't arrive.
    /// Mirrors the Android `Framing.kt` cap. (Reimplemented from @vulnix0x4's PR #374.)
    static let maxFrameBytes = 8192

    /// How many start-of-frame bytes were dropped because the total length they declared was below
    /// the family minimum. Such a byte run never reaches a parser, so without this counter it would
    /// vanish without trace — and one of the readers downstream exists to preserve exactly the
    /// frames nothing else can read. Monotonic for the lifetime of the reassembler.
    public private(set) var belowMinimumLengthDrops = 0

    /// WHOOP 5.0 ("puffin") reads a u16 declared length at `buf[2..4]` (after the `0xAA` SOF and the
    /// `0x01` format byte), total = `declLength + 8` — the extra 4 covers the format byte and the
    /// CRC16 header that 5.0 inserts ahead of the inner record.
    public init(family: DeviceFamily = .whoop5) {
        self.family = family
    }

    public func feed(_ fragment: [UInt8]) -> [[UInt8]] {
        buf.append(contentsOf: fragment)
        var out: [[UInt8]] = []
        while true {
            guard let sof = indexOfSOF() else {
                // No SOF left in the window: nothing here is salvageable, so drop it all.
                buf.removeAll(keepingCapacity: true)
                head = 0
                break
            }
            // Skip any leading bytes ahead of the SOF instead of physically removing them.
            if sof > head { head = sof }
            let avail = buf.count - head
            // At least 4 bytes are needed to read the declared length.
            if avail < 4 {
                break
            }
            let total: Int
            switch family {
            case .whoop5:
                total = (Int(buf[head + 2]) | (Int(buf[head + 3]) << 8)) + 8
            }
            if total < FrameLimits.minimumFrameBytes(for: family) {
                // A declared total below the configured family floor is not accepted: emitting it
                // would hand the parser a byte run whose "inner fields" are its own checksum trailer.
                // Drop this 0xAA, count it, and resync — same shape as the ceiling below.
                belowMinimumLengthDrops += 1
                head += 1
                continue
            }
            if total > Reassembler.maxFrameBytes {
                // Impossibly large declared length → this 0xAA is garbage. Drop it and resync to the
                // next SOF instead of stalling the live stream until a reconnect.
                head += 1
                continue
            }
            if avail < total {
                break
            }
            out.append(Array(buf[head..<(head + total)]))
            head += total
        }
        compact()
        return out
    }

    /// Index of the first 0xAA at or after `head` in the live window, or nil if none remain.
    private func indexOfSOF() -> Int? {
        var i = head
        while i < buf.count {
            if buf[i] == 0xAA { return i }
            i += 1
        }
        return nil
    }

    /// Slide the unconsumed tail back to offset 0 so `head` can't drift forever and the buffer stays
    /// small. compact() runs at the end of every feed(), so `head` is always 0 when the next append
    /// lands. The leftover is at most one in-progress frame (< maxFrameBytes), so the move is bounded.
    private func compact() {
        if head == 0 { return }
        if head >= buf.count {
            buf.removeAll(keepingCapacity: true)
        } else {
            buf.removeFirst(head)
        }
        head = 0
    }
}
