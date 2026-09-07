// Copyright (c) 2026 Patrick Tudor. SPDX-License-Identifier: MIT

enum BitReaderError: Error { case truncatedStream, invalidWidth }

/// A bounded cursor over little-endian bit fields, without speculative reads.
struct BitReaderLE {
    private let bytes: [UInt8]
    private var cursor: Int
    private(set) var truncated: Bool

    init(_ data: [UInt8], startOffset: Int) {
        bytes = data
        let valid = startOffset >= 0 && startOffset <= data.count
        cursor = valid ? startOffset * 8 : data.count * 8
        truncated = !valid
    }

    mutating func bit() throws -> Int { try bits(1) }

    mutating func bits(_ width: Int) throws -> Int {
        guard (0...32).contains(width) else { throw BitReaderError.invalidWidth }
        if width == 0 { return 0 }
        guard !truncated, width <= bytes.count * 8 - cursor else {
            truncated = true
            throw BitReaderError.truncatedStream
        }
        var value = 0
        var filled = 0
        while filled < width {
            let position = cursor & 7
            let take = min(8 - position, width - filled)
            let part = (Int(bytes[cursor / 8]) >> position) & ((1 << take) - 1)
            value |= part << filled
            cursor += take
            filled += take
        }
        return value
    }
}
