import Foundation
import Darwin

struct Limits {
    var inputBytes = 256 * 1024 * 1024
    var forkBytes = 64 * 1024 * 1024
    var totalBytes = 512 * 1024 * 1024
    var members = 100_000
    var depth = 128
    var recoveryBytes = 1024 * 1024

    static func check(_ amount: Int, _ limit: Int, _ label: String) throws {
        guard amount >= 0, amount <= limit else {
            throw MacFileWriter.WriteError(description: "resource limit exceeded: \(label) (\(amount) > \(limit))")
        }
    }
    // Bounded reads on the same descriptor avoid both eager unbounded loading
    // and SIGBUS if an externally mutable memory-mapped input is truncated.
    func readInput(_ path: String) throws -> Data {
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw MacFileWriter.failure("open input", path) }
        defer { _ = close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else {
            throw MacFileWriter.WriteError(description: "input must be a regular file: \(path)")
        }
        try Self.check(Int(st.st_size), inputBytes, "input bytes")
        var result = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 {
                let code = errno
                if code == EINTR { continue }
                throw MacFileWriter.failure("read input", path, code)
            }
            if n == 0 { return result }
            try Self.check(n, inputBytes - result.count, "input bytes remaining")
            result.append(contentsOf: chunk.prefix(n))
        }
    }
}

final class OutputBudget {
    let limits: Limits
    private(set) var used = 0
    init(_ limits: Limits) { self.limits = limits }
    func reserve(_ entry: SITEntry) throws {
        // Stored contradictions may return more bytes than advertised. Account
        // for those bytes too, before either fork is allocated or written.
        let r = max(entry.rsrcUncompressedLength, entry.rsrcMethod == 0 ? entry.rsrcCompressedLength : 0)
        let d = max(entry.dataUncompressedLength, entry.dataMethod == 0 ? entry.dataCompressedLength : 0)
        try Limits.check(r, limits.forkBytes, "resource fork bytes")
        try Limits.check(d, limits.forkBytes, "data fork bytes")
        try Limits.check(r, limits.totalBytes - used, "aggregate bytes remaining")
        try Limits.check(d, limits.totalBytes - used - r, "aggregate bytes remaining")
        used += r + d
    }
}
