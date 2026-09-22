import Foundation

/// The WHOOP 5/MG **R16 raw ECG record** — the type-47 / layout-16 historical record, and the type-43
/// live record that shares its layout (#891).
///
/// This type implements the contract in [`docs/PROTOCOL_ECG.md`](../../../../docs/PROTOCOL_ECG.md)
/// §"R16 raw waveform and lead diagnostics". It exists as its own pure type rather than as loose code
/// inside `decodeWhoop5HistoricalV16` because every claim it makes is checkable without a strap, an app
/// or CoreBluetooth, and because the record is read by two callers (the field-map interpreter and the
/// stream extractor) that must not drift apart.
///
/// ## Why this replaced a "tag class" reading
///
/// An earlier revision read the top two bits of each waveform word as a 4-way **channel selector** and
/// kept only words whose byte matched `0x80` — `tag & 0x80 != 0 && tag & 0x7C == 0`. That reading was
/// wrong, and wrong in the worst available direction: those two bits are not a channel, they are two
/// independent FLAGS that ride every sample of the ONE waveform channel. The guard therefore did not
/// select a channel, it **discarded samples** — and then packed the survivors contiguously, so the
/// record's time axis silently closed up around the holes.
///
/// Measured over the 128-frame v16 corpus the layout was derived from:
///
/// | | |
/// |---|---:|
/// | declared waveform samples | 62,490 |
/// | samples the tag-class guard kept | 35,760 |
/// | **samples discarded** | **26,730 (42.8 %)** |
/// | records that declared samples and stored NONE | **52 of 128** |
///
/// The evidence that settled it, all from that same corpus:
///
/// 1. **Reserved bits 2–5 are clear in 62,000 of 62,000 samples.** The guard folded those bits into its
///    "class" test, so a class reading predicts they vary. They do not.
/// 2. **Flag 7 changes at most once per record** (122 of 124 full records never change it at all), and
///    **both observed transitions land exactly on the contact grid** this file implements — 2 of 2 on
///    grid, 0 off it, from 9 admissible positions out of 499. A per-sample channel selector has no
///    reason to respect a 10-entry grouping boundary; a slower contact stream has no way not to.
/// 3. **The lead-off diagnostic count at @1534 reads 10 or 11**, matching both the 11 fixed I/Q slots
///    and the divisor the grouping rule needs.
///
/// So: one waveform channel, `flag6` per sample, `flag7` resampled up from a slower contact stream.
///
/// ## What is NOT claimed here
///
/// Nothing in this file asserts volts, a sample rate, electrode acceptance, or a clinical reading. The
/// record's capacity is 500 slots and its cadence is one record per second, and **neither of those is a
/// sample frequency** — see the doc's "Front-end application and calibration boundary". `flag6` is
/// carried verbatim and deliberately left uninterpreted: every one of the 1,000 `flag6 = 1` samples in
/// the corpus sits at the amplifier rail, which looks like a saturation marker until the converse is
/// checked — 252 rail samples have `flag6` CLEAR and 976 non-rail samples have it SET. There is no
/// correspondence, so this type preserves the bit and names nothing.
public enum Whoop5EcgRawRecord {

    // MARK: - Fixed geometry (docs/PROTOCOL_ECG.md §R16)

    /// Total frame length. The R16 record is exactly this long; the regions below never move.
    public static let frameLength = 1584
    /// First waveform slot.
    public static let waveformStart = 34
    /// Waveform slot capacity. A declared count above this is an ANOMALY, never a longer read.
    public static let waveformCapacity = 500
    /// Bytes per waveform slot.
    public static let waveformSlotWidth = 3
    /// The lead-off diagnostic count byte.
    ///
    /// This is a FIXED offset, and that is the whole point of naming it: `waveformStart +
    /// declaredCount * waveformSlotWidth` happens to equal it for a full 500-sample record and is WRONG
    /// for every shorter one. A decoder that computes its way here from the count reads the tail of the
    /// waveform region as lead diagnostics on any partial record — of which the corpus has several.
    public static let leadOffCountOffset = 1534
    /// First I-channel halfword. 11 fixed slots.
    public static let leadOffIStart = 1535
    /// First Q-channel halfword. 11 fixed slots.
    public static let leadOffQStart = 1557
    /// I/Q slot capacity. A declared lead-off count above this is an ANOMALY.
    public static let leadOffCapacity = 11
    /// The zero alignment byte between the Q array and the CRC32 trailer. Never a sample.
    public static let alignmentOffset = 1579

