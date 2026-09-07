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

    static func writeFile(in parent: OutputDirectory, name: String, entry: SITEntry, dataFork: [UInt8], resourceFork: [UInt8]) throws {
        try validate(name)
        let fd = openat(parent.fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw failure("create file (existing output preserved)", name) }
        defer { _ = close(fd) }
        try dataFork.withUnsafeBytes { buf in
            var offset = 0
            while offset < buf.count {
                let n = Darwin.write(fd, buf.baseAddress!.advanced(by: offset), buf.count - offset)
                guard n > 0 else { throw failure("write data fork", name) }
                offset += n
            }
        }
        if !resourceFork.isEmpty {
            let result = resourceFork.withUnsafeBytes { fsetxattr(fd, "com.apple.ResourceFork", $0.baseAddress, $0.count, 0, 0) }
            guard result == 0 else { throw failure("write resource fork", name) }
        }
        setMetadata(fd: fd, entry: entry)
    }

    static func createDirectory(in parent: OutputDirectory, name: String, entry: SITEntry) throws -> OutputDirectory {
        let dir = try parent.create(name)
        setMetadata(fd: dir.fd, entry: entry, isDirectory: true)
        return dir
    }

    static func setMetadata(fd: Int32, entry: SITEntry, isDirectory: Bool = false) {
        var info = [UInt8](repeating: 0, count: 32)
        if !isDirectory {
            info.replaceSubrange(0..<4, with: entry.type)
            info.replaceSubrange(4..<8, with: entry.creator)
        }
        info[8] = UInt8(entry.finderFlags >> 8); info[9] = UInt8(entry.finderFlags & 255)
        _ = info.withUnsafeBytes { fsetxattr(fd, "com.apple.FinderInfo", $0.baseAddress, 32, 0, 0) }
        setModificationDate(fd: fd, macDate: entry.modificationDate)
    }

    static func setModificationDate(fd: Int32, macDate: UInt32) {
        guard macDate != 0 else { return }
        let unix = Int64(macDate) - macEpochOffset
        guard unix > 0 else { return }
        let tv = timeval(tv_sec: Int(unix), tv_usec: 0)
        var times = [tv, tv]
        _ = futimes(fd, &times)
    }
}
