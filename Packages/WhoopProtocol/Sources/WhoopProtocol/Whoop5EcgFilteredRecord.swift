import Foundation

/// The WHOOP 5/MG **R17 filtered ECG record** — layout 17, carried live as type 43 and historically as
/// type 47.
///
/// This type implements the contract in [`docs/PROTOCOL_ECG.md`](../../../../docs/PROTOCOL_ECG.md)
/// §"R17 filtered waveform". It is the live counterpart of `Whoop5EcgRawRecord`: once
/// TOGGLE_LABRADOR_FILTERED (139) is on and generation is started, the strap streams these 240-byte
/// records while the R16 raw record is banked to flash.
///
/// ## Why the older 101-sample reading is not reused
///
/// `Whoop5Ecg.realtimeRawSamples` reads the same 240-byte frame as 101 i16 values from byte 34 to 236.
/// The doc rules that out: bytes 234–235 are two zero alignment bytes, "never a waveform sample", so a
/// 101-value read appends a fake zero to every record — a regular one-per-record artefact at the record
/// period, the exact shape #194 warned manufactures a false rhythm. It also ignores the declared count at
/// @32, so a partial record would be padded with slots the strap never filled.
///
/// ## What is NOT claimed here
///
/// No volts, no sample rate, no clinical reading. The standard configuration emits one filtered value
/// per five processed inputs, which is a count ratio, not a frequency; a display that paces these at a
/// nominal rate is choosing a presentation, not stating a measurement.
public enum Whoop5EcgFilteredRecord {

    // MARK: - Fixed geometry (docs/PROTOCOL_ECG.md §R17)

    /// Total frame length. The R17 record is exactly this long.
    public static let frameLength = 240
    /// Layout selector byte value at @9.
    public static let layout: UInt8 = 17
    /// Live transport packet type.
    public static let livePacketType: UInt8 = 43
    /// Historical transport packet type.
    public static let historicalPacketType: UInt8 = 47
    /// First sample slot.
    public static let waveformStart = 34
    /// Sample slot capacity: 100 two-byte slots at @34–233. A declared count above this is an ANOMALY.
    public static let waveformCapacity = 100
    /// Bytes per sample slot.
    public static let waveformSlotWidth = 2

    /// True for a frame shaped like an R17 record on either transport. Shape only — the caller gates on
    /// the frame checksums first.
    ///
    /// Type 43 alone is not enough: the doc lists live R16 under the same type, and other type-43 shapes
    /// exist, so the layout byte and the exact length both have to agree.
    public static func isFilteredRecord(_ frame: [UInt8]) -> Bool {
        frame.count == frameLength
            && (frame[8] == livePacketType || frame[8] == historicalPacketType)
            && frame[9] == layout
    }

    /// A bound this record violated. Reported rather than repaired.
    public enum Anomaly: Equatable, Sendable {
        /// The declared count exceeds the 100-slot capacity. The doc requires such a count be
        /// quarantined, never truncated — so the record decodes NO samples.
        case waveformCountOverCapacity(declared: Int)
    }

    /// One decoded R17 record.
    public struct Decoded: Equatable, Sendable {
        /// @11 — the shared record sequence. Raw and filtered outputs of one acquisition pass can share
        /// it, so it is never a cross-layout dedup key on its own.
        public let recordIndex: UInt32
        /// @15 — strap RTC seconds.
        public let unix: UInt32
        /// @21–33 — the same packed status region R16 carries, including the R17-only byte @28.
        public let status: Whoop5EcgRawRecord.Status
        /// Every declared sample, in wire order, as signed i16. Counted zeros are kept: the doc is
        /// explicit that a zero sample can be real and is not padding.
        public let samples: [Int]
        public let anomalies: [Anomaly]

        public init(recordIndex: UInt32, unix: UInt32, status: Whoop5EcgRawRecord.Status,
                    samples: [Int], anomalies: [Anomaly]) {
            self.recordIndex = recordIndex
            self.unix = unix
            self.status = status
            self.samples = samples
            self.anomalies = anomalies
        }
    }

    /// Decode a complete R17 record, or `nil` when `frame` is not R17-shaped.
    public static func decode(_ frame: [UInt8]) -> Decoded? {
        guard isFilteredRecord(frame), let status = Whoop5EcgRawRecord.Status.decode(frame) else { return nil }
        let recordIndex = UInt32(frame[11]) | (UInt32(frame[12]) << 8)
            | (UInt32(frame[13]) << 16) | (UInt32(frame[14]) << 24)
        let unix = UInt32(frame[15]) | (UInt32(frame[16]) << 8)
            | (UInt32(frame[17]) << 16) | (UInt32(frame[18]) << 24)
        let declared = Int(status.declaredSampleCount)
        guard declared <= waveformCapacity else {
            return Decoded(recordIndex: recordIndex, unix: unix, status: status, samples: [],
                           anomalies: [.waveformCountOverCapacity(declared: declared)])
        }
        var samples: [Int] = []
        samples.reserveCapacity(declared)
        for i in 0..<declared {
            let o = waveformStart + i * waveformSlotWidth
            let raw = Int(frame[o]) | (Int(frame[o + 1]) << 8)
            samples.append(raw >= 0x8000 ? raw - 0x1_0000 : raw)
        }
        return Decoded(recordIndex: recordIndex, unix: unix, status: status, samples: samples, anomalies: [])
    }
}
