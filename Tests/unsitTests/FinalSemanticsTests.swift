import Foundation
import XCTest
@testable import unsit

final class FinalSemanticsTests: XCTestCase {
    func testFolderDatesAfterChildPublication() throws {
        for child in [Fixture.member("child", data: [1], rsrc: [2]), Fixture.member("child", data: [0x60], dm: 13)] {
            let s = try Sandbox()
            let parts = [Fixture.member("outer", rm: 32, mod: 3_000_000_001), Fixture.member("inner", rm: 32, mod: 3_000_000_002), child,
                         Fixture.member("inner", rm: 33, mod: 3_000_000_100), Fixture.member("empty", rm: 32, mod: 3_000_000_003), Fixture.member("empty", rm: 33), Fixture.member("outer", rm: 33)]
            let result = try s.run(Fixture.archive(parts))
            XCTAssertEqual(result.0, child[1] == 13 ? 1 : 0, result.2)
            for (name,seconds) in [("outer",917155201), ("outer/inner",917155202), ("outer/empty",917155203)] {
                XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: s.out.appendingPathComponent(name).path)[.modificationDate] as? Date, Date(timeIntervalSince1970: Double(seconds)), name)
            }
        }
        let result = try Sandbox().run(Fixture.archive([Fixture.member("open", rm: 32), Fixture.member("child", data: [1])]))
        XCTAssertNotEqual(result.0, 0); XCTAssertTrue(result.2.contains("unclosed"))
    }
    func testHistoricalDates() throws {
        for mac: UInt32 in [0,1,2_000_000_000,2_082_844_800,3_000_000_000,UInt32.max] {
            let s = try Sandbox(), started = Date().timeIntervalSince1970
            let result = try s.run(Fixture.archive([Fixture.member(data: [1], mod: mac)]))
            if result.0 != 0 {
                XCTAssertTrue(result.2.contains("modification date"), result.2)
                XCTAssertTrue(result.2.contains("partial")); continue
            }
            let date = try FileManager.default.attributesOfItem(atPath: s.out.appendingPathComponent("f").path)[.modificationDate] as! Date
            if mac == 0 { XCTAssertGreaterThanOrEqual(date.timeIntervalSince1970, started - 1) }
            else { XCTAssertEqual(date.timeIntervalSince1970, Double(Int64(mac)-2_082_844_800)) }
        }
    }
    func testQuietAndArgumentActions() throws {
        let archive = Fixture.archive([Fixture.member(data: [1])])
        let quiet = try Sandbox().run(archive, ["--quiet"])
        XCTAssertEqual(quiet.0, 0); XCTAssertEqual(quiet.1, "")
        let list = try Sandbox().run(archive, ["--list", "--quiet"])
        XCTAssertEqual(list.0, 0); XCTAssertTrue(list.1.contains("f  [TEXT]"))
        let bad = try Sandbox().run(Fixture.archive([Fixture.member(data: [1], dataCRC: 123)]), ["--quiet"])
        XCTAssertEqual(bad.1, ""); XCTAssertNotEqual(bad.0, 0); XCTAssertFalse(bad.2.isEmpty)
        let s = try Sandbox(); try Data(archive).write(to: s.root.appendingPathComponent("input.sit"))
        let literalValue = try s.command(["--output", "--self-test", "input.sit"])
        XCTAssertEqual(literalValue.0, 0, literalValue.2)
        XCTAssertEqual(try Data(contentsOf: s.root.appendingPathComponent("--self-test/f")), Data([1]))
        for args in [["-o","chosen","input.sit","positional"], ["--self-test","input.sit","mixed"], ["--version","input.sit"], ["--version","--self-test"], ["--output"], ["--max-depth"], ["--self-test","--list"], ["-o","a","-o","b","input.sit"]] {
            let result = try s.command(args)
            XCTAssertEqual(result.0, 2, args.joined(separator: " ")); XCTAssertFalse(result.2.isEmpty)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.root.appendingPathComponent("chosen").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.root.appendingPathComponent("positional").path))
        XCTAssertEqual(try s.command(["--self-test"]).0, 0)
        let version = try s.command(["--version"])
        XCTAssertEqual(version.0, 0); XCTAssertEqual(version.1, "unsit \(UnsitVersion.current)\n")
        let help = try s.command(["--help"]); XCTAssertEqual(help.0, 0); XCTAssertTrue(help.1.contains("--self-test"))
        try Data(archive).write(to: s.root.appendingPathComponent("-archive.sit"))
        XCTAssertEqual(try s.command(["--", "-archive.sit", "-out"]).0, 0)
        XCTAssertEqual(try Data(contentsOf: s.root.appendingPathComponent("-out/f")), Data([1]))
    }
}
