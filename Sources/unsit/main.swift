import Foundation
import UnsitReport

struct FolderFrame {
    let directory: OutputDirectory?
    let entry: SITEntry?
}

func log(_ s: String, quiet: Bool = false) {
    if !quiet { print(display(s)) }
}

func warn(_ s: String) {
    FileHandle.standardError.write(Data("warning: \(display(s))\n".utf8))
}

func run() -> Int32 {
    let opts: Options
    do {
        switch try parseArguments(Array(CommandLine.arguments.dropFirst())) {
        case .help: print(helpText); return 0
        case .version: print("unsit \(UnsitVersion.current)"); return 0
        case .selfTest: return SelfTest.run()
        case .archive(let options): opts = options
        }
    } catch {
        FileHandle.standardError.write(Data("error: \(display(String(describing: error)))\n\(helpText)\n".utf8))
        return 2
    }

    var summary = ExtractionReport()
    summary.forkChecksSkipped = opts.noVerify
    defer {
        if !opts.list && summary.damageDetected {
            warn("archive damage detected (possible bitrot): Unsit recovered \(summary.recoveredFiles) file(s): \(summary.completeFiles) complete, \(summary.partialFiles) partial")
            if summary.recoveredAfterDamage > 0 {
                warn("\(summary.recoveredAfterDamage) file(s) recovered beyond damaged archive records; original folder placement is uncertain")
            }
        }
        if opts.json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(summary) {
                FileHandle.standardOutput.write(data + Data([10]))
            }
        }
    }
    let quiet = opts.quiet || opts.json
    let archive: SITArchive
    do {
        archive = try SITArchive(data: opts.limits.readInput(opts.archivePath), limits: opts.limits)
    } catch {
        summary.problem = String(describing: error)
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
    summary.outputDirectory = URL(fileURLWithPath: root).path

    let rootDirectory: OutputDirectory
    do {
        rootDirectory = try OutputDirectory.root(root)
    } catch {
        summary.problem = String(describing: error)
        summary.restorationFailures += 1
        FileHandle.standardError.write(Data("error: cannot create output directory \(display(root)): \(display(String(describing: error)))\n".utf8))
        return 1
    }

    let rootFrame = FolderFrame(directory: rootDirectory, entry: nil)
    var dirStack = [rootFrame]
    let budget = OutputBudget(opts.limits)
    var errorCount = 0

    do {
        let report = try archive.forEachEntry(onResync: { pos, skipped in
            warn("resynced at offset \(pos + skipped), skipped \(skipped) unrecognized byte(s)")
            summary.skippedArchiveBytes += skipped
            summary.damagedHeaderGaps += 1
            summary.archiveStructureDamaged = true
        }, onReport: { report in
            summary.archiveStructureDamaged = report.structureDamaged
            summary.archiveValidationIncomplete = report.validationIncomplete
            summary.skippedArchiveBytes = report.skippedBytes
            summary.damagedHeaderGaps = report.damagedHeaderGaps
        }) { entry in
            if entry.hierarchyUncertain && dirStack.count > 1 { dirStack = [rootFrame] }
            switch entry.kind {
            case .folderStart:
                if entry.hierarchyUncertain { return }
                do {
                    try MacFileWriter.validate(entry.name)
                    guard let parent = dirStack.last!.directory else { throw MacFileWriter.WriteError(description: "blocked parent directory") }
                    let dir = try parent.create(entry.name)
                    let issues = MacFileWriter.setMetadata(fd: dir.fd, entry: entry, isDirectory: true, restoreDate: false)
                    for issue in issues { warn(issue) }
                    if !issues.isEmpty { errorCount += 1; summary.restorationFailures += 1 }
                    dirStack.append(FolderFrame(directory: dir, entry: entry))
                } catch {
                    warn("failed folder \(entry.name) at offset \(entry.offset): \(error)")
                    errorCount += 1
                    summary.restorationFailures += 1
                    dirStack.append(FolderFrame(directory: nil, entry: entry))
                }
                log("  \(String(repeating: "  ", count: dirStack.count - 2))[\(entry.name)]/", quiet: quiet)

            case .folderEnd:
                if entry.hierarchyUncertain { return }
                if dirStack.count > 1 {
                    let frame = dirStack.removeLast()
                    if let dir = frame.directory, let start = frame.entry,
                       let issue = MacFileWriter.setModificationDate(fd: dir.fd, macDate: start.modificationDate, name: start.name) {
                        warn(issue); errorCount += 1
                        summary.restorationFailures += 1
                    }
                }

            case .file:
                var forkIssueCount = 0
                var publicationAttempted = false
                do {
                    try MacFileWriter.validate(entry.name)
                    guard let trustedParent = dirStack.last!.directory else { throw MacFileWriter.WriteError(description: "blocked parent directory") }
                    try budget.reserve(entry)
                    let parent: OutputDirectory
                    if entry.hierarchyUncertain {
                        parent = try rootDirectory.create(entry.recoveryDirectory)
                        warn("uncertain member at \(entry.offset) recovered as \(entry.recoveryDirectory)/\(entry.name)")
                    } else { parent = trustedParent }
                    let rsrc = archive.recoverFork(
                        method: entry.rsrcMethod, offset: entry.rsrcOffset,
                        compressedLength: entry.rsrcCompressedLength,
                        uncompressedLength: entry.rsrcUncompressedLength, crc: entry.rsrcCRC, verify: !opts.noVerify)
                    let data = archive.recoverFork(
                        method: entry.dataMethod, offset: entry.dataOffset,
                        compressedLength: entry.dataCompressedLength,
                        uncompressedLength: entry.dataUncompressedLength, crc: entry.dataCRC, verify: !opts.noVerify)
                    let issues = rsrc.diagnostics.map { "resource fork: " + $0 } + data.diagnostics.map { "data fork: " + $0 }
                    forkIssueCount = issues.count
                    summary.damagedForks += [rsrc, data].filter { $0.damageDetected }.count
                    summary.unsupportedForks += [rsrc, data].filter { $0.unsupported }.count
                    if !issues.isEmpty && rsrc.bytes.isEmpty && data.bytes.isEmpty {
                        throw MacFileWriter.WriteError(description: issues.joined(separator: "; ") + "; no recoverable fork bytes")
                    }
                    publicationAttempted = true
                    let outcome = try MacFileWriter.writeFile(in: parent, name: entry.name, entry: entry,
                        dataFork: data.bytes, resourceFork: rsrc.bytes, diagnostics: issues)
                    if entry.hierarchyUncertain { summary.recoveredAfterDamage += 1 }
                    if outcome.complete { summary.completeFiles += 1 }
                    else {
                        summary.partialFiles += 1; errorCount += 1
                        if outcome.diagnostics.count > issues.count { summary.restorationFailures += 1 }
                        for issue in outcome.diagnostics { warn("\(entry.name) at offset \(entry.offset): \(issue)") }
                        warn("partial member preserved as \(outcome.name)")
                    }
                    let indent = String(repeating: "  ", count: dirStack.count - 1)
                    log("  \(indent)\(outcome.name) (\(data.bytes.count + rsrc.bytes.count) bytes)", quiet: quiet)
                } catch {
                    warn("failed to extract \(entry.name) at offset \(entry.offset): \(error)")
                    errorCount += 1
                    summary.failedFiles += 1
                    if forkIssueCount == 0 || publicationAttempted { summary.restorationFailures += 1 }
                }
            }
        }
        for diagnostic in report.diagnostics { warn(diagnostic) }
        if !report.complete { errorCount += 1 }
    } catch {
        summary.problem = String(describing: error)
        FileHandle.standardError.write(Data("error: \(display(String(describing: error)))\n".utf8))
        return 1
    }

    log("Extracted \(summary.completeFiles) file(s) into \(root)", quiet: quiet)
    if summary.partialFiles > 0 { warn("\(summary.partialFiles) partial member(s) recovered") }
    if summary.skippedArchiveBytes > 0 { warn("skipped \(summary.skippedArchiveBytes) unrecognized byte(s) total during resync") }
    if errorCount > 0 { warn("\(errorCount) issue(s) prevented complete restoration") }
    summary.status = (errorCount > 0) ? 1 : 0
    return summary.status
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
