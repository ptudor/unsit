// Copyright (c) 2026 Patrick Tudor. SPDX-License-Identifier: MIT

enum PrefixCodeError: Error { case invalidBitstream, malformedTable }

/// Canonical codes are decoded by numeric ranges, one range per bit width.
/// Explicit codes (used by the format's metacode) use sentinel-prefixed keys.
final class PrefixCode {
    private struct Range {
        var first: UInt64 = 0
        var symbols: [Int] = []
    }
    private var ranges: [Range]?
    private var explicit: [UInt64: Int] = [:]
    private var longest = 0

    func insert(hbf: UInt32, length: Int, value: Int) throws {
        guard ranges == nil, (1...32).contains(length), value >= 0,
              UInt64(hbf) < (UInt64(1) << length) else { throw PrefixCodeError.malformedTable }
        let key = (UInt64(1) << length) | UInt64(hbf)
        var ancestor = key
        while ancestor > 0 {
            guard explicit[ancestor] == nil else { throw PrefixCodeError.malformedTable }
            ancestor >>= 1
        }
        for existing in explicit.keys {
            let existingWidth = 63 - existing.leadingZeroBitCount
            if existingWidth > length && existing >> (existingWidth - length) == key {
                throw PrefixCodeError.malformedTable
            }
        }
        explicit[key] = value
        longest = max(longest, length)
    }

    static func canonical(lengths: [Int], count: Int) throws -> PrefixCode {
        guard (0...lengths.count).contains(count) else { throw PrefixCodeError.malformedTable }
        var groups = [Range](repeating: Range(), count: 33)
        for symbol in 0..<count {
            let width = lengths[symbol]
            guard (-1...32).contains(width) else { throw PrefixCodeError.malformedTable }
            if width > 0 { groups[width].symbols.append(symbol) }
        }
        var first: UInt64 = 0
        let code = PrefixCode()
        for width in 1...32 {
            first = (first + UInt64(groups[width - 1].symbols.count)) << 1
            guard first + UInt64(groups[width].symbols.count) <= UInt64(1) << width else {
                throw PrefixCodeError.malformedTable
            }
            groups[width].first = first
            if !groups[width].symbols.isEmpty { code.longest = width }
        }
        code.ranges = groups
        return code
    }

    func next(_ reader: inout BitReaderLE) throws -> Int {
        guard longest > 0 else { throw PrefixCodeError.invalidBitstream }
        var value: UInt64 = 0
        var key: UInt64 = 1
        for width in 1...longest {
            let bit = UInt64(try reader.bit())
            value = value * 2 + bit
            if let ranges = ranges {
                let group = ranges[width]
                if value >= group.first {
                    let index = value - group.first
                    if index < UInt64(group.symbols.count) { return group.symbols[Int(index)] }
                }
            } else {
                key = key * 2 + bit
                if let symbol = explicit[key] { return symbol }
            }
        }
        throw PrefixCodeError.invalidBitstream
    }
}

func reverseBits(_ value: UInt32, length: Int) -> UInt32 {
    (0..<length).reduce(UInt32(0)) { ($0 << 1) | ((value >> $1) & 1) }
}
