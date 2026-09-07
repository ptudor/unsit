// Copyright (c) 2026 Patrick Tudor. SPDX-License-Identifier: MIT

enum StuffIt13Error: Error { case emptyInput, illegalSubMethod(Int), tableSizeMismatch }

struct ForkDamage: Error, CustomStringConvertible {
    let bytes: [UInt8]
    let description: String
}

/// Method 13's wire grammar is documented in docs/method-13.md. This decoder
/// uses canonical numeric ranges and copies from its bounded output history.
struct StuffIt13 {
    private var input: BitReaderLE
    private let contexts: [PrefixCode]
    private let distances: PrefixCode
    private(set) var terminalMatchRemaining = 0

    init(_ payload: [UInt8]) throws {
        guard let control = payload.first else { throw StuffIt13Error.emptyInput }
        let preset = Int(control >> 4)
        guard preset <= 5 else { throw StuffIt13Error.illegalSubMethod(preset) }
        var cursor = BitReaderLE(payload, startOffset: 1)
        var lengths: [[Int]]
        if preset > 0 {
            lengths = [StuffIt13Tables.firstCodeLengths[preset - 1],
                       StuffIt13Tables.secondCodeLengths[preset - 1],
                       StuffIt13Tables.offsetCodeLengths[preset - 1]]
        } else {
            let meta = PrefixCode()
            for symbol in StuffIt13Tables.metaCodes.indices {
                let width = StuffIt13Tables.metaCodeLengths[symbol]
                try meta.insert(hbf: reverseBits(StuffIt13Tables.metaCodes[symbol], length: width), length: width, value: symbol)
            }
            let first = try Self.readLengths(321, from: &cursor, using: meta)
            let second = control & 8 != 0 ? first : try Self.readLengths(321, from: &cursor, using: meta)
            lengths = [first, second, try Self.readLengths(Int(control & 7) + 10, from: &cursor, using: meta)]
        }
        let codes = try lengths.map { try PrefixCode.canonical(lengths: $0, count: $0.count) }
        contexts = Array(codes.prefix(2))
        distances = codes[2]
        input = cursor
    }

    private static func readLengths(_ count: Int, from input: inout BitReaderLE, using meta: PrefixCode) throws -> [Int] {
        var result: [Int] = []
        var current = 0
        while result.count < count {
            let operation = try meta.next(&input)
            var copies = 1
            switch operation {
            case 0...30: current = operation + 1
            case 31: current = -1
            case 32: current += 1
            case 33: current -= 1
            case 34...36:
                let index = operation - 34
                copies = [1, 3, 11][index] + (try input.bits([1, 3, 6][index]))
            default: throw PrefixCodeError.malformedTable
            }
            guard (-1...32).contains(current), copies <= count - result.count else {
                throw PrefixCodeError.malformedTable
            }
            result.append(contentsOf: repeatElement(current, count: copies))
        }
        return result
    }

    mutating func decompress(expectedLength: Int) throws -> [UInt8] {
        guard expectedLength >= 0 else { throw StuffIt13Error.tableSizeMismatch }
        var output: [UInt8] = []
        output.reserveCapacity(min(expectedLength, 1 << 20))
        var context = 0
        do {
            while output.count < expectedLength {
                let token = try contexts[context].next(&input)
                if token < 256 {
                    output.append(UInt8(token))
                    context = 0
                    continue
                }
                guard token < 320 else {
                    throw ForkDamage(bytes: output, description: "end marker before declared fork length")
                }
                let length: Int
                switch token {
                case 256...317: length = token - 253
                case 318: length = 65 + (try input.bits(10))
                default: length = 65 + (try input.bits(15))
                }
                let category = try distances.next(&input)
                guard (0...16).contains(category) else { throw PrefixCodeError.invalidBitstream }
                let distance = category == 0 ? 1 : (1 << (category - 1)) + (try input.bits(category - 1)) + 1
                let count = min(length, expectedLength - output.count)
                // The first 64 KiB of logical history is zero. Reading the
                // growing output directly also handles overlapping matches.
                for _ in 0..<count {
                    let source = output.count - distance
                    output.append(source < 0 ? 0 : output[source])
                }
                terminalMatchRemaining = length - count
                context = 1
            }
        } catch let damage as ForkDamage {
            throw damage
        } catch {
            throw ForkDamage(bytes: output, description: "damaged compressed stream: \(error)")
        }
        return output
    }
}
