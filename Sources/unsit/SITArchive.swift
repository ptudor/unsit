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
    var hierarchyUncertain = false
    var recoveryDirectory: String { ".unsit-recovery-\(offset)" }
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
///                   "rLau", version(u8), 7 reserved bytes.
///   Each entry: 112-byte header (CRC-16/ARC of bytes 0..109 stored at 110),
///   followed, for files, by the compressed resource fork then the compressed
///   data fork. Folders are marked by method byte 0x20 (start) / 0x21 (end)
///   and carry no fork payload.
struct SITArchive {
    static let headerSize = 22
    static let entryHeaderSize = 112
    static let folderStart: UInt8 = 0x20
    static let folderEnd: UInt8 = 0x21

    let data: Data
    let limits: Limits
    let numFiles: Int
    let extent: Int
    let declaredExtent: Int
    let version: UInt8

    init(data: [UInt8], limits: Limits = Limits()) throws {
        try self.init(data: Data(data), limits: limits)
    }

    init(data: Data, limits: Limits = Limits()) throws {
        try Limits.check(data.count, limits.inputBytes, "input bytes")
        self.limits = limits
        guard data.count >= Self.headerSize,
              data[0] == 0x53, data[1] == 0x49, data[2] == 0x54, data[3] == 0x21,
              Array(data[10..<14]) == Array("rLau".utf8) else { // "SIT!"
            throw SITError.notAStuffItArchive
        }
        self.data = data
        self.numFiles = Int(data[4]) << 8 | Int(data[5])
        self.declaredExtent = Int(data[6]) << 24 | Int(data[7]) << 16 | Int(data[8]) << 8 | Int(data[9])
        guard declaredExtent >= Self.headerSize else { throw SITError.truncated }
        self.extent = min(declaredExtent, data.count)
        self.version = data[14]
    }

    private func u16(_ o: Int) -> UInt16 { UInt16(data[o]) << 8 | UInt16(data[o + 1]) }
    private func u32(_ o: Int) -> Int {
        Int(data[o]) << 24 | Int(data[o + 1]) << 16 | Int(data[o + 2]) << 8 | Int(data[o + 3])
    }

