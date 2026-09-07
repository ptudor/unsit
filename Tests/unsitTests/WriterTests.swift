import Foundation
import XCTest
@testable import unsit

final class WriterTests: XCTestCase {
    func testWriteInterruptShortWritesAndChunkCaps() throws {
        let s = try Sandbox(), entry = try Fixture.decodedEntry()
        let parent = OutputDirectory(fd: open(s.out.path, O_RDONLY | O_DIRECTORY))
        let bytes = [UInt8](repeating: 65, count: MacFileWriter.chunkSize * 2 + 7)
        var io = WriterIO(), calls = 0, sizes: [Int] = [], resourceSizes: [Int] = []
        io.write = { fd, ptr, count in
            calls += 1; sizes.append(count)
            if calls == 1 { errno = EINTR; return -1 }
            return Darwin.write(fd, ptr, min(13, count))
        }
        var resourceCalls = 0
        io.xattr = { fd, name, ptr, count, offset in
            if name == "com.apple.ResourceFork" {
                resourceSizes.append(count); resourceCalls += 1
                if resourceCalls == 1 { errno = EINTR; return -1 }
            }
            return fsetxattr(fd, name, ptr, count, offset, 0)
        }
        let result = try MacFileWriter.writeFile(in: parent, name: "f", entry: entry, dataFork: bytes, resourceFork: bytes, io: io)
        XCTAssertTrue(result.complete, result.diagnostics.joined(separator: ";"))
        XCTAssertEqual(try s.bytes("f"), bytes); XCTAssertEqual(try s.bytes("f/..namedfork/rsrc"), bytes)
        XCTAssertLessThanOrEqual(sizes.max()!, MacFileWriter.chunkSize)
        XCTAssertLessThanOrEqual(resourceSizes.max()!, MacFileWriter.chunkSize)
    }
    func testTransactionFaultsPreserveOriginalAndMarkPartial() throws {
        for fault in ["create", "zero", "space", "resource", "resourcePartial", "close", "flush", "finder", "date", "rename"] {
            let s = try Sandbox(), entry = try Fixture.decodedEntry()
            try Data("ORIGINAL".utf8).write(to: s.out.appendingPathComponent("f"))
            try Data("OLD_RESOURCE".utf8).write(to: s.out.appendingPathComponent("f/..namedfork/rsrc"))
            let parent = OutputDirectory(fd: open(s.out.path, O_RDONLY | O_DIRECTORY))
            var io = WriterIO(), closeCalls = 0
            if fault == "create" { io.create = { _,_ in errno = EACCES; return -1 } }
            if fault == "zero" { io.write = { _,_,_ in 0 } }
            if fault == "space" { io.write = { _,_,_ in errno = ENOSPC; return -1 } }
            io.close = { fd in closeCalls += 1; let r = Darwin.close(fd); if fault == "close" { errno = EIO; return -1 }; return r }
            if fault == "flush" { io.flush = { _ in errno = EIO; return -1 } }
            if fault == "date" { io.times = { _,_ in errno = EPERM; return -1 } }
            io.xattr = { fd, name, ptr, count, offset in
                if name == "com.apple.ResourceFork" && (fault == "resource" || fault == "resourcePartial") {
                    if fault == "resourcePartial" { _ = fsetxattr(fd, name, ptr, 1, 0, 0) }
                    errno = fault == "resource" ? ENOTSUP : ENOSPC; return -1
                }
                if name == "com.apple.FinderInfo" && fault == "finder" { errno = ENOTSUP; return -1 }
                return fsetxattr(fd, name, ptr, count, offset, 0)
            }
            if fault == "rename" { io.publish = { _,_,_ in errno = EIO; return -1 } }
            do {
                let result = try MacFileWriter.writeFile(in: parent, name: "f", entry: entry, dataFork: Array("NEW_DATA".utf8), resourceFork: Array("RSRC".utf8), io: io)
                XCTAssertFalse(result.complete, fault); XCTAssertEqual(result.name, "f.partial-22")
                XCTAssertFalse(result.diagnostics.isEmpty)
                if !["zero", "space"].contains(fault) { XCTAssertEqual(try s.bytes(result.name), Array("NEW_DATA".utf8)) }
                if fault == "resourcePartial" { XCTAssertEqual(try s.bytes(result.name + "/..namedfork/rsrc"), [82]) }
                if fault == "finder" {
                    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: s.out.appendingPathComponent(result.name).path)[.modificationDate] as? Date, Date(timeIntervalSince1970: 917155200))
                }
            } catch { XCTAssertTrue(["create", "rename"].contains(fault), "\(fault): \(error)") }
            XCTAssertEqual(closeCalls, fault == "create" ? 0 : 1)
            XCTAssertEqual(try s.bytes("f"), Array("ORIGINAL".utf8))
            XCTAssertEqual(try s.bytes("f/..namedfork/rsrc"), Array("OLD_RESOURCE".utf8))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: s.out.path).contains(where: { $0.hasPrefix(".unsit-tmp-") }))
        }
    }
    func testDirectoryMetadataIndependentFailuresAndNativeLayout() throws {
        let s = try Sandbox(); var entry = try Fixture.decodedEntry()
        entry.finderFlags = 0x4000
        let fd = open(s.out.path, O_RDONLY | O_DIRECTORY); defer { close(fd) }
        var io = WriterIO(); io.xattr = { _,_,_,_,_ in errno = ENOTSUP; return -1 }
        let issues = MacFileWriter.setMetadata(fd: fd, entry: entry, isDirectory: true, io: io)
        XCTAssertEqual(issues.count, 1); XCTAssertTrue(issues[0].contains("FinderInfo"))
        var st = stat(); XCTAssertEqual(fstat(fd, &st), 0); XCTAssertEqual(st.st_mtimespec.tv_sec, 917155200)
        io = WriterIO(); io.times = { _,_ in errno = EPERM; return -1 }
        XCTAssertTrue(MacFileWriter.setMetadata(fd: fd, entry: entry, isDirectory: true, io: io).first!.contains("modification date"))
        var info = [UInt8](repeating: 0, count: 32)
        XCTAssertEqual(fgetxattr(fd, "com.apple.FinderInfo", &info, 32, 0, 0), 32)
        XCTAssertEqual(Array(info.prefix(8)), [UInt8](repeating: 0, count: 8)); XCTAssertEqual(info[8], 0x40)
    }
    func testIndependentForkRecoveryAndPartialPrefixes() throws {
        for (data,rsrc,dm,rm) in [([71,79,79,68],[0x60],0,13), ([0x60],[71,79,79,68],13,0), ([0x60],[0x60],13,13)] {
            let s = try Sandbox()
            let parts = [Fixture.member(data: data.map(UInt8.init), rsrc: rsrc.map(UInt8.init), rm: UInt8(rm), dm: UInt8(dm)), Fixture.member("later", data: [9])]
            let result = try s.run(Fixture.archive(parts))
            XCTAssertNotEqual(result.0, 0); XCTAssertEqual(try s.bytes("later"), [9])
            if dm == 0 { XCTAssertEqual(try s.bytes("f.partial-22"), Array("GOOD".utf8)) }
            if rm == 0 { XCTAssertEqual(try s.bytes("f.partial-22/..namedfork/rsrc"), Array("GOOD".utf8)) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: s.out.appendingPathComponent("f").path))
        }
        var bits = Bits(); for _ in 0..<4 { bits.code(65, StuffIt13Tables.firstCodeLengths[0]) }
        let s = try Sandbox()
        let result = try s.run(Fixture.archive([Fixture.member(data: [0x10] + bits.bytes, dm: 13, du: 100)]))
        XCTAssertNotEqual(result.0, 0); XCTAssertEqual(try s.bytes("f.partial-22"), [65,65,65,65])
    }
}

