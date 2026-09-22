import Foundation
import WhoopProtocol

/// Build a complete WHOOP 5.0/MG frame around an arbitrary inner record, for app-target tests.
///
/// The envelope `verifyFrame(_:family:.whoop5)` accepts:
///
///     [0xAA][fmt 0x01][declLen u16 LE][header u16][crc16 u16 LE][type][seq][cmd][payload…][crc32 u32 LE]
///
/// Deliberately NOT `puffinCommandFrame`: that one pads the inner record to a 4-byte boundary because the
/// strap's maverick framing does, which is right for a COMMAND we transmit and wrong for a fixture whose
/// payload length is the thing under test. Here the declared length is exactly the bytes given.
///
/// Byte-for-byte the same builder as `W5FrameFactory.w5Frame` in the WhoopProtocol test target; duplicated
/// rather than shared because a package's test target is not visible from the app's.
func w5Frame(_ data: [UInt8], type: UInt8, seq: UInt8 = 0, cmd: UInt8 = 0,
             header: [UInt8] = [0x00, 0x01]) -> [UInt8] {
    let inner: [UInt8] = [type, seq, cmd] + data
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
