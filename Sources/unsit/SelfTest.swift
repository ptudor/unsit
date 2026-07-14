import Foundation

/// Fast, dependency-free sanity checks run via `unsit --self-test`. These guard
/// the hand-transcribed constant tables and the core primitives against
/// regressions, independent of any archive on disk.
enum SelfTest {
    static func run() -> Int32 {
        var failures: [String] = []

        func check(_ condition: Bool, _ message: @autoclosure () -> String) {
            if !condition { failures.append(message()) }
        }

        // CRC-16/ARC standard check value: crc("123456789") == 0xBB3D.
        check(CRC16.checksum(Array("123456789".utf8)) == 0xBB3D, "CRC-16/ARC check value")

        // reverseBits round-trips and matches known cases.
        check(reverseBits(0b001, length: 3) == 0b100, "reverseBits 001->100")
        check(reverseBits(0b1011, length: 4) == 0b1101, "reverseBits 1011->1101")

        // Table shapes: five presets, 321-symbol first/second codes, offset
        // codes sized per OffsetCodeSize.
        check(StuffIt13Tables.firstCodeLengths.count == 5, "firstCodeLengths group count")
        check(StuffIt13Tables.secondCodeLengths.count == 5, "secondCodeLengths group count")
        check(StuffIt13Tables.offsetCodeLengths.count == 5, "offsetCodeLengths group count")
        check(StuffIt13Tables.metaCodes.count == 37, "metaCodes count")
        check(StuffIt13Tables.metaCodeLengths.count == 37, "metaCodeLengths count")
        for i in 0..<5 {
            check(StuffIt13Tables.firstCodeLengths[i].count == 321, "firstCodeLengths[\(i)] size")
            check(StuffIt13Tables.secondCodeLengths[i].count == 321, "secondCodeLengths[\(i)] size")
            check(StuffIt13Tables.offsetCodeLengths[i].count == StuffIt13Tables.offsetCodeSize[i],
                  "offsetCodeLengths[\(i)] size")
        }

        // Every preset table must build a valid canonical prefix code (no
        // prefix conflicts / over-full trees) — catches most transcription slips.
        for i in 0..<5 {
            do {
                _ = try PrefixCode.canonical(lengths: StuffIt13Tables.firstCodeLengths[i], count: 321)
                _ = try PrefixCode.canonical(lengths: StuffIt13Tables.secondCodeLengths[i], count: 321)
                _ = try PrefixCode.canonical(lengths: StuffIt13Tables.offsetCodeLengths[i],
                                             count: StuffIt13Tables.offsetCodeSize[i])
            } catch {
                failures.append("preset table \(i + 1) is not a valid prefix code: \(error)")
            }
        }

        // The metacode built from MetaCodes/MetaCodeLengths must be conflict-free.
        do {
            let meta = PrefixCode()
            for i in 0..<37 {
                try meta.insert(hbf: reverseBits(StuffIt13Tables.metaCodes[i], length: StuffIt13Tables.metaCodeLengths[i]),
                                length: StuffIt13Tables.metaCodeLengths[i], value: i)
            }
        } catch {
            failures.append("metacode is not a valid prefix code: \(error)")
        }

        if failures.isEmpty {
            print("self-test: OK")
            return 0
        }
        for f in failures { FileHandle.standardError.write(Data("self-test FAILED: \(f)\n".utf8)) }
        return 1
    }
}
