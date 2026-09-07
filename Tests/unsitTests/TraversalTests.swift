import Foundation
import XCTest
@testable import unsit

final class TraversalTests: XCTestCase {
    func testContainerBoundsAndTruncations() throws {
        let valid = Fixture.archive([Fixture.member(data: [1,2])])
        for end in 0..<valid.count {
            let archive = try? SITArchive(data: Array(valid.prefix(end)))
            if let archive = archive {
                let report = try archive.forEachEntry(onResync: { _, _ in }) { _ in }
                XCTAssertFalse(report.complete, "boundary \(end)")
            }
        }
        var wrong = Fixture.archive([]); wrong.replaceSubrange(10..<14, with: [78,79,80,69])
        let badTail = Array(Fixture.member(data: [1]).dropLast())
        let cases = [wrong, Fixture.archive([], count: 1), Fixture.archive([badTail]),
                     Fixture.archive([Fixture.member(data: [1])], total: 22),
                     Fixture.archive([Fixture.member(data: [1])], total: 999),
                     Fixture.archive([Array(Fixture.member().prefix(60))])]
        for bytes in cases {
            for flags in [[], ["--list"], ["--quiet"], ["--no-verify"], ["--list","--no-verify"]] {
                let result = try Sandbox().run(bytes, flags)
                XCTAssertNotEqual(result.0, 0, "\(bytes.count) \(flags)"); XCTAssertFalse(result.2.isEmpty)
            }
        }
        XCTAssertEqual(try Sandbox().run(Fixture.archive([], count: 0)).0, 0)
        XCTAssertEqual(try Sandbox().run(Fixture.archive([], count: 0), ["--list"]).0, 0)
    }
    func testRootCountAndFlaggedFolders() throws {
        for rm: UInt8 in [0,0x30,0xb0] {
            let dm: UInt8 = rm == 0 ? 0x30 : 0
            let parts = [Fixture.member("dir", rm: rm, dm: dm), Fixture.member("inside", data: [1]),
                         Fixture.member("dir", rm: rm == 0 ? 0 : rm+1, dm: dm == 0 ? 0 : dm+1), Fixture.member("later", data: [2])]
            let s = try Sandbox(); let result = try s.run(Fixture.archive(parts, count: 2))
            XCTAssertEqual(result.0, 0, result.2); XCTAssertEqual(try s.bytes("dir/inside"), [1]); XCTAssertEqual(try s.bytes("later"), [2])
            XCTAssertNotEqual(try Sandbox().run(Fixture.archive(parts, count: 4), ["--list"]).0, 0)
        }
        XCTAssertNotEqual(try Sandbox().run(Fixture.archive([Fixture.member(data: [1], dm: 0x80)])).0, 0)
    }
    func testFalseRecoveryCandidatesAndOffsetDiagnostics() throws {
        let fake = Fixture.member("bogus", dm: 255, dc: 10000, nameLength: 255)
        let parts = [Fixture.member("first", data: [1,2,3]), [UInt8](repeating: 63, count: 17), [UInt8](repeating: 0, count: 112), fake, Fixture.member("good", data: [4])]
        let offset = 22 + parts.dropLast().reduce(0, { $0 + $1.count })
        for flags in [[], ["--list"]] {
            let s = try Sandbox(); let result = try s.run(Fixture.archive(parts, count: 2), flags)
            XCTAssertNotEqual(result.0, 0); XCTAssertTrue(result.2.contains("resynced at offset \(offset)"), result.2)
            if flags.isEmpty { XCTAssertEqual(try s.bytes(".unsit-recovery-\(offset)/good"), [4]) }
        }
        let exact = Fixture.archive([Fixture.member("first", data: [1,2,3]), [UInt8](repeating: 63, count: 17), Fixture.member("second", data: [4])], count: 2)
        let result = try Sandbox().run(exact, ["--list"])
        XCTAssertTrue(result.2.contains("resynced at offset 154, skipped 17"), result.2)
        var tail = Fixture.member("bad"); tail[110] ^= 1
        let terminal = try Sandbox().run(Fixture.archive([Fixture.member("first", data: [1,2,3]), tail], count: 2), ["--list"])
        XCTAssertNotEqual(terminal.0, 0); XCTAssertTrue(terminal.2.contains("137..249"), terminal.2)
    }
    func testUncertainAndUnbalancedHierarchy() throws {
        let intact = [Fixture.member("dir", rm: 32), Fixture.member("inside", data: [1]), Fixture.member("dir", rm: 33), Fixture.member("root_file", data: [2])]
        for damage in [0,2] {
            var parts = intact; parts[damage][110] ^= 1
            let s = try Sandbox(); let result = try s.run(Fixture.archive(parts, count: 2))
            XCTAssertNotEqual(result.0, 0); XCTAssertTrue(result.2.contains("uncertain"), result.2)
            let offset = 22 + parts.dropLast().reduce(0, { $0 + $1.count })
            XCTAssertEqual(try s.bytes(".unsit-recovery-\(offset)/root_file"), [2])
            XCTAssertFalse(FileManager.default.fileExists(atPath: s.out.appendingPathComponent("dir/root_file").path))
            let listing = try Sandbox().run(Fixture.archive(parts, count: 2), ["--list"])
            XCTAssertTrue(listing.1.contains(".unsit-recovery-\(offset)/root_file"), listing.1)
        }
        for parts in [[Fixture.member("dir", rm: 32)], [Fixture.member("dir", rm: 33)]] {
            XCTAssertNotEqual(try Sandbox().run(Fixture.archive(parts), ["--list"]).0, 0)
            XCTAssertNotEqual(try Sandbox().run(Fixture.archive(parts)).0, 0)
        }
    }
}

