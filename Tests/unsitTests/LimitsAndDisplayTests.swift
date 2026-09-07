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
            if !flags.contains("--list") { XCTAssertEqual(try s.bytes(name), [1]) }
        }
    }
}
