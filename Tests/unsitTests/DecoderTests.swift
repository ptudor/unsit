import Foundation
import XCTest
@testable import unsit

final class DecoderTests: XCTestCase {
    func testCompressedEOFAndAllByteTruncations() throws {
        for flags in [[], ["--no-verify"]] {
            let result = try Sandbox().run(Fixture.archive([Fixture.member(data: [0x10], dm: 13, du: 4096, dataCRC: 0)]), flags)
            XCTAssertNotEqual(result.0, 0); XCTAssertTrue(result.2.contains("truncat"), result.2)
        }
        for name in (1...5).map({ "valid_preset_\($0)" }) + ["valid_dynamic", "valid_dynamic_separate", "valid_extended_window_wrap"] {
            let bytes = try Fixture.golden(name)
            let payload = Array(bytes.dropFirst(134))
            let expected = name.contains("extended") ? 66754 : 8
            for end in 0..<payload.count {
                do {
                    var decoder = try StuffIt13(Array(payload.prefix(end)))
                    _ = try decoder.decompress(expectedLength: expected)
                    XCTFail("accepted truncated \(name) at byte \(end)")
                } catch { }
            }
        }
    }
    func testPrefixValidation() throws {
        XCTAssertThrowsError(try PrefixCode.canonical(lengths: [1,1,1], count: 3))
        XCTAssertThrowsError(try PrefixCode.canonical(lengths: [33], count: 1))
        XCTAssertThrowsError(try PrefixCode.canonical(lengths: [1], count: 2))
        XCTAssertThrowsError(try PrefixCode.canonical(lengths: [1], count: -1))
        for (a,b) in [(1,1), (1,2), (2,1)] {
            let code = PrefixCode()
            try code.insert(hbf: 0, length: a, value: 42)
            XCTAssertThrowsError(try code.insert(hbf: 0, length: b, value: 99))
        }
        for width in [1,31,32] {
            let c = try PrefixCode.canonical(lengths: [width], count: 1)
            var r = BitReaderLE([0,0,0,0], startOffset: 0)
            XCTAssertEqual(try c.next(&r), 0)
        }
        XCTAssertNoThrow(try PrefixCode.canonical(lengths: [-1,0,3,3], count: 4))
    }
    func testStoredLengthAndEarlyEndDamage() throws {
        for flags in [[], ["--no-verify"]] {
            for member in [Fixture.member(data: [65], du: 20), Fixture.member(data: [1,2], du: 1),
                           Fixture.member(data: [1], du: 0), Fixture.member(data: [], du: 1),
                           Fixture.member(data: [0x10,0x16], dm: 13, du: 20, dataCRC: 0)] {
                let result = try Sandbox().run(Fixture.archive([member]), flags)
                XCTAssertNotEqual(result.0, 0); XCTAssertTrue(result.2.contains("length"), result.2)
            }
        }
    }
    func testAbsentForkMethods() throws {
        for method: UInt8 in [13,99,128] {
            for member in [Fixture.member(data: [1], rm: method), Fixture.member(rsrc: [2], dm: method), Fixture.member(rm: method, dm: method)] {
                let s = try Sandbox()
                XCTAssertEqual(try s.run(Fixture.archive([member])).0, 0)
            }
        }
    }
}

