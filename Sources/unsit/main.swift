import Foundation

struct Options {
    var archivePath: String
    var outputDir: String?
    var list = false
    var quiet = false
    var noVerify = false
    var limits = Limits()
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
        case "--max-input-bytes", "--max-fork-bytes", "--max-total-bytes", "--max-members", "--max-depth", "--max-recovery-bytes":
            guard !args.isEmpty, let n = Int(args.removeFirst()), n >= 0 else { usage() }
            switch a {
            case "--max-input-bytes": opts.limits.inputBytes = n
            case "--max-fork-bytes": opts.limits.forkBytes = n
            case "--max-total-bytes": opts.limits.totalBytes = n
            case "--max-members": opts.limits.members = n
            case "--max-depth": opts.limits.depth = n
            default: opts.limits.recoveryBytes = n
            }
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
    if !quiet { print(display(s)) }
}

func warn(_ s: String) {
    FileHandle.standardError.write(Data("warning: \(display(s))\n".utf8))
}

func run() -> Int32 {
    if CommandLine.arguments.dropFirst().contains("--self-test") {
        return SelfTest.run()
    }
    let opts = parseArguments()

    let archive: SITArchive
    do {
        archive = try SITArchive(data: opts.limits.readInput(opts.archivePath), limits: opts.limits)
    } catch {
        FileHandle.standardError.write(Data("error: \(display(String(describing: error)))\n".utf8))
        return 1
    }

    if opts.list {
        return list(archive)
    }

    // Determine root output directory.
    let base = (opts.archivePath as NSString).lastPathComponent
    let stem = base.hasSuffix(".sit") ? String(base.dropLast(4)) : base + " (extracted)"
    let root = opts.outputDir ?? stem

    let rootDirectory: OutputDirectory
    do {
        rootDirectory = try OutputDirectory.root(root)
    } catch {
        FileHandle.standardError.write(Data("error: cannot create output directory \(display(root)): \(display(String(describing: error)))\n".utf8))
        return 1
    }

    var dirStack: [OutputDirectory?] = [rootDirectory]
    let budget = OutputBudget(opts.limits)
    var fileCount = 0
    var crcFailures = 0
    var skippedBytes = 0
    var errorCount = 0

    do {
        let report = try archive.forEachEntry(onResync: { pos, skipped in
            warn("resynced at offset \(pos + skipped), skipped \(skipped) unrecognized byte(s)")
            skippedBytes += skipped
        }) { entry in
            if entry.hierarchyUncertain && dirStack.count > 1 { dirStack = [rootDirectory] }
            switch entry.kind {
            case .folderStart:
                if entry.hierarchyUncertain { return }
                do {
                    try MacFileWriter.validate(entry.name)
                    guard let parent = dirStack.last! else { throw MacFileWriter.WriteError(description: "blocked parent directory") }
                    let dir = try MacFileWriter.createDirectory(in: parent, name: entry.name, entry: entry)
                    dirStack.append(dir)
                } catch {
                    warn("failed folder \(entry.name) at offset \(entry.offset): \(error)")
                    errorCount += 1
                    dirStack.append(nil)
                }
                log("  \(String(repeating: "  ", count: dirStack.count - 2))[\(entry.name)]/", quiet: opts.quiet)

            case .folderEnd:
                if entry.hierarchyUncertain { return }
                if dirStack.count > 1 { dirStack.removeLast() }

            case .file:
                do {
                    try MacFileWriter.validate(entry.name)
                    guard let trustedParent = dirStack.last! else { throw MacFileWriter.WriteError(description: "blocked parent directory") }
                    try budget.reserve(entry)
                    let parent: OutputDirectory
                    if entry.hierarchyUncertain {
                        parent = try rootDirectory.create(entry.recoveryDirectory)
                        warn("uncertain member at \(entry.offset) recovered as \(entry.recoveryDirectory)/\(entry.name)")
                    } else { parent = trustedParent }
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
                    try MacFileWriter.writeFile(in: parent, name: entry.name, entry: entry, dataFork: data, resourceFork: rsrc)
                    fileCount += 1
                    let indent = String(repeating: "  ", count: dirStack.count - 1)
                    log("  \(indent)\(entry.name) (\(data.count + rsrc.count) bytes)", quiet: opts.quiet)
                } catch {
                    warn("failed to extract \(entry.name) at offset \(entry.offset): \(error)")
                    errorCount += 1
                }
            }
        }
        for diagnostic in report.diagnostics { warn(diagnostic) }
        if !report.complete { errorCount += 1 }
    } catch {
        FileHandle.standardError.write(Data("error: \(display(String(describing: error)))\n".utf8))
        return 1
    }

    log("Extracted \(fileCount) file(s) into \(root)", quiet: false)
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
        let report = try archive.forEachEntry(onResync: { pos, skipped in
            warn("resynced at offset \(pos + skipped), skipped \(skipped) byte(s)")
        }) { entry in
            let indent = String(repeating: "  ", count: entry.hierarchyUncertain ? 0 : max(0, depth))
            let memberName = entry.hierarchyUncertain ? entry.recoveryDirectory + "/" + entry.name : entry.name
            switch entry.kind {
            case .folderStart:
                print(display("\(indent)[\(entry.name)]/"))
                depth += 1
            case .folderEnd:
                depth = max(0, depth - 1)
            case .file:
                let type = String(bytes: entry.type, encoding: .macOSRoman) ?? "????"
                let m = "r\(entry.rsrcMethod)/d\(entry.dataMethod)"
                print(display("\(indent)\(memberName)  [\(type)] \(m) rsrc=\(entry.rsrcUncompressedLength) data=\(entry.dataUncompressedLength)"))
                count += 1
            }
        }
        for diagnostic in report.diagnostics { warn(diagnostic) }
        print("\n\(count) file(s)")
        return report.complete ? 0 : 1
    } catch {
        FileHandle.standardError.write(Data("error: \(display(String(describing: error)))\n".utf8))
        return 1
    }
}

exit(run())
