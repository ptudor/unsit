import Foundation

/// Least-significant-bit-first bit reader over a byte buffer.
///
/// Mirrors the semantics of XADMaster's `CSInput*LE` functions used by the
/// StuffIt method-13 stream: bytes are consumed low address first, and within
/// a byte the low bit is consumed first. For a multi-bit read the first bit
/// consumed becomes the least-significant bit of the returned value.
struct BitReaderLE {
    private let data: [UInt8]
    private var bytePos: Int
    private var bitBuffer: UInt64 = 0
    private var bitCount: Int = 0

    /// - Parameter startOffset: index of the first byte fed to the bit buffer.
    ///   The method-13 selector byte is read separately (see `StuffIt13`) so
    ///   decoding begins one byte into the fork.
    init(_ data: [UInt8], startOffset: Int) {
        self.data = data
        self.bytePos = startOffset
    }

    private mutating func fill(_ needed: Int) {
        while bitCount < needed {
            let b: UInt64 = bytePos < data.count ? UInt64(data[bytePos]) : 0
            bytePos += 1
            bitBuffer |= b << UInt64(bitCount)
            bitCount += 8
        }
    }

    /// Read a single bit (0 or 1), earliest bit first.
    mutating func bit() -> Int {
        fill(1)
        let r = Int(bitBuffer & 1)
        bitBuffer >>= 1
        bitCount -= 1
        return r
    }

    /// Read `n` bits; the first bit read is the LSB of the result.
    mutating func bits(_ n: Int) -> Int {
        if n == 0 { return 0 }
        fill(n)
        let mask: UInt64 = (UInt64(1) << UInt64(n)) - 1
        let r = Int(bitBuffer & mask)
        bitBuffer >>= UInt64(n)
        bitCount -= n
        return r
    }
}