    // MARK: - Packed status (bytes 21–33)

    /// The **13-byte packed status region** at @21–33.
    ///
    /// Deliberately NOT `EcgStatusHeader`, which models the older generic 17-byte "Labrador" header of
    /// unpacked booleans. `docs/PROTOCOL_ECG.md` rules that header out for R16/R17 explicitly ("no
    /// fallback to the generic 17-byte Labrador header for these revisions"), and the corpus agrees: the
    /// 17-byte model puts the sample count at @36–37, where the R16 record has already moved on to
    /// waveform slots, and reads @25 as a BOOLEAN where the record actually carries a progress value
    /// that ramps 0, 3, 6, 10 … 100 across a session.
    ///
    /// Every field is kept as its RAW byte. The doc is explicit that the quality codes are "partial
    /// observed outcomes, not an exhaustive enum or a bad/good/excellent scale" and that the classifier
    /// codes have "no established diagnostic interpretation", so this type stores numbers and names
    /// nothing. Interpretation, if it ever arrives, belongs above this layer.
    public struct Status: Equatable, Sendable {
        /// @21 — quality code. Observed 0–3; thresholds and vocabulary unresolved.
        public let quality: UInt8
        /// @22 — state-transition / presence bits. See the doc's bit table; not decoded here, because a
        /// bit-by-bit reading would name clinical states the doc says these are not.
        public let stateBits: UInt8
        /// @23 — classifier result code. No established diagnostic interpretation.
        public let classifierResult: UInt8
        /// @24 — classifier state code.
        public let classifierState: UInt8
        /// @25 — progress value, percentage-like. Observed ramping 0 → 100 across a session, and 255
        /// where no session is running. The complete range and termination contract are unresolved, so
        /// this stays a raw byte rather than becoming a `Double` fraction.
        public let progress: UInt8
        /// @26 — four independent booleans packed into bits 0–3; individual names unresolved. Zero in
        /// every record of the corpus.
        public let packedBooleans: UInt8
        /// @27 — HR-related classifier value; average/current distinction unresolved.
        ///
        /// **Nothing displays this.** It reads 73 on exactly the records where `progress` reaches 100,
        /// which is precisely the shape that invites a BPM readout — and `ECG_FEATURE_NOTES.md` §5
        /// records that beat-to-beat accuracy against the strap's own optical HR was never established
        /// (r ≈ 0.43 at best). It is preserved because discarding a wire field is irreversible, not
        /// because it is ready to mean anything.
        public let hrRelated: UInt8
        /// @28 — additional HR-related value for R17; a **zero placeholder on R16**. Confirmed zero in
        /// 128 of 128 corpus records.
        public let hrRelatedR17: UInt8
        /// @29–30 — HRV-related value, units unresolved. 65535 reads as "unset" in the corpus.
        public let hrvRelated: UInt16
        /// @31 — zero placeholder in this version. **Not a measured stress value**, despite the field
        /// name the older header gave it.
        public let reservedZero: UInt8
        /// @32–33 — declared waveform sample count. The count is separate from the fixed 500-slot
        /// capacity: read exactly this many samples, never the capacity.
        public let declaredSampleCount: UInt16

        public init(quality: UInt8, stateBits: UInt8, classifierResult: UInt8, classifierState: UInt8,
                    progress: UInt8, packedBooleans: UInt8, hrRelated: UInt8, hrRelatedR17: UInt8,
                    hrvRelated: UInt16, reservedZero: UInt8, declaredSampleCount: UInt16) {
            self.quality = quality
            self.stateBits = stateBits
            self.classifierResult = classifierResult
            self.classifierState = classifierState
            self.progress = progress
            self.packedBooleans = packedBooleans
            self.hrRelated = hrRelated
            self.hrRelatedR17 = hrRelatedR17
            self.hrvRelated = hrvRelated
            self.reservedZero = reservedZero
            self.declaredSampleCount = declaredSampleCount
        }

