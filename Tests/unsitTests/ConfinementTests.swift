import Foundation
import XCTest
@testable import unsit

final class ConfinementTests: XCTestCase {
    func testUnsafeFoldersAndLaterSibling() throws {
        for name in ["..", ".", "", "\0", "..\0"] {
            for flags in [[], ["--no-verify"]] {
                let s = try Sandbox()
                let sentinel = s.root.appendingPathComponent("sentinel")
                try Data("ORIGINAL".utf8).write(to: sentinel)
                let before = try FileManager.default.attributesOfItem(atPath: sentinel.path)
                let parts = [Fixture.member(name, rm: 32, dm: 32), Fixture.member("escaped", data: [1]),
                             Fixture.member(name, rm: 33, dm: 33), Fixture.member("later", data: [2])]
                let result = try s.run(Fixture.archive(parts), flags)
                XCTAssertNotEqual(result.0, 0)
                XCTAssertTrue(result.2.contains("unsafe"), result.2)
                XCTAssertFalse(FileManager.default.fileExists(atPath: s.root.appendingPathComponent("escaped").path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: s.out.appendingPathComponent("escaped").path))
                XCTAssertEqual(try s.bytes("later"), [2])
                XCTAssertEqual(try Data(contentsOf: sentinel), Data("ORIGINAL".utf8))
                XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: sentinel.path)[.modificationDate] as? Date, before[.modificationDate] as? Date)
            }
        }
    }
    func testDirectorySymlinkAndRootSymlinkRejected() throws {
        let s = try Sandbox()
        let external = s.root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        let before = try FileManager.default.attributesOfItem(atPath: external.path)[.modificationDate] as? Date
        try FileManager.default.createSymbolicLink(atPath: s.out.appendingPathComponent("link").path, withDestinationPath: external.path)
        let result = try s.run(Fixture.archive([Fixture.member("link", rm: 32), Fixture.member("escaped", data: [1]), Fixture.member("link", rm: 33), Fixture.member("later", data: [2])]))
        XCTAssertNotEqual(result.0, 0)
        XCTAssertEqual(try s.bytes("later"), [2])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: external.path), [])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: external.path)[.modificationDate] as? Date, before)
        XCTAssertNotEqual(try s.command(["input.sit", "out/link"]).0, 0)
    }
    func testExistingAndCollidingNamesPreserved() throws {
        for (first, second) in [("f", "f"), ("File", "file"), ("f", "f\0")] {
            let s = try Sandbox()
            let result = try s.run(Fixture.archive([Fixture.member(first, data: [1], rsrc: [2]), Fixture.member(second, data: [3], rsrc: [4])]))
            XCTAssertNotEqual(result.0, 0)
            XCTAssertEqual(try s.bytes(first), [1]); XCTAssertEqual(try s.bytes(first + "/..namedfork/rsrc"), [2])
        }
        for kind in ["file", "symlink", "hardlink", "directory"] {
            let s = try Sandbox()
            let original = s.root.appendingPathComponent("original")
            try Data([7,8]).write(to: original)
            let dest = s.out.appendingPathComponent("f")
            if kind == "file" { try Data([7,8]).write(to: dest) }
            if kind == "symlink" { try FileManager.default.createSymbolicLink(at: dest, withDestinationURL: original) }
            if kind == "hardlink" { try FileManager.default.linkItem(at: original, to: dest) }
            if kind == "directory" { try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false) }
            XCTAssertNotEqual(try s.run(Fixture.archive([Fixture.member(data: [1])])).0, 0)
            XCTAssertEqual(try Data(contentsOf: original), Data([7,8]))
            if kind != "directory" { XCTAssertEqual(try s.bytes("f"), [7,8]) }
        }
    }
}

extension ConfinementTests {
    func testAcquiredDirectorySurvivesAncestorSwap() throws {
        let s = try Sandbox()
        let resolved = realpath(s.out.path, nil)!
        defer { free(resolved) }
        let parent = try OutputDirectory.root(String(cString: resolved))
        let dir = try parent.create("dir")
        let external = s.root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        try FileManager.default.moveItem(at: s.out.appendingPathComponent("dir"), to: s.out.appendingPathComponent("held"))
        try FileManager.default.createSymbolicLink(at: s.out.appendingPathComponent("dir"), withDestinationURL: external)
        let archive = try SITArchive(data: Fixture.archive([Fixture.member(data: [1], rsrc: [2])]))
        try archive.forEachEntry(onResync: { _, _ in }) { e in
            try MacFileWriter.writeFile(in: dir, name: e.name, entry: e, dataFork: [1], resourceFork: [2])
        }
        XCTAssertEqual(try s.bytes("held/f"), [1]); XCTAssertEqual(try s.bytes("held/f/..namedfork/rsrc"), [2])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: external.path), [])
    }
    func testFolderCollisionsAndInputArchiveProtection() throws {
        let s = try Sandbox()
        let parts = [Fixture.member("dir", rm: 32), Fixture.member("first", data: [1]), Fixture.member("dir", rm: 33),
                     Fixture.member("dir", rm: 32), Fixture.member("second", data: [2]), Fixture.member("dir", rm: 33)]
        XCTAssertNotEqual(try s.run(Fixture.archive(parts)).0, 0)
        XCTAssertEqual(try s.bytes("dir/first"), [1])
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.out.appendingPathComponent("dir/second").path))
        let bytes = Fixture.archive([Fixture.member("input.sit", data: [9])])
        try Data(bytes).write(to: s.root.appendingPathComponent("input.sit"))
        XCTAssertNotEqual(try s.command(["input.sit", "."]).0, 0)
        XCTAssertEqual(try Data(contentsOf: s.root.appendingPathComponent("input.sit")), Data(bytes))
    }
    func testFilesystemUnicodeEquivalence() throws {
        let s = try Sandbox()
        try Data([7]).write(to: s.out.appendingPathComponent("e\u{301}"))
        let result = try s.run(Fixture.archive([Fixture.member("é", data: [8])]))
        XCTAssertNotEqual(result.0, 0)
        XCTAssertEqual(try s.bytes("e\u{301}"), [7])
    }
}
