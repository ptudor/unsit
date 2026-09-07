import Foundation
import XCTest
@testable import unsit

final class LimitsAndDisplayTests: XCTestCase {
    func testResourceBoundaries() throws {
        let bytes = Fixture.archive([Fixture.member(data: [1,2], rsrc: [3,4])])
        for (option, good, bad) in [("--max-input-bytes", bytes.count, bytes.count-1),
                                    ("--max-fork-bytes", 2, 1), ("--max-total-bytes", 4, 3),
                                    ("--max-members", 1, 0)] {
            let s = try Sandbox()
            XCTAssertEqual(try s.run(bytes, [option, String(good)]).0, 0, option)
            let other = try Sandbox()
            let result = try other.run(bytes, [option, String(bad)])
            XCTAssertNotEqual(result.0, 0, option); XCTAssertTrue(result.2.contains("limit"), result.2)
            XCTAssertFalse(FileManager.default.fileExists(atPath: other.out.appendingPathComponent("f").path))
        }
        let s = try Sandbox()
        XCTAssertNotEqual(try s.run(Fixture.archive([Fixture.member("a", data: [1,2]), Fixture.member("b", data: [3,4])]), ["--max-total-bytes", "3"]).0, 0)
        XCTAssertEqual(try s.bytes("a"), [1,2])
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.out.appendingPathComponent("b").path))
        let nested = Fixture.archive([Fixture.member("a", rm: 32), Fixture.member("b", rm: 32), Fixture.member("b", rm: 33), Fixture.member("a", rm: 33)])
        XCTAssertEqual(try Sandbox().run(nested, ["--list", "--max-depth", "2"]).0, 0)
        XCTAssertNotEqual(try Sandbox().run(nested, ["--list", "--max-depth", "1"]).0, 0)
        XCTAssertNotEqual(try Sandbox().run(Fixture.archive([[UInt8](repeating: 63, count: 20), Fixture.member(data: [1])]), ["--max-recovery-bytes", "4"]).0, 0)
        XCTAssertNotEqual(try Sandbox().run(Fixture.archive([Fixture.member(data: [0x10], dm: 13, du: Int(UInt32.max))])).0, 0)
        let golden = try Fixture.golden("valid_extended_window_wrap")
        XCTAssertEqual(try Sandbox().run(golden, ["--max-fork-bytes", "66754"]).0, 0)
        XCTAssertNotEqual(try Sandbox().run(golden, ["--max-fork-bytes", "66753"]).0, 0)
    }
    func testDisplayControls() throws {
        let name = "\u{1b}]0;title\u{7}\r\n\tname"
        for flags in [[], ["--list"], ["--quiet"], ["--no-verify"]] {
            let s = try Sandbox()
            let result = try s.run(Fixture.archive([Fixture.member(name, data: [1], dataCRC: 42)]), flags)
            for output in [result.1, result.2] {
                XCTAssertFalse(output.contains("\u{1b}")); XCTAssertFalse(output.contains("\r")); XCTAssertFalse(output.contains("\t")); XCTAssertFalse(output.contains("\u{7}"))
                XCTAssertFalse(output.contains("\n\tname"))
            }
            if !flags.contains("--list") { XCTAssertEqual(try s.bytes(flags.contains("--no-verify") ? name : name + ".partial-22"), [1]) }
        }
    }
}

extension LimitsAndDisplayTests {
    func testMaximumDeclarationInLimitedSubprocess() throws {
        let s = try Sandbox()
        let source = Bundle.module.url(forResource: "resource-driver", withExtension: "c", subdirectory: "Fixtures")!
        let driver = s.root.appendingPathComponent("resource-driver")
        let compile = Process(); compile.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compile.arguments = [source.path, "-o", driver.path]
        try compile.run(); compile.waitUntilExit(); XCTAssertEqual(compile.terminationStatus, 0)
        try Data(Fixture.archive([Fixture.member(data: [0x10], dm: 13, du: Int(UInt32.max))])).write(to: s.root.appendingPathComponent("input.sit"))
        let result = try s.command([Sandbox.binary.path, "--quiet", "input.sit", "out"], executable: driver)
        XCTAssertEqual(result.0, 1, result.2); XCTAssertTrue(result.2.contains("resource limit exceeded"))
        let rss = Int(result.1.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "=").last!)!
        XCTAssertGreaterThan(rss, 0); XCTAssertLessThan(rss, 128 * 1024 * 1024)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: s.out.path), [])
    }
    func testTypeControlsAndErrorPathsAreEscaped() throws {
        var member = Fixture.member("é/name", data: [1], dm: 99)
        member.replaceSubrange(66..<70, with: [0x1b,13,9,0])
        Fixture.put(Int(Fixture.crc(Array(member.prefix(110)))), in: &member, at: 110, width: 2)
        for flags in [[], ["--quiet"], ["--list"]] {
            let result = try Sandbox().run(Fixture.archive([member]), flags)
            for text in [result.1, result.2] {
                XCTAssertFalse(text.contains("\u{1b}")); XCTAssertFalse(text.contains("\r")); XCTAssertFalse(text.contains("\t")); XCTAssertFalse(text.contains("\0"))
            }
        }
        let s = try Sandbox()
        let result = try s.command(["missing\u{1b}\n.sit"])
        XCTAssertEqual(result.0, 1); XCTAssertFalse(result.2.contains("\u{1b}")); XCTAssertTrue(result.2.contains("\\n"))
        XCTAssertEqual(try s.run(Fixture.archive([Fixture.member("é/name", data: [1])])).0, 0)
        XCTAssertEqual(try s.bytes("é:name"), [1])
    }
}