    /// True if a valid 112-byte entry header (matching its stored CRC) begins at `o`.
    func isValidHeader(at o: Int) -> Bool {
        guard o >= 0, o <= extent, Self.entryHeaderSize <= extent - o else { return false }
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
        if (rm & 0x6f) == Self.folderStart || (dm & 0x6f) == Self.folderStart { kind = .folderStart }
        else if (rm & 0x6f) == Self.folderEnd || (dm & 0x6f) == Self.folderEnd { kind = .folderEnd }
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

    struct TraversalReport {
        var diagnostics: [String] = []
        var skippedBytes = 0
        var members = 0
        var complete: Bool { diagnostics.isEmpty }
    }

    /// CRC and structural plausibility are distinct. Recovery candidates must
    /// fit entirely; an ordinary incomplete member can still expose a safe fork.
    private func plausible(at offset: Int, recovery: Bool) -> Bool {
        guard isValidHeader(at: offset), data[offset + 2] <= 31 else { return false }
        let e = entry(at: offset)
        let rm = e.rsrcMethod & 0x6f, dm = e.dataMethod & 0x6f
        guard !((rm == 32 && dm == 33) || (rm == 33 && dm == 32)) else { return false }
        if e.kind != .file {
            guard e.rsrcCompressedLength == 0, e.dataCompressedLength == 0 else { return false }
        } else if e.rawName.isEmpty { return false }
        if recovery {
            if e.kind != .folderEnd, (try? MacFileWriter.validate(e.name)) == nil { return false }
            guard payloadEnd(e) <= extent else { return false }
        }
        return true
    }

    private func payloadEnd(_ e: SITEntry) -> Int {
        // All fields are UInt32 values represented by 64-bit Int on macOS.
        e.kind == .file ? e.dataOffset + e.dataCompressedLength : e.offset + Self.entryHeaderSize
    }

    /// onResync receives invalid start and skipped length, never the recovered
    /// offset. Both CLI consumers compute start + skipped for their diagnostics.
    @discardableResult
    func forEachEntry(onResync: (Int, Int) -> Void, _ body: (SITEntry) throws -> Void) throws -> TraversalReport {
        var report = TraversalReport()
        if declaredExtent != data.count {
            report.diagnostics.append("declared archive extent \(declaredExtent) differs from physical length \(data.count); parsing only 22..\(extent)")
        }
        var pos = Self.headerSize
        var stack: [SITEntry] = []
        var rootMembers = 0
        var uncertain = false
        var recoveryWork = 0
        while pos < extent {
            if !plausible(at: pos, recovery: false) {
                let start = pos
                var scan = pos + 1
                while scan <= extent - Self.entryHeaderSize {
                    recoveryWork += 1
                    try Limits.check(recoveryWork, limits.recoveryBytes, "recovery scan bytes")
                    if plausible(at: scan, recovery: true) { break }
                    scan += 1
                }
                guard scan <= extent - Self.entryHeaderSize else {
                    report.skippedBytes += extent - start
                    report.diagnostics.append("terminal damaged/incomplete header gap \(start)..\(extent); no recovery header found")
                    break
                }
                report.skippedBytes += scan - start
                onResync(start, scan - start)
                let candidate = entry(at: scan)
                let next = payloadEnd(candidate)
                let corroborated = next == extent || plausible(at: next, recovery: true)
                report.diagnostics.append("ambiguous recovery at \(scan): hierarchy uncertain; next boundary \(corroborated ? "corroborated" : "uncorroborated")")
                if !stack.isEmpty {
                    report.diagnostics.append("incomplete folder state at gap \(start); prior folders will not receive recovered children")
                }
                uncertain = true
                stack.removeAll()
                pos = scan
            }
            var e = entry(at: pos)
            e.hierarchyUncertain = uncertain
            report.members += 1
            try Limits.check(report.members, limits.members, "members")
            if e.kind != .folderEnd && stack.isEmpty { rootMembers += 1 }
            switch e.kind {
            case .folderStart:
                try Limits.check(stack.count + 1, limits.depth, "nesting depth")
                stack.append(e)
            case .folderEnd:
                if stack.isEmpty {
                    report.diagnostics.append("unmatched folder end at \(e.offset); subsequent hierarchy uncertain")
                    uncertain = true
                } else { stack.removeLast() }
            case .file: break
            }
            if payloadEnd(e) > extent {
                report.diagnostics.append("incomplete member at \(e.offset): payload ends at \(payloadEnd(e)), archive extent \(extent)")
            }
            try body(e)
            pos = min(payloadEnd(e), extent)
        }
        for e in stack.reversed() { report.diagnostics.append("unclosed folder \(e.name) at offset \(e.offset)") }
        // The classic recursive macutils reader counts a root file or a whole
        // root folder once. Do not infer version-specific extensions from it.
        if version == 1 {
            if !uncertain && rootMembers != numFiles {
                report.diagnostics.append("archive count mismatch: declared \(numFiles) root items, traversed \(rootMembers)")
            }
        } else {
            report.diagnostics.append("count validation SKIPPED for unverified classic archive version \(version)")
        }
        return report
    }

    struct ForkOutcome {
        var bytes: [UInt8]
        var absent: Bool
        var diagnostics: [String]
        var complete: Bool { diagnostics.isEmpty }
    }

    func recoverFork(method: UInt8, offset: Int, compressedLength: Int, uncompressedLength: Int,
                     crc: UInt16, verify: Bool) -> ForkOutcome {
        var result: ForkOutcome
        do {
            let bytes = try decompressFork(method: method, offset: offset, compressedLength: compressedLength, uncompressedLength: uncompressedLength)
            result = ForkOutcome(bytes: bytes, absent: compressedLength == 0 && uncompressedLength == 0, diagnostics: [])
        } catch let damage as ForkDamage {
            result = ForkOutcome(bytes: damage.bytes, absent: false, diagnostics: [damage.description])
        } catch {
            result = ForkOutcome(bytes: [], absent: false, diagnostics: [String(describing: error)])
        }
        if verify && !result.absent && CRC16.checksum(result.bytes) != crc { result.diagnostics.append("CRC mismatch") }
        return result
    }

    /// Decompress a fork given its method, compressed byte range and expected
    /// uncompressed length. Only methods 0 (stored) and 13 are present in the
    /// classic archives targeted here.
    func decompressFork(method: UInt8, offset: Int, compressedLength: Int, uncompressedLength: Int) throws -> [UInt8] {
        try Limits.check(max(uncompressedLength, method == 0 ? compressedLength : 0), limits.forkBytes, "decoded fork bytes")
        guard offset >= 0, compressedLength >= 0, offset <= extent, compressedLength <= extent - offset else {
            if method == 0, offset >= 0, offset <= extent, compressedLength >= 0 {
                throw ForkDamage(bytes: Array(data[offset..<extent]), description: "truncated stored fork length")
            }
            if method == 13, offset >= 0, offset <= extent, compressedLength >= 0 {
                do {
                    var decoder = try StuffIt13(Array(data[offset..<extent]))
                    let bytes = try decoder.decompress(expectedLength: uncompressedLength)
                    throw ForkDamage(bytes: bytes, description: "truncated compressed fork extent")
                } catch let damage as ForkDamage {
                    throw ForkDamage(bytes: damage.bytes, description: "truncated compressed fork extent; " + damage.description)
                }
            }
            throw SITError.truncated
        }
        try Limits.check(uncompressedLength, limits.forkBytes, "decoded fork bytes")
        if compressedLength == 0 && uncompressedLength == 0 { return [] }
        let slice = Array(data[offset..<(offset + compressedLength)])
        if (compressedLength == 0) != (uncompressedLength == 0) {
            throw ForkDamage(bytes: method == 0 ? slice : [], description: "contradictory zero/nonzero fork lengths")
        }
        switch method {
        case 0:
            guard compressedLength == uncompressedLength else {
                throw ForkDamage(bytes: slice, description: "stored length \(compressedLength) differs from declared length \(uncompressedLength)")
            }
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
