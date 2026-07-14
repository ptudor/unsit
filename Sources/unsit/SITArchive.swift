import Foundation

enum SITError: Error, CustomStringConvertible {
    case notAStuffItArchive
    case truncated

    var description: String {
        switch self {
        case .notAStuffItArchive: return "not a classic StuffIt (SIT!) archive"
        case .truncated: return "archive is truncated"
        }
    }
}

/// One decoded archive member.
struct SITEntry {
    enum Kind { case file, folderStart, folderEnd }
    var kind: Kind
    var name: String                 // decoded, path-separator-safe
    var rawName: [UInt8]             // original Mac Roman bytes
    var type: [UInt8]               // 4-byte OSType
    var creator: [UInt8]            // 4-byte OSType
    var finderFlags: UInt16
    var creationDate: UInt32        // Mac (1904) epoch seconds
    var modificationDate: UInt32
    var offset: Int                 // header offset in file (for diagnostics)

    var rsrcMethod: UInt8
    var dataMethod: UInt8
    var rsrcUncompressedLength: Int
    var dataUncompressedLength: Int
    var rsrcCompressedLength: Int
    var dataCompressedLength: Int
    var rsrcCRC: UInt16
    var dataCRC: UInt16

    // Absolute file offsets of the compressed fork bytes (resource then data).
    var rsrcOffset: Int
    var dataOffset: Int
}

/// Parser for the classic StuffIt container ("SIT!" / "rLau").
///
/// Layout (all multi-byte fields big-endian), verified against the sample
/// archives via the per-header CRC-16/ARC:
///   Archive header: 22 bytes — "SIT!", numFiles(u16), archiveLength(u32),
///                   "rLau", 8 reserved bytes.
///   Each entry: 112-byte header (CRC-16/ARC of bytes 0..109 stored at 110),
///   followed, for files, by the compressed resource fork then the compressed
///   data fork. Folders are marked by method byte 0x20 (start) / 0x21 (end)
///   and carry no fork payload.
struct SITArchive {
    static let headerSize = 22
    static let entryHeaderSize = 112
    static let folderStart: UInt8 = 0x20
    static let folderEnd: UInt8 = 0x21

    let data: [UInt8]
    let numFiles: Int

    init(data: [UInt8]) throws {
        guard data.count >= Self.headerSize,
              data[0] == 0x53, data[1] == 0x49, data[2] == 0x54, data[3] == 0x21 else { // "SIT!"
            throw SITError.notAStuffItArchive
        }
        self.data = data
        self.numFiles = Int(data[4]) << 8 | Int(data[5])
    }

    private func u16(_ o: Int) -> UInt16 { UInt16(data[o]) << 8 | UInt16(data[o + 1]) }
    private func u32(_ o: Int) -> Int {
        Int(data[o]) << 24 | Int(data[o + 1]) << 16 | Int(data[o + 2]) << 8 | Int(data[o + 3])
    }

    /// True if a valid 112-byte entry header (matching its stored CRC) begins at `o`.
    func isValidHeader(at o: Int) -> Bool {
        guard o >= 0, o + Self.entryHeaderSize <= data.count else { return false }
        let stored = u16(o + 110)
        return CRC16.checksum(data[o..<(o + 110)]) == stored
    }

    private func decodeName(_ o: Int, _ nl: Int) -> (String, [UInt8]) {
        let n = min(nl, 31)
        let raw = Array(data[(o + 3)..<(o + 3 + n)])
        var s = String(bytes: raw, encoding: .macOSRoman) ?? String(decoding: raw, as: UTF8.self)
        // A Mac filename may contain "/", which is the path separator on the
        // POSIX layer. Map it to ":" — Finder displays ":" as "/", round-tripping
        // the original name. Strip embedded NULs.
        s = s.replacingOccurrences(of: "/", with: ":")
        s = s.replacingOccurrences(of: "\u{0}", with: "")
        return (s, raw)
    }

    private func entry(at o: Int) -> SITEntry {
        let rm = data[o], dm = data[o + 1], nl = Int(data[o + 2])
        let (name, raw) = decodeName(o, nl)
        let kind: SITEntry.Kind
        if rm == Self.folderStart || dm == Self.folderStart { kind = .folderStart }
        else if rm == Self.folderEnd || dm == Self.folderEnd { kind = .folderEnd }
        else { kind = .file }

        let rC = u32(o + 92), dC = u32(o + 96)
        return SITEntry(
            kind: kind,
            name: name,
            rawName: raw,
            type: Array(data[(o + 66)..<(o + 70)]),
            creator: Array(data[(o + 70)..<(o + 74)]),
            finderFlags: u16(o + 74),
            creationDate: UInt32(bitPattern: Int32(truncatingIfNeeded: u32(o + 76))),
            modificationDate: UInt32(bitPattern: Int32(truncatingIfNeeded: u32(o + 80))),
            offset: o,
            rsrcMethod: rm,
            dataMethod: dm,
            rsrcUncompressedLength: u32(o + 84),
            dataUncompressedLength: u32(o + 88),
            rsrcCompressedLength: rC,
            dataCompressedLength: dC,
            rsrcCRC: u16(o + 100),
            dataCRC: u16(o + 102),
            rsrcOffset: o + Self.entryHeaderSize,
            dataOffset: o + Self.entryHeaderSize + rC
        )
    }

    /// Walk the archive, yielding entries in order. Uses the header CRC to
    /// validate each position; on a mismatch (e.g. the isolated stray-fork
    /// anomaly observed in one sample), it resyncs forward to the next valid
    /// header and reports the number of skipped bytes via `onResync`.
    func forEachEntry(onResync: (Int, Int) -> Void, _ body: (SITEntry) throws -> Void) throws {
        var pos = Self.headerSize
        while pos + Self.entryHeaderSize <= data.count {
            if !isValidHeader(at: pos) {
                // Resync: scan forward for the next CRC-valid header.
                var scan = pos + 1
                while scan + Self.entryHeaderSize <= data.count && !isValidHeader(at: scan) {
                    scan += 1
                }
                if scan + Self.entryHeaderSize > data.count { break } // no more headers
                onResync(pos, scan - pos)
                pos = scan
                continue
            }
            let e = entry(at: pos)
            try body(e)
            switch e.kind {
            case .folderStart, .folderEnd:
                pos += Self.entryHeaderSize
            case .file:
                pos += Self.entryHeaderSize + e.rsrcCompressedLength + e.dataCompressedLength
            }
        }
    }

    /// Decompress a fork given its method, compressed byte range and expected
    /// uncompressed length. Only methods 0 (stored) and 13 are present in the
    /// classic archives targeted here.
    func decompressFork(method: UInt8, offset: Int, compressedLength: Int, uncompressedLength: Int) throws -> [UInt8] {
        guard compressedLength >= 0, offset + compressedLength <= data.count else {
            throw SITError.truncated
        }
        let slice = Array(data[offset..<(offset + compressedLength)])
        switch method {
        case 0:
            return slice
        case 13:
            var dec = try StuffIt13(slice)
            return try dec.decompress(expectedLength: uncompressedLength)
        default:
            throw ExtractError.unsupportedMethod(method)
        }
    }
}

enum ExtractError: Error, CustomStringConvertible {
    case unsupportedMethod(UInt8)
    var description: String {
        switch self {
        case .unsupportedMethod(let m): return "unsupported compression method \(m)"
        }
    }
}
