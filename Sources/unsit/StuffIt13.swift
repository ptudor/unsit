import Foundation

enum StuffIt13Error: Error {
    case emptyInput
    case illegalSubMethod(Int)
    case tableSizeMismatch
}

/// Decompressor for classic StuffIt compression method 13
/// ("LZ + dynamic Huffman"). Reimplemented from the algorithm in XADMaster's
/// XADStuffIt13Handle.m (LGPL-2.1); see README for provenance.
///
/// The stream begins with a selector byte whose high nibble chooses the code
/// set: 0 builds dynamic Huffman codes from a metacode-encoded length table,
/// 1...5 load one of five preset static tables. Two 321-symbol codes model
/// the alternation between "after a literal" and "after a match" contexts, and
/// a small offset code encodes match distances.
struct ForkDamage: Error, CustomStringConvertible {
    let bytes: [UInt8]
    let description: String
}

struct StuffIt13 {
    private var reader: BitReaderLE
    private let firstCode: PrefixCode
    private let secondCode: PrefixCode
    private let offsetCode: PrefixCode
    private(set) var terminalMatchRemaining = 0

    init(_ data: [UInt8]) throws {
        guard let selector = data.first else { throw StuffIt13Error.emptyInput }
        var r = BitReaderLE(data, startOffset: 1)
        let code = Int(selector) >> 4

        if code == 0 {
            // Dynamic: parse three code-length tables via the metacode.
            let meta = PrefixCode()
            for i in 0..<37 {
                try meta.insert(
                    hbf: reverseBits(StuffIt13Tables.metaCodes[i], length: StuffIt13Tables.metaCodeLengths[i]),
                    length: StuffIt13Tables.metaCodeLengths[i],
                    value: i
                )
            }
            self.firstCode = try StuffIt13.parseCode(size: 321, meta: meta, reader: &r)
            if (Int(selector) & 0x08) != 0 {
                self.secondCode = self.firstCode
            } else {
                self.secondCode = try StuffIt13.parseCode(size: 321, meta: meta, reader: &r)
            }
            self.offsetCode = try StuffIt13.parseCode(size: (Int(selector) & 0x07) + 10, meta: meta, reader: &r)
        } else if code < 6 {
            let idx = code - 1
            let first = StuffIt13Tables.firstCodeLengths[idx]
            let second = StuffIt13Tables.secondCodeLengths[idx]
            let offset = StuffIt13Tables.offsetCodeLengths[idx]
            guard first.count == 321, second.count == 321,
                  offset.count == StuffIt13Tables.offsetCodeSize[idx] else {
                throw StuffIt13Error.tableSizeMismatch
            }
            self.firstCode = try PrefixCode.canonical(lengths: first, count: 321)
            self.secondCode = try PrefixCode.canonical(lengths: second, count: 321)
            self.offsetCode = try PrefixCode.canonical(lengths: offset, count: StuffIt13Tables.offsetCodeSize[idx])
        } else {
            throw StuffIt13Error.illegalSubMethod(code)
        }
        self.reader = r
    }

    /// Parse a run-length-encoded code-length table using the metacode, then
    /// build a canonical prefix code of `size` symbols. Faithful to
    /// `allocAndParseCodeOfSize:` including its index-advancing repeat cases.
    private static func parseCode(size: Int, meta: PrefixCode, reader: inout BitReaderLE) throws -> PrefixCode {
        var lengths = [Int]()
        lengths.reserveCapacity(size)
        var length = 0
        while lengths.count < size {
            let val = try meta.next(&reader)
            var emitted = 1
            switch val {
            case 31: length = -1
            case 32: length += 1
            case 33: length -= 1
            case 34: emitted += try reader.bit()
            case 35: emitted += try reader.bits(3) + 2
            case 36: emitted += try reader.bits(6) + 10
            default: length = val + 1
            }
            // Both -1 and zero are omitted by the reference canonical builder;
            // compatibility fixtures cover increment(-1) and decrement(1).
            guard (-1...32).contains(length), emitted <= size - lengths.count else {
                throw StuffIt13Error.tableSizeMismatch
            }
            lengths.append(contentsOf: repeatElement(length, count: emitted))
        }
        return try PrefixCode.canonical(lengths: lengths, count: size)
    }

    /// Window size of the LZSS back-reference buffer (must be a power of two).
    private static let windowSize = 65536
    private static let windowMask = windowSize - 1

    /// Decompress up to `expectedLength` bytes.
    ///
    /// Reconstruction uses a zero-initialized circular window of `windowSize`
    /// bytes, exactly as XADMaster's XADLZSSHandle: each produced byte is read
    /// from `window[(pos - offset) & mask]` and written to `window[pos & mask]`.
    /// Offsets are never bounds-checked — on a valid stream they always point
    /// within the produced output, and on a damaged stream this yields the same
    /// best-effort bytes the reference decoder produces rather than aborting.
    mutating func decompress(expectedLength: Int) throws -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(expectedLength)
        var window = [UInt8](repeating: 0, count: Self.windowSize)
        let mask = Self.windowMask
        var pos = 0
        // The active code toggles between the literal-context (`firstCode`) and
        // match-context (`secondCode`) codes depending on whether the previous
        // symbol was a literal or a match; it starts as the literal code.
        var currentIsFirst = true

        do {
        while out.count < expectedLength {
            let code = currentIsFirst ? firstCode : secondCode
            let val = try code.next(&reader)

            if val < 0x100 {
                window[pos & mask] = UInt8(val)
                out.append(UInt8(val))
                pos += 1
                currentIsFirst = true
                continue
            }

            currentIsFirst = false
            let matchLength: Int
            if val < 0x13e {
                matchLength = val - 0x100 + 3
            } else if val == 0x13e {
                matchLength = try reader.bits(10) + 65
            } else if val == 0x13f {
                matchLength = try reader.bits(15) + 65
            } else {
                break // end marker (0x140)
            }

            let bitLength = try offsetCode.next(&reader)
            let offset: Int
            if bitLength == 0 {
                offset = 1
            } else if bitLength == 1 {
                offset = 2
            } else {
                offset = try (1 << (bitLength - 1)) + reader.bits(bitLength - 1) + 1
            }

            terminalMatchRemaining = max(0, matchLength - (expectedLength - out.count))
            var matchOffset = pos - offset
            for _ in 0..<matchLength {
                if out.count >= expectedLength { break }
                let byte = window[matchOffset & mask]
                matchOffset += 1
                window[pos & mask] = byte
                out.append(byte)
                pos += 1
            }
        }

        }
        catch { throw ForkDamage(bytes: out, description: String(describing: error)) }
        guard out.count == expectedLength else {
            throw ForkDamage(bytes: out, description: "decoded length \(out.count) differs from declared length \(expectedLength) (early end marker)")
        }
        return out
    }
}
