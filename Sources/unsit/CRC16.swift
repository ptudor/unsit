import Foundation

/// CRC-16/ARC (a.k.a. CRC-16/IBM): polynomial 0xA001 (reflected 0x8005),
/// initial value 0, reflected input/output, no final XOR.
///
/// Classic StuffIt uses this checksum both for the per-entry header (over the
/// first 110 bytes of each 112-byte header) and for each decompressed fork
/// (the `rsrcCRC` / `dataCRC` fields). Verified empirically against the header
/// CRCs stored in the sample archives.
enum CRC16 {
    private static let table: [UInt16] = {
        var t = [UInt16](repeating: 0, count: 256)
        for n in 0..<256 {
            var c = UInt16(n)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (c >> 1) ^ 0xA001 : (c >> 1)
            }
            t[n] = c
        }
        return t
    }()

    static func checksum<S: Sequence>(_ bytes: S) -> UInt16 where S.Element == UInt8 {
        var c: UInt16 = 0
        for b in bytes {
            c = (c >> 8) ^ table[Int((c ^ UInt16(b)) & 0xFF)]
        }
        return c
    }
}
