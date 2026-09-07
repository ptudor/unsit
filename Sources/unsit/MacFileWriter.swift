import Foundation
import Darwin

/// All member operations use a single validated component and an owned parent
/// descriptor. No member pathname is resolved again for fork or metadata writes.
final class OutputDirectory {
    let fd: Int32
    init(fd: Int32) { self.fd = fd }
    deinit { _ = close(fd) }

    static func root(_ path: String) throws -> OutputDirectory {
        var current = OutputDirectory(fd: open(path.hasPrefix("/") ? "/" : ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC))
        guard current.fd >= 0 else { throw MacFileWriter.failure("open output root", path) }
        // User-supplied root paths may include . and ..; archive components may not.
        for part in path.split(separator: "/").map(String.init) {
            if mkdirat(current.fd, part, 0o755) != 0 && errno != EEXIST {
                throw MacFileWriter.failure("create output root", part)
            }
            let next = openat(current.fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw MacFileWriter.failure("open output root (symlinks rejected)", part) }
            current = OutputDirectory(fd: next)
        }
        return current
    }

    func create(_ name: String) throws -> OutputDirectory {
        try MacFileWriter.validate(name)
        guard mkdirat(fd, name, 0o755) == 0 else { throw MacFileWriter.failure("create directory (existing output preserved)", name) }
        let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw MacFileWriter.failure("open directory", name) }
        return OutputDirectory(fd: child)
    }
}

enum MacFileWriter {
    static let macEpochOffset: Int64 = 2_082_844_800
    struct WriteError: Error, CustomStringConvertible {
        let description: String
    }
    static func failure(_ operation: String, _ name: String, _ code: Int32 = errno) -> WriteError {
        WriteError(description: "\(operation) \(name): \(String(cString: strerror(code))) (errno \(code))")
    }
    static func validate(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw WriteError(description: "unsafe member component \(String(reflecting: name))")
        }
    }

    static let chunkSize = 64 * 1024
    struct WriteOutcome {
        let name: String
        let diagnostics: [String]
        var complete: Bool { diagnostics.isEmpty }
    }

    /// Build both native forks on one descriptor. RENAME_EXCL publishes the
    /// complete inode atomically, never replacing existing files or symlinks.
    @discardableResult
    static func writeFile(in parent: OutputDirectory, name: String, entry: SITEntry,
                          dataFork: [UInt8], resourceFork: [UInt8],
                          diagnostics: [String] = [], io: WriterIO = WriterIO()) throws -> WriteOutcome {
        try validate(name)
        let temporary = ".unsit-tmp-" + UUID().uuidString
        let fd = io.create(parent.fd, temporary)
        guard fd >= 0 else { throw failure("create temporary file", name, errno) }
        var closed = false
        var published = false
        defer {
            if !closed { _ = io.close(fd) }
            if !published { _ = unlinkat(parent.fd, temporary, 0) }
        }
        var issues = diagnostics
        io.stage("created")
        do { try writeData(fd: fd, name: name, bytes: dataFork, io: io) }
        catch { issues.append(String(describing: error)) }
        io.stage("data")
        do { try writeResource(fd: fd, name: name, bytes: resourceFork, io: io) }
        catch { issues.append(String(describing: error)) }
        io.stage("resource")
        issues += setMetadata(fd: fd, entry: entry, io: io)
        io.stage("metadata")
        if io.flush(fd) != 0 { let code = errno; issues.append(failure("flush member", name, code).description) }
        io.stage("flushed")
        // Never retry close, including EINTR: descriptor ownership ends here.
        closed = true
        if io.close(fd) != 0 { let code = errno; issues.append(failure("close member", name, code).description) }
        io.stage("closed")
        let finalName = issues.isEmpty ? name : name + ".partial-\(entry.offset)"
        try validate(finalName)
        guard io.publish(parent.fd, temporary, finalName) == 0 else {
            let code = errno
            throw WriteError(description: (issues + [failure("publish (existing output preserved)", finalName, code).description]).joined(separator: "; "))
        }
        published = true
        return WriteOutcome(name: finalName, diagnostics: issues)
    }

    static func writeData(fd: Int32, name: String, bytes: [UInt8], io: WriterIO) throws {
        try bytes.withUnsafeBytes { buf in
            var offset = 0
            while offset < buf.count {
                let count = min(chunkSize, buf.count - offset)
                let n = io.write(fd, buf.baseAddress!.advanced(by: offset), count)
                if n < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    throw failure("write data fork", name, code)
                }
                guard n > 0, n <= count else { throw WriteError(description: "zero progress/short write to \(name)") }
                offset += n
            }
        }
    }

    static func writeResource(fd: Int32, name: String, bytes: [UInt8], io: WriterIO) throws {
        try bytes.withUnsafeBytes { buf in
            var offset = 0
            while offset < buf.count {
                let count = min(chunkSize, buf.count - offset)
                // ResourceFork is the macOS xattr supporting positional I/O.
                // Unlike write(), fsetxattr is all-or-error for each request.
                let n = io.xattr(fd, "com.apple.ResourceFork", buf.baseAddress!.advanced(by: offset), count, UInt32(offset))
                if n != 0 {
                    let code = errno
                    if code == EINTR { continue }
                    throw failure("write resource fork", name, code)
                }
                offset += count
            }
        }
    }

    /// Metadata fields are independent: return every failure after attempting
    /// both fields, so useful bytes and successfully restored fields survive.
    static func setMetadata(fd: Int32, entry: SITEntry, isDirectory: Bool = false, io: WriterIO = WriterIO()) -> [String] {
        var issues: [String] = []
        var info = [UInt8](repeating: 0, count: 32)
        if !isDirectory {
            info.replaceSubrange(0..<4, with: entry.type)
            info.replaceSubrange(4..<8, with: entry.creator)
        }
        info[8] = UInt8(entry.finderFlags >> 8); info[9] = UInt8(entry.finderFlags & 255)
        let result = info.withUnsafeBytes { io.xattr(fd, "com.apple.FinderInfo", $0.baseAddress!, 32, 0) }
        if result != 0 { let code = errno; issues.append(failure("restore FinderInfo", entry.name, code).description) }
        if let issue = setModificationDate(fd: fd, macDate: entry.modificationDate, name: entry.name, io: io) { issues.append(issue) }
        return issues
    }

    static func setModificationDate(fd: Int32, macDate: UInt32, name: String, io: WriterIO = WriterIO()) -> String? {
        guard macDate != 0 else { return nil }
        let unix = Int64(macDate) - macEpochOffset
        guard unix > 0 else { return nil }
        let tv = timeval(tv_sec: Int(unix), tv_usec: 0)
        let times = [tv, tv]
        let result = times.withUnsafeBufferPointer { io.times(fd, $0.baseAddress!) }
        if result != 0 { let code = errno; return failure("restore modification date", name, code).description }
        return nil
    }
}