        /// Parse the region from a frame. `nil` when the frame is too short to hold all 13 bytes.
        public static func decode(_ frame: [UInt8]) -> Status? {
            guard frame.count >= 34 else { return nil }
            return Status(quality: frame[21],
                          stateBits: frame[22],
                          classifierResult: frame[23],
                          classifierState: frame[24],
                          progress: frame[25],
                          packedBooleans: frame[26],
                          hrRelated: frame[27],
                          hrRelatedR17: frame[28],
                          hrvRelated: UInt16(frame[29]) | (UInt16(frame[30]) << 8),
                          reservedZero: frame[31],
                          declaredSampleCount: UInt16(frame[32]) | (UInt16(frame[33]) << 8))
        }
    }

    // MARK: - Anomalies

    /// A bound this record violated. Each one is REPORTED rather than silently repaired, because every
    /// member here means the record disagrees with the fixed layout — which is the one circumstance in
    /// which a decoder's other outputs should not be trusted.
    ///
    /// This replaces `ecg_candidate_unexpected_tag_count`, which counted every word whose top bits were
    /// not `0b10` and called the total "unexpected". Under the correct reading those words are ordinary
    /// samples carrying ordinary flags, so the counter reported hundreds of anomalies on records where
    /// nothing anomalous had happened — a diagnostic asserting far more than it observed, which is the
    /// thing `AGENTS.md` forbids outright. The genuine never-yet-observed signal is a reserved bit, and
    /// that is what `reservedBitsSet` counts.
    public enum Anomaly: Equatable, Sendable {
        /// The declared waveform count exceeds the 500-slot capacity. The doc requires such a count be
        /// quarantined, never truncated silently — so the record decodes NO samples.
        case waveformCountOverCapacity(declared: Int)
        /// The declared lead-off count exceeds the 11 I/Q slots. The diagnostics are dropped; the
        /// waveform is unaffected.
        case leadOffCountOverCapacity(declared: Int)
        /// Waveform words carried a non-zero value in reserved bits 2–5. These bits are clear in all
        /// 62,000 corpus samples, so a non-zero here means firmware is using them and this decoder's
        /// sample reconstruction may no longer be complete. Counted, never guessed at.
        case reservedBitsSet(words: Int)
        /// The frame is not the fixed 1,584-byte R16 length. Fixed regions cannot be trusted to be where
        /// they belong, so nothing past the status block is read.
        case unexpectedFrameLength(Int)
    }

    // MARK: - The decoded record

    /// One fully decoded R16 record.
    public struct Decoded: Equatable, Sendable {
        /// @11 — the monotonic lifetime record index, shared with v18/v20/v21/v26.
        ///
        /// This, not `unix`, is the reliable ordering and contiguity key: it advances by exactly one per
        /// record regardless of what the strap's RTC is doing, so a run of consecutive indices is a
        /// continuous recording even across a clock correction.
        public let recordIndex: UInt32
        /// @15 — strap RTC seconds; one record per second.
        public let unix: UInt32
        public let status: Status
        /// The waveform, **every declared sample, in wire order**, sign-extended from 18-bit two's
        /// complement. Range −131,072 … 131,071 by the coding; the observed amplifier rail is narrower
        /// at ±126,976. No scale is applied and none is known.
        public let samples: [Int]
        /// `flag6` for each sample, index-aligned with `samples`. Uninterpreted — see the type doc.
        public let sampleFlags: [Bool]
        /// The slower contact/lead-state stream: `flag7` collapsed back to ONE entry per group.
        ///
        /// Recovered rather than carried per-sample, because per-sample is what it is not. The doc is
        /// explicit that flag 7 "comes from a slower contact/lead-state stream, so its timing must not be
        /// treated as an independently sampled 500-entry contact channel".
        public let contactFlags: [Bool]
        /// @1534 — the declared number of slower entries, as sent. `contactFlags.count` can be smaller
        /// when the record declared fewer samples than the grouping needs.
        public let leadOffCount: Int
        /// @1535+ — I-channel diagnostic halfwords, signed, `leadOffCount` of them. Signed view of an
        /// unresolved physical quantity: never a clinical threshold.
        public let leadOffI: [Int]
        /// @1557+ — Q-channel diagnostic halfwords, signed.
        public let leadOffQ: [Int]
        /// Every bound this record violated. Empty is the normal case.
        public let anomalies: [Anomaly]

        public init(recordIndex: UInt32, unix: UInt32, status: Status, samples: [Int],
                    sampleFlags: [Bool], contactFlags: [Bool], leadOffCount: Int,
                    leadOffI: [Int], leadOffQ: [Int], anomalies: [Anomaly]) {
            self.recordIndex = recordIndex
            self.unix = unix
            self.status = status
            self.samples = samples
            self.sampleFlags = sampleFlags
            self.contactFlags = contactFlags
            self.leadOffCount = leadOffCount
            self.leadOffI = leadOffI
            self.leadOffQ = leadOffQ
            self.anomalies = anomalies
        }
    }