extension DecoderTests {
    func dynamic(_ first: Bits, second: Bits? = nil, literals: [Int] = [65]) -> [UInt8] {
        var bits = first
        if let second = second { bits.bits += second.bits }
        for _ in 0..<10 { bits.meta(3) }
        for symbol in literals { bits.code(symbol, [Int](repeating: 9, count: 321)) }
        return [second == nil ? 8 : 0] + bits.bytes
    }
    func testDynamicRunsWidthsAndOmission() throws {
        for (token,width,minExtra,maxExtra,base) in [(34,1,0,1,1),(35,3,0,7,3),(36,6,0,63,11)] {
            for extra in [minExtra,maxExtra] {
                let emitted = base + extra
                var exact = Bits()
                for _ in 0..<(321-emitted) { exact.meta(8) }
                exact.meta(token); exact.low(extra,width)
                var decoder = try StuffIt13(dynamic(exact))
                XCTAssertEqual(try decoder.decompress(expectedLength: 1), [65])
                for over in [1, emitted] {
                    var bad = Bits()
                    for _ in 0..<(321-emitted+over) { bad.meta(8) }
                    bad.meta(token); bad.low(extra,width)
                    // For a full preceding table the repeat belongs to offsets and
                    // might be coherent there, so only test actual crossing runs.
                    if over < emitted { XCTAssertThrowsError(try StuffIt13(dynamic(bad))) }
                }
            }
        }
        var overrun = Bits(); overrun.meta(8)
        for _ in 0..<4 { overrun.meta(36); overrun.low(63,6) }
        overrun.meta(36); overrun.low(14,6)
        XCTAssertThrowsError(try StuffIt13(dynamic(overrun)))
        for prefix in [[31,33], [30,32,32]] {
            var bad = Bits(); for t in prefix { bad.meta(t) }
            for _ in prefix.count..<321 { bad.meta(8) }
            XCTAssertThrowsError(try StuffIt13(dynamic(bad)))
        }
        var oversubscribed = Bits(); for _ in 0..<321 { oversubscribed.meta(0) }
        XCTAssertThrowsError(try StuffIt13(dynamic(oversubscribed)))
        // Explicit omitted -1, increment(-1) to zero, and decrement(1) to zero.
        for prefix in [[31,32], [0,33]] {
            var b = Bits(); for t in prefix { b.meta(t) }
            for _ in 2..<321 { b.meta(8) }
            for _ in 0..<10 { b.meta(3) }
            let lengths = prefix == [31,32] ? [-1,0] + [Int](repeating: 9, count: 319) : [1,0] + [Int](repeating: 10, count: 319)
            // For the length-1 prefix, use length 10 for remaining entries to
            // stay within canonical capacity.
            if prefix == [0,33] {
                b = Bits(); b.meta(0); b.meta(33)
                for _ in 2..<321 { b.meta(9) }
                for _ in 0..<10 { b.meta(3) }
            }
            b.code(65, lengths)
            var decoder = try StuffIt13([8] + b.bytes)
            XCTAssertEqual(try decoder.decompress(expectedLength: 1), [65])
        }
    }
    func testByteEndAlignmentsAndTerminalMatch() throws {
        var alignments = Set<Int>()
        let literal = StuffIt13Tables.firstCodeLengths[0].prefix(256).firstIndex(where: { $0 % 2 == 1 })!
        for count in 1...8 {
            var bits = Bits()
            for _ in 0..<count { bits.code(literal, StuffIt13Tables.firstCodeLengths[0]) }
            alignments.insert(bits.bits.count % 8)
            var decoder = try StuffIt13([0x10] + bits.bytes)
            XCTAssertEqual(try decoder.decompress(expectedLength: count), [UInt8](repeating: UInt8(literal), count: count))
        }
        XCTAssertEqual(alignments.count, 8)
        var bits = Bits(); bits.code(65, StuffIt13Tables.firstCodeLengths[0])
        bits.code(256, StuffIt13Tables.firstCodeLengths[0]); bits.code(0, StuffIt13Tables.offsetCodeLengths[0])
        var decoder = try StuffIt13([0x10] + bits.bytes)
        XCTAssertEqual(try decoder.decompress(expectedLength: 2), [65,65])
        XCTAssertEqual(decoder.terminalMatchRemaining, 2)
        let s = try Sandbox(); XCTAssertEqual(try s.run(Fixture.golden("valid_extended_window_wrap")).0, 0)
        XCTAssertEqual(try s.bytes("f"), [UInt8](repeating: 65, count: 66753) + [66])
    }
}

extension DecoderTests {
    func testDynamicRepeatExtrasTruncationAndArchiveFailures() throws {
        var first = Bits(); first.meta(8)
        for _ in 0..<4 { first.meta(36); first.low(63,6) }
        first.meta(36); first.low(13,6)
        let bytes = dynamic(first)
        var valid = try StuffIt13(bytes)
        XCTAssertEqual(try valid.decompress(expectedLength: 1), [65])
        for end in 0..<bytes.count {
            XCTAssertThrowsError(try { var decoder = try StuffIt13(Array(bytes.prefix(end))); return try decoder.decompress(expectedLength: 1) }())
        }
        var bad = Bits(); for _ in 0..<321 { bad.meta(0) }
        for flags in [[], ["--no-verify"]] {
            XCTAssertNotEqual(try Sandbox().run(Fixture.archive([Fixture.member(data: dynamic(bad), dm: 13, du: 1, dataCRC: 0)]), flags).0, 0)
        }
    }
}
