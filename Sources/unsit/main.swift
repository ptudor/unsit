import Foundation

struct Options {
    var archivePath: String
    var outputDir: String?
    var list = false
    var quiet = false
    var noVerify = false
}

func usage() -> Never {
    let prog = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? "unsit"
    FileHandle.standardError.write(Data("""
    unsit — extract classic StuffIt (SIT!) archives

    Usage:
      \(prog) [options] <archive.sit> [output-directory]

    Options:
      -l, --list        List archive contents without extracting
      -o, --output DIR  Extract into DIR (default: a folder named after the archive)
      -q, --quiet       Only print warnings and errors
          --no-verify   Skip fork CRC verification
      -h, --help        Show this help

    Extracts data forks as file contents, resource forks to each file's
    ..namedfork/rsrc, and restores type/creator/Finder-flags and mod dates.

    """.data(using: .utf8)!))
    exit(2)
}

func parseArguments() -> Options {
    var args = Array(CommandLine.arguments.dropFirst())
    var opts = Options(archivePath: "")
    var positional: [String] = []
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "-h", "--help": usage()
        case "-l", "--list": opts.list = true
        case "-q", "--quiet": opts.quiet = true
        case "--no-verify": opts.noVerify = true
        case "-o", "--output":
            guard !args.isEmpty else { usage() }
            opts.outputDir = args.removeFirst()
        default:
            if a.hasPrefix("-") && a != "-" { usage() }
            positional.append(a)
        }
    }
    guard !positional.isEmpty else { usage() }
    opts.archivePath = positional[0]
    if positional.count > 1 { opts.outputDir = positional[1] }
    if positional.count > 2 { usage() }
    return opts
}

func log(_ s: String, quiet: Bool = false) {
    if !quiet { print(s) }
}

func warn(_ s: String) {
    FileHandle.standardError.write(Data("warning: \(s)\n".utf8))
}

func run() -> Int32 {
    if CommandLine.arguments.dropFirst().contains("--self-test") {
        return SelfTest.run()
    }
    let opts = parseArguments()

    guard let data = FileManager.default.contents(atPath: opts.archivePath) else {
        FileHandle.standardError.write(Data("error: cannot read \(opts.archivePath)\n".utf8))
        return 1
    }

    let archive: SITArchive
    do {
        archive = try SITArchive(data: [UInt8](data))
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        return 1
    }

    if opts.list {
        return list(archive)
    }

    // Determine root output directory.
    let base = (opts.archivePath as NSString).lastPathComponent
    let stem = base.hasSuffix(".sit") ? String(base.dropLast(4)) : base + " (extracted)"
    let root = opts.outputDir ?? stem

    do {
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    } catch {
        FileHandle.standardError.write(Data("error: cannot create output directory \(root): \(error)\n".utf8))
        return 1
    }

    var dirStack = [root]
    var fileCount = 0
    var crcFailures = 0
    var skippedBytes = 0
    var errorCount = 0

    do {
        try archive.forEachEntry(onResync: { pos, skipped in
            warn("resynced at offset \(pos), skipped \(skipped) unrecognized byte(s)")
            skippedBytes += skipped
        }) { entry in
            switch entry.kind {
            case .folderStart:
                let dir = dirStack.last! + "/" + entry.name
                try MacFileWriter.createDirectory(at: dir, entry: entry)
                dirStack.append(dir)
                log("  \(String(repeating: "  ", count: dirStack.count - 2))[\(entry.name)]/", quiet: opts.quiet)

            case .folderEnd:
                if dirStack.count > 1 { dirStack.removeLast() }

            case .file:
                let path = dirStack.last! + "/" + entry.name
                do {
                    let rsrc = try archive.decompressFork(
                        method: entry.rsrcMethod, offset: entry.rsrcOffset,
                        compressedLength: entry.rsrcCompressedLength,
                        uncompressedLength: entry.rsrcUncompressedLength)
                    let data = try archive.decompressFork(
                        method: entry.dataMethod, offset: entry.dataOffset,
                        compressedLength: entry.dataCompressedLength,
                        uncompressedLength: entry.dataUncompressedLength)

                    if !opts.noVerify {
                        crcFailures += verify(entry: entry, rsrc: rsrc, data: data)
                    }
                    try MacFileWriter.writeFile(at: path, entry: entry, dataFork: data, resourceFork: rsrc)
                    fileCount += 1
                    let indent = String(repeating: "  ", count: dirStack.count - 1)
                    log("  \(indent)\(entry.name) (\(data.count + rsrc.count) bytes)", quiet: opts.quiet)
                } catch {
                    warn("failed to extract \(entry.name) at offset \(entry.offset): \(error)")
                    errorCount += 1
                }
            }
        }
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        return 1
    }

    log("\nExtracted \(fileCount) file(s) into \(root)", quiet: false)
    if crcFailures > 0 { warn("\(crcFailures) fork(s) failed CRC verification") }
    if skippedBytes > 0 { warn("skipped \(skippedBytes) unrecognized byte(s) total during resync") }
    if errorCount > 0 { warn("\(errorCount) member(s) could not be extracted") }
    return (crcFailures > 0 || errorCount > 0) ? 1 : 0
}

/// Returns the number of CRC failures (0, 1, or 2) for this entry's forks.
func verify(entry: SITEntry, rsrc: [UInt8], data: [UInt8]) -> Int {
    var failures = 0
    if entry.rsrcUncompressedLength > 0 {
        if CRC16.checksum(rsrc) != entry.rsrcCRC {
            warn("resource fork CRC mismatch for \(entry.name)")
            failures += 1
        }
    }
    if entry.dataUncompressedLength > 0 {
        if CRC16.checksum(data) != entry.dataCRC {
            warn("data fork CRC mismatch for \(entry.name)")
            failures += 1
        }
    }
    return failures
}

func list(_ archive: SITArchive) -> Int32 {
    var depth = 0
    var count = 0
    do {
        try archive.forEachEntry(onResync: { pos, skipped in
            warn("resynced at offset \(pos), skipped \(skipped) byte(s)")
        }) { entry in
            let indent = String(repeating: "  ", count: max(0, depth))
            switch entry.kind {
            case .folderStart:
                print("\(indent)[\(entry.name)]/")
                depth += 1
            case .folderEnd:
                depth = max(0, depth - 1)
            case .file:
                let type = String(bytes: entry.type, encoding: .macOSRoman) ?? "????"
                let m = "r\(entry.rsrcMethod)/d\(entry.dataMethod)"
                print("\(indent)\(entry.name)  [\(type)] \(m) rsrc=\(entry.rsrcUncompressedLength) data=\(entry.dataUncompressedLength)")
                count += 1
            }
        }
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        return 1
    }
    print("\n\(count) file(s)")
    return 0
}

exit(run())
