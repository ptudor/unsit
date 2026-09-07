import Foundation
import XCTest
@testable import unsit

enum Fixture {
    static func crc(_ bytes: [UInt8]) -> UInt16 {
        var c: UInt16 = 0
        for byte in bytes {
            c ^= UInt16(byte)
            for _ in 0..<8 { c = (c >> 1) ^ (c & 1 == 1 ? 0xa001 : 0) }
        }
        return c
    }
    static func put(_ value: Int, in bytes: inout [UInt8], at: Int, width: Int) {
        for i in 0..<width { bytes[at+i] = UInt8(truncatingIfNeeded: value >> (8*(width-i-1))) }
    }
    static func member(_ name: String = "f", data: [UInt8] = [], rsrc: [UInt8] = [],
                       rm: UInt8 = 0, dm: UInt8 = 0, du: Int? = nil, ru: Int? = nil,
                       dc: Int? = nil, rc: Int? = nil, dataCRC: UInt16? = nil,
                       mod: UInt32 = 3_000_000_000, nameLength: Int? = nil) -> [UInt8] {
        let raw = Array(name.data(using: .macOSRoman)!)
        var h = [UInt8](repeating: 0, count: 112)
        h[0] = rm; h[1] = dm; h[2] = UInt8(nameLength ?? raw.count)
        for (i, b) in raw.prefix(31).enumerated() { h[3+i] = b }
        h.replaceSubrange(66..<74, with: Array("TEXTttxt".utf8))
        put(Int(mod), in: &h, at: 76, width: 4); put(Int(mod), in: &h, at: 80, width: 4)
        for (offset, value) in [(84, ru ?? rsrc.count), (88, du ?? data.count),
                                (92, rc ?? rsrc.count), (96, dc ?? data.count)] {
            put(value, in: &h, at: offset, width: 4)
        }
        put(Int(crc(rsrc)), in: &h, at: 100, width: 2)
        put(Int(dataCRC ?? crc(data)), in: &h, at: 102, width: 2)
        put(Int(crc(Array(h.prefix(110)))), in: &h, at: 110, width: 2)
        return h + rsrc + data
    }
    static func archive(_ parts: [[UInt8]], count: Int? = nil, total: Int? = nil) -> [UInt8] {
        let body = parts.flatMap { $0 }
        var h = Array("SIT!".utf8) + [UInt8](repeating: 0, count: 18)
        put(count ?? parts.count, in: &h, at: 4, width: 2)
        put(total ?? (22 + body.count), in: &h, at: 6, width: 4)
        h.replaceSubrange(10..<14, with: Array("rLau".utf8)); h[14] = 1
        return h + body
    }
    static func golden(_ name: String) throws -> [UInt8] {
        Array(try Data(contentsOf: Bundle.module.url(forResource: name, withExtension: "sit", subdirectory: "Fixtures")!))
    }
}

final class Sandbox {
    let root: URL
    let out: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("unsit-test-" + UUID().uuidString)
        out = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func run(_ bytes: [UInt8], _ flags: [String] = []) throws -> (Int32, String, String) {
        try Data(bytes).write(to: root.appendingPathComponent("input.sit"))
        return try command(flags + ["input.sit", "out"])
    }
    func command(_ args: [String]) throws -> (Int32, String, String) {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["UNSIT_TEST_BINARY"] ?? repo.appendingPathComponent(".build/debug/unsit").path)
        p.arguments = args; p.currentDirectoryURL = root
        let stdout = root.appendingPathComponent("stdout"), stderr = root.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdout.path, contents: nil)
        FileManager.default.createFile(atPath: stderr.path, contents: nil)
        let o = try FileHandle(forWritingTo: stdout), e = try FileHandle(forWritingTo: stderr)
        defer { try? o.close(); try? e.close() }
        p.standardOutput = o; p.standardError = e
        try p.run(); p.waitUntilExit()
        return (p.terminationStatus, try String(contentsOf: stdout), try String(contentsOf: stderr))
    }
    func bytes(_ name: String) throws -> [UInt8] { Array(try Data(contentsOf: out.appendingPathComponent(name))) }
}