extension WriterTests {
    func interposer(in s: Sandbox) throws -> URL {
        let source = Bundle.module.url(forResource: "fault-interposer", withExtension: "c", subdirectory: "Fixtures")!
        let library = s.root.appendingPathComponent("fault.dylib")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        p.arguments = ["-dynamiclib", source.path, "-o", library.path]
        try p.run(); p.waitUntilExit(); XCTAssertEqual(p.terminationStatus, 0)
        return library
    }
    func testCLIQuietFaultStatusAndInterruptedTransaction() throws {
        let s = try Sandbox(), lib = try interposer(in: s)
        let archive = Fixture.archive([Fixture.member(data: Array("NEW_DATA".utf8), rsrc: Array("RSRC".utf8))])
        try Data(archive).write(to: s.root.appendingPathComponent("input.sit"))
        try Data("ORIGINAL".utf8).write(to: s.out.appendingPathComponent("f"))
        try Data("OLD_RESOURCE".utf8).write(to: s.out.appendingPathComponent("f/..namedfork/rsrc"))
        for fault in ["resource", "finder", "date", "close"] {
            let destination = "out-" + fault
            let result = try s.command(["--quiet", "input.sit", destination], environment: ["DYLD_INSERT_LIBRARIES": lib.path, "UNSIT_TEST_FAULT": fault])
            XCTAssertNotEqual(result.0, 0); XCTAssertTrue(result.2.contains("partial"), result.2)
            XCTAssertFalse(FileManager.default.fileExists(atPath: s.root.appendingPathComponent(destination + "/f").path))
        }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process(); process.executableURL = repo.appendingPathComponent(".build/debug/unsit")
        process.currentDirectoryURL = s.root; process.arguments = ["input.sit", "out"]
        process.environment = ProcessInfo.processInfo.environment.merging(["DYLD_INSERT_LIBRARIES": lib.path, "UNSIT_TEST_FAULT": "stop_resource"], uniquingKeysWith: { _,n in n })
        try process.run()
        defer { if process.isRunning { _ = kill(process.processIdentifier, SIGKILL); process.waitUntilExit() } }
        let deadline = Date().addingTimeInterval(5)
        var status: Int32 = 0, stopped = false
        while Date() < deadline {
            if waitpid(process.processIdentifier, &status, WUNTRACED | WNOHANG) > 0 && (status & 0xff) == 0x7f { stopped = true; break }
            usleep(10_000)
        }
        XCTAssertTrue(stopped, "fault interposer must stop the child before resource writes")
        XCTAssertEqual(try s.bytes("f"), Array("ORIGINAL".utf8)); XCTAssertEqual(try s.bytes("f/..namedfork/rsrc"), Array("OLD_RESOURCE".utf8))
        _ = kill(process.processIdentifier, SIGKILL); process.waitUntilExit()
        let names = try FileManager.default.contentsOfDirectory(atPath: s.out.path)
        XCTAssertEqual(names.filter { $0.hasPrefix(".unsit-tmp-") }.count, 1)
        XCTAssertFalse(names.contains("f.partial-22"))
    }
}

extension WriterTests {
    func testTruncatedForkExtentsKeepAvailableBytes() throws {
        var bits = Bits(); for _ in 0..<4 { bits.code(65, StuffIt13Tables.firstCodeLengths[0]) }
        for member in [Fixture.member(data: [1,2,3], du: 5, dc: 5), Fixture.member(data: [0x10] + bits.bytes, dm: 13, du: 100, dc: 100)] {
            let s = try Sandbox(); let result = try s.run(Fixture.archive([member]), ["--no-verify"])
            XCTAssertNotEqual(result.0, 0)
            XCTAssertEqual(try s.bytes("f.partial-22"), member[1] == 0 ? [1,2,3] : [65,65,65,65])
        }
    }
}