    // MARK: - Sample coding

    /// Reconstruct one waveform slot: the 18-bit two's-complement sample and its two flags.
    ///
    /// ```text
    /// raw18 = ((b0 & 0x03) << 16) | (b1 << 8) | b2      big-endian within the slot
    /// flag6 = (b0 >> 6) & 1
    /// flag7 = (b0 >> 7) & 1
    /// ```
    ///
    /// Reading `raw18` UNSIGNED — as the first revision of this decoder did — puts a ~65,000-count cliff
    /// at every zero crossing (`… 65511, 298, 65162 …`), which is how that reading gave itself away.
    /// Reading it as little-endian i16 clips every sample that needs the wider range, and 315 words in
    /// the corpus need it.
    public static func decodeSlot(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8)
        -> (sample: Int, flag6: Bool, flag7: Bool, reservedBits: UInt8) {
        let raw18 = (Int(b0 & 0x03) << 16) | (Int(b1) << 8) | Int(b2)
        let signed = raw18 >= 0x2_0000 ? raw18 - 0x4_0000 : raw18
        return (signed, (b0 >> 6) & 1 == 1, (b0 >> 7) & 1 == 1, (b0 >> 2) & 0x0F)
    }

    // MARK: - The contact grouping rule

    /// Group sizes that map `sampleCount` waveform samples onto `contactCount` slower contact entries.
    ///
    /// The doc specifies this for the 500-raw / 10-slower case and gives the answer explicitly: the
    /// groups are **51, then eight of 50, then 49** — *not* ten equal groups of 50. The rule that
    /// produces it is a divisor of `sampleCount / contactCount` with the boundary sample staying with the
    /// EARLIER entry before the index advances, which is what makes the first group one long and the last
    /// one short.
    ///
    /// Generalised to other counts only in the arithmetic sense. The doc is clear that "nonzero counts
    /// other than ten are not established as ordinary supported input to this grouping rule", and the
    /// corpus does carry `leadOffCount == 11` records — so a caller gets a correctly-sized grouping for
    /// those and no claim that the strap meant it that way.
    ///
    /// Returns an empty array when either count is non-positive.
    public static func contactGroupSizes(sampleCount: Int, contactCount: Int) -> [Int] {
        guard sampleCount > 0, contactCount > 0 else { return [] }
        let divisor = sampleCount / contactCount
        guard divisor > 0 else { return [] }
        // Boundaries advance the contact index AFTER the sample at each multiple of `divisor`, which is
        // what shifts the whole grid one sample later and leaves the remainder on the last group.
        var sizes: [Int] = []
        var start = 0
        for entry in 0..<contactCount {
            // The first group absorbs the extra boundary sample; the last absorbs whatever remains.
            let end = entry == contactCount - 1 ? sampleCount : min(sampleCount, divisor * (entry + 1) + 1)
            guard end > start else { break }
            sizes.append(end - start)
            start = end
        }
        return sizes
    }

    /// Collapse a per-sample `flag7` array back to one entry per contact group.
    ///
    /// Each group contributes the flag its samples carry. When a group's samples disagree — which the
    /// grouping rule says should not happen, since every sample in a group was stamped from one slower
    /// entry — the group is reported as `true` if ANY sample carries it, and the disagreement is visible
    /// to the caller as a shorter-than-expected agreement rather than being hidden.
    public static func collapseContactFlags(perSample: [Bool], contactCount: Int) -> [Bool] {
        let sizes = contactGroupSizes(sampleCount: perSample.count, contactCount: contactCount)
        guard !sizes.isEmpty else { return [] }
        var out: [Bool] = []
        out.reserveCapacity(sizes.count)
        var i = 0
        for size in sizes {
            let end = min(i + size, perSample.count)
            guard end > i else { break }
            out.append(perSample[i..<end].contains(true))
            i = end
        }
        return out
    }

    // MARK: - Decode

