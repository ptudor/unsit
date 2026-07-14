import Foundation

/// Writes extracted members to disk as native macOS files: the data fork
/// becomes the file's contents, the resource fork is written to the file's
/// `..namedfork/rsrc`, and type/creator/Finder-flags are stored in the
/// `com.apple.FinderInfo` extended attribute. Modification time is restored last.
enum MacFileWriter {
    /// Seconds between the Mac (1904-01-01) and Unix (1970-01-01) epochs.
    static let macEpochOffset: TimeInterval = 2_082_844_800

    enum WriteError: Error, CustomStringConvertible {
        case cannotCreate(String, Int32)
        case cannotWriteResourceFork(String, Int32)
        case shortWrite(String)
        var description: String {
            switch self {
            case .cannotCreate(let p, let e): return "cannot create \(p): \(String(cString: strerror(e)))"
            case .cannotWriteResourceFork(let p, let e): return "cannot write resource fork of \(p): \(String(cString: strerror(e)))"
            case .shortWrite(let p): return "short write to \(p)"
            }
        }
    }

    static func writeFile(at path: String, entry: SITEntry, dataFork: [UInt8], resourceFork: [UInt8]) throws {
        // Data fork → file contents.
        if !FileManager.default.createFile(atPath: path, contents: Data(dataFork)) {
            throw WriteError.cannotCreate(path, errno)
        }

        // Resource fork → named fork (only if non-empty).
        if !resourceFork.isEmpty {
            try writeResourceFork(at: path, bytes: resourceFork)
        }

        setFinderInfo(at: path, type: entry.type, creator: entry.creator, flags: entry.finderFlags)
        setModificationDate(at: path, macDate: entry.modificationDate)
    }

    static func createDirectory(at path: String, entry: SITEntry?) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        if let e = entry {
            // Folders carry Finder flags too; type/creator are not meaningful.
            setFinderInfo(at: path, type: [0, 0, 0, 0], creator: [0, 0, 0, 0], flags: e.finderFlags, isDirectory: true)
            setModificationDate(at: path, macDate: e.modificationDate)
        }
    }

    private static func writeResourceFork(at path: String, bytes: [UInt8]) throws {
        let forkPath = path + "/..namedfork/rsrc"
        let fd = open(forkPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd < 0 { throw WriteError.cannotWriteResourceFork(path, errno) }
        defer { close(fd) }
        var written = 0
        try bytes.withUnsafeBytes { buf in
            while written < bytes.count {
                let n = write(fd, buf.baseAddress!.advanced(by: written), bytes.count - written)
                if n <= 0 { throw WriteError.cannotWriteResourceFork(path, errno) }
                written += n
            }
        }
    }

    /// FinderInfo is 32 bytes: type(4), creator(4), Finder flags(2, big-endian),
    /// then location/folder fields left zero.
    private static func setFinderInfo(at path: String, type: [UInt8], creator: [UInt8], flags: UInt16, isDirectory: Bool = false) {
        // For directories the first 8 bytes are the DInfo frRect (leave zero);
        // only the flags at offset 8 are meaningful. For files, bytes 0..7 hold
        // type and creator.
        var info = [UInt8](repeating: 0, count: 32)
        if !isDirectory {
            for i in 0..<4 { info[i] = type[i] }
            for i in 0..<4 { info[4 + i] = creator[i] }
        }
        info[8] = UInt8(flags >> 8)
        info[9] = UInt8(flags & 0xFF)
        _ = info.withUnsafeBytes { buf in
            setxattr(path, "com.apple.FinderInfo", buf.baseAddress, 32, 0, XATTR_NOFOLLOW)
        }
    }

    private static func setModificationDate(at path: String, macDate: UInt32) {
        guard macDate != 0 else { return }
        let unix = TimeInterval(macDate) - macEpochOffset
        guard unix > 0 else { return }
        let tv = timeval(tv_sec: Int(unix), tv_usec: 0)
        var times = [tv, tv] // access, modification
        _ = utimes(path, &times)
    }
}