extension TraversalTests {
    func testUnsupportedCandidatesContradictoryMarkersAndSeededGaps() throws {
        for seed in 1...8 {
            var value = UInt32(seed)
            let gap: [UInt8] = (0..<64).map { _ in value = value &* 1664525 &+ 1013904223; return UInt8(truncatingIfNeeded: value >> 24) }
            let parts = [gap, Fixture.member("unsupported", data: [1], dm: 99), Fixture.member("good", data: [2])]
            let offset = 22 + 64 + 113
            let s = try Sandbox(); let result = try s.run(Fixture.archive(parts, count: 2))
            XCTAssertNotEqual(result.0, 0); XCTAssertTrue(result.2.contains("unsupported compression method 99"), result.2)
            XCTAssertEqual(try s.bytes(".unsit-recovery-\(offset)/good"), [2])
        }
        let bad = Fixture.member("dir", rm: 0x30, dm: 0x31)
        let result = try Sandbox().run(Fixture.archive([bad, Fixture.member("good", data: [1])]), ["--list"])
        XCTAssertNotEqual(result.0, 0); XCTAssertTrue(result.1.contains("good"))
        let gaps = Fixture.archive([Fixture.member("a", data: [1,2,3]), [UInt8](repeating: 63, count: 17), Fixture.member("b", data: [1]), [UInt8](repeating: 63, count: 19), Fixture.member("c", data: [1])], count: 3)
        let listed = try Sandbox().run(gaps, ["--list"])
        XCTAssertTrue(listed.2.contains("resynced at offset 154, skipped 17")); XCTAssertTrue(listed.2.contains("resynced at offset 286, skipped 19"))
    }
    func testBlockedNestedFolderAndPermissions() throws {
        let s = try Sandbox()
        try Data([7]).write(to: s.out.appendingPathComponent("blocked"))
        let parts = [Fixture.member("blocked", rm: 32), Fixture.member("nested", rm: 32), Fixture.member("child", data: [1]), Fixture.member("nested", rm: 33), Fixture.member("blocked", rm: 33), Fixture.member("later", data: [2])]
        XCTAssertNotEqual(try s.run(Fixture.archive(parts)).0, 0)
        XCTAssertEqual(try s.bytes("blocked"), [7]); XCTAssertEqual(try s.bytes("later"), [2])
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.out.appendingPathComponent("child").path))
        let parent = OutputDirectory(fd: open(s.out.path, O_RDONLY | O_DIRECTORY))
        XCTAssertThrowsError(try parent.create(String(repeating: "a", count: 256)))
        XCTAssertEqual(fchmod(parent.fd, 0o500), 0)
        defer { _ = fchmod(parent.fd, 0o755) }
        XCTAssertThrowsError(try parent.create("denied"))
    }
}

extension TraversalTests {
    func testNestedStructuralLossNeverMergesIdenticalNames() throws {
        let original = [Fixture.member("outer", rm: 32), Fixture.member("inner", rm: 32), Fixture.member("same", data: [1]), Fixture.member("inner", rm: 33), Fixture.member("same", data: [2]), Fixture.member("outer", rm: 33), Fixture.member("same", data: [3])]
        for damage in [0,1,3,5] {
            var parts = original; parts[damage][110] ^= 1
            let s = try Sandbox(); let result = try s.run(Fixture.archive(parts, count: 2))
            XCTAssertNotEqual(result.0, 0)
            let listing = try Sandbox().run(Fixture.archive(parts, count: 2), ["--list"])
            for (index, byte, trusted) in [(2,UInt8(1),"outer/inner/same"), (4,UInt8(2),"outer/same"), (6,UInt8(3),"same")] {
                let offset = 22 + parts.prefix(index).reduce(0, { $0 + $1.count })
                let path = index > damage ? ".unsit-recovery-\(offset)/same" : trusted
                XCTAssertEqual(try s.bytes(path), [byte])
                if index > damage { XCTAssertTrue(listing.1.contains(path), listing.1) }
            }
        }
    }
    func testAppendedEntriesAndUnverifiedCountVersion() throws {
        let first = Fixture.member("first", data: [1])
        let s = try Sandbox()
        XCTAssertNotEqual(try s.run(Fixture.archive([first, Fixture.member("appended", data: [2])], count: 1, total: 22 + first.count)).0, 0)
        XCTAssertEqual(try s.bytes("first"), [1]); XCTAssertFalse(FileManager.default.fileExists(atPath: s.out.appendingPathComponent("appended").path))
        var bytes = Fixture.archive([first]); bytes[14] = 2
        let result = try Sandbox().run(bytes, ["--list"])
        XCTAssertNotEqual(result.0, 0); XCTAssertTrue(result.2.contains("count validation SKIPPED"))
    }
}