    /// Decode a complete R16 record.
    ///
    /// `frame` is the reassembled frame from its framing byte, so every offset in this file is a frame
    /// offset. Returns `nil` only when the frame is too short to carry the shared header and status —
    /// anything decodable past that point comes back as a `Decoded` with its problems in `anomalies`,
    /// because a record that breaks one bound still has fields worth preserving.
    public static func decode(_ frame: [UInt8]) -> Decoded? {
        guard frame.count >= 34, let status = Status.decode(frame) else { return nil }
        let recordIndex = UInt32(frame[11]) | (UInt32(frame[12]) << 8)
            | (UInt32(frame[13]) << 16) | (UInt32(frame[14]) << 24)
        let unix = UInt32(frame[15]) | (UInt32(frame[16]) << 8)
            | (UInt32(frame[17]) << 16) | (UInt32(frame[18]) << 24)

        var anomalies: [Anomaly] = []
        // The fixed regions are only where the doc says they are in a full-length frame. A short or long
        // frame is reported and its waveform left unread rather than located by arithmetic that the
        // frame's own length has already disproved.
        guard frame.count == frameLength else {
            anomalies.append(.unexpectedFrameLength(frame.count))
            return Decoded(recordIndex: recordIndex, unix: unix, status: status, samples: [],
                           sampleFlags: [], contactFlags: [], leadOffCount: 0,
                           leadOffI: [], leadOffQ: [], anomalies: anomalies)
        }

        // WAVEFORM. Read exactly the declared count, and quarantine a count that overruns the capacity
        // instead of truncating it: the doc requires an over-capacity count be treated as an anomaly, and
        // a silent truncation would hand a caller 500 plausible samples out of a record whose own header
        // it had just contradicted.
        let declared = Int(status.declaredSampleCount)
        var samples: [Int] = []
        var sampleFlags: [Bool] = []
        var contactPerSample: [Bool] = []
        var reservedWords = 0
        if declared > waveformCapacity {
            anomalies.append(.waveformCountOverCapacity(declared: declared))
        } else if declared > 0 {
            samples.reserveCapacity(declared)
            sampleFlags.reserveCapacity(declared)
            contactPerSample.reserveCapacity(declared)
            for i in 0..<declared {
                let o = waveformStart + i * waveformSlotWidth
                let slot = decodeSlot(frame[o], frame[o + 1], frame[o + 2])
                samples.append(slot.sample)
                sampleFlags.append(slot.flag6)
                contactPerSample.append(slot.flag7)
                if slot.reservedBits != 0 { reservedWords += 1 }
            }
        }
        if reservedWords > 0 { anomalies.append(.reservedBitsSet(words: reservedWords)) }

        // LEAD-OFF DIAGNOSTICS, at their fixed offsets. Note this is read even when the waveform was
        // quarantined above: the two regions are independent, and the diagnostics are exactly what a
        // reader wants when the waveform is the part that went wrong.
        let leadOffCount = Int(frame[leadOffCountOffset])
        var leadOffI: [Int] = []
        var leadOffQ: [Int] = []
        if leadOffCount > leadOffCapacity {
            anomalies.append(.leadOffCountOverCapacity(declared: leadOffCount))
        } else if leadOffCount > 0 {
            for k in 0..<leadOffCount {
                leadOffI.append(readSignedHalfword(frame, leadOffIStart + k * 2))
                leadOffQ.append(readSignedHalfword(frame, leadOffQStart + k * 2))
            }
        }

        // Collapse flag 7 onto the slower grid it actually came from. A record whose lead-off count is
        // zero gets no contact stream — the doc notes "a zero slower count omits flag-7 insertion" — so
        // there is nothing to collapse and an empty array is the honest answer, not an array of `false`.
        let contactFlags = leadOffCount > 0 && leadOffCount <= leadOffCapacity
            ? collapseContactFlags(perSample: contactPerSample, contactCount: leadOffCount)
            : []

        return Decoded(recordIndex: recordIndex, unix: unix, status: status, samples: samples,
                       sampleFlags: sampleFlags, contactFlags: contactFlags,
                       leadOffCount: leadOffCount, leadOffI: leadOffI, leadOffQ: leadOffQ,
                       anomalies: anomalies)
    }

    /// The I/Q halfwords are little-endian and carry a signed diagnostic interpretation.
    @inline(__always)
    private static func readSignedHalfword(_ frame: [UInt8], _ off: Int) -> Int {
        let raw = Int(frame[off]) | (Int(frame[off + 1]) << 8)
        return raw >= 0x8000 ? raw - 0x1_0000 : raw
    }
}
