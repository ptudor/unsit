import Foundation

enum PrefixCodeError: Error {
    case invalidBitstream
    case malformedTable
}

/// A binary prefix (Huffman) code decoded bit-at-a-time.
///
/// Codes are described by a "high-bit-first" integer value and a bit length:
/// the path from the root follows the value's bits from the most-significant
/// (bit `length-1`) down to bit 0. Bits are pulled from the stream LSB-first
/// (see `BitReaderLE`), so the first bit consumed corresponds to the most
/// significant bit of the code value — matching XADMaster's `...CodeLE` path.
final class PrefixCode {
    // Node arrays: child[node][bit]; -1 means "no branch". A node is a leaf
    // iff `symbol[node] >= 0`, in which case it has no children.
    private var child0: [Int] = [-1]
    private var child1: [Int] = [-1]
    private var symbol: [Int] = [-1]

    private func newNode() -> Int {
        child0.append(-1)
        child1.append(-1)
        symbol.append(-1)
        return symbol.count - 1
    }

    /// Insert `value` at the code given by `hbf` (high-bit-first) of `length` bits.
    func insert(hbf: UInt32, length: Int, value: Int) throws {
        guard (1...32).contains(length), value >= 0, UInt64(hbf) < (UInt64(1) << length) else { throw PrefixCodeError.malformedTable }
        var node = 0
        for k in 0..<length {
            let bit = Int((hbf >> UInt32(length - 1 - k)) & 1)
            if symbol[node] >= 0 { throw PrefixCodeError.malformedTable } // prefix conflict
            var next = bit == 0 ? child0[node] : child1[node]
            if next == -1 {
                next = newNode()
                if bit == 0 { child0[node] = next } else { child1[node] = next }
            }
            node = next
        }
        if symbol[node] >= 0 || child0[node] != -1 || child1[node] != -1 { throw PrefixCodeError.malformedTable }
        symbol[node] = value
    }

    /// Build a canonical code from per-symbol bit lengths (`shortestCodeIsZeros`).
    /// Symbols with length <= 0 are omitted. This reproduces XADPrefixCode's
    /// `initWithLengths:...shortestCodeIsZeros:YES` assignment exactly.
    static func canonical(lengths: [Int], count: Int) throws -> PrefixCode {
        guard count >= 0, count <= lengths.count,
              lengths.prefix(count).allSatisfy({ (-1...32).contains($0) }) else { throw PrefixCodeError.malformedTable }
        let code = PrefixCode()
        var value: UInt64 = 0
        for length in 1...32 {
            for i in 0..<count where lengths[i] == length {
                guard value < (UInt64(1) << length) else { throw PrefixCodeError.malformedTable }
                try code.insert(hbf: UInt32(value), length: length, value: i)
                value += 1
            }
            value <<= 1
        }
        return code
    }

    /// Decode the next symbol from the reader.
    func next(_ reader: inout BitReaderLE) throws -> Int {
        var node = 0
        while symbol[node] < 0 {
            let bit = try reader.bit()
            let next = bit == 0 ? child0[node] : child1[node]
            if next == -1 { throw PrefixCodeError.invalidBitstream }
            node = next
        }
        return symbol[node]
    }
}

/// Reverse the low `length` bits of `value`.
func reverseBits(_ value: UInt32, length: Int) -> UInt32 {
    var v = value
    var r: UInt32 = 0
    for _ in 0..<length {
        r = (r << 1) | (v & 1)
        v >>= 1
    }
    return r
}
