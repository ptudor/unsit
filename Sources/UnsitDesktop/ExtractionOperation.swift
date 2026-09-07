// Copyright (c) 2026 Patrick Tudor. SPDX-License-Identifier: MIT
import Foundation
import Darwin
import UnsitReport

public struct ExtractionResult: Sendable {
    public let output: URL?
    public let status: Int32
    public let cancelled: Bool
    public let details: String
    public let report: ExtractionReport?
}

/// Runs the same CLI shipped in the app bundle. One operation owns one fresh
/// destination and subprocess; diagnostics never pass through a shell or pipe.
public final class ExtractionOperation: @unchecked Sendable {
    // All shared mutable state is protected by lock. run() is single-use;
    // cancel() may be called from the UI while the worker waits for the child.
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var started = false

    public init() {}

    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if let process = process, process.isRunning { process.terminate() }
    }

    public func run(archive: URL, destination: URL, executable: URL) throws -> ExtractionResult {
        lock.lock()
        let alreadyStarted = started
        started = true
        lock.unlock()
        guard !alreadyStarted else { throw Failure("This extraction has already started.") }
        guard archive.isFileURL, destination.isFileURL else { throw Failure("Choose a local archive and folder.") }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw Failure("The extractor is missing from this copy of Unsit. Reinstall the app.")
        }
        let archive = try Self.canonicalURL(archive)
        let parent = try Self.canonicalURL(destination)
        let output = try Self.reserveOutput(for: archive, in: parent)
        let logs = FileManager.default.temporaryDirectory.appendingPathComponent("unsit-app-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: logs) }
        let logFile = logs.appendingPathComponent("diagnostics")
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logFile)
        defer { try? handle.close() }
        let reportFile = logs.appendingPathComponent("report.json")
        FileManager.default.createFile(atPath: reportFile.path, contents: nil)
        let reportHandle = try FileHandle(forWritingTo: reportFile)
        defer { try? reportHandle.close() }

        let task = Process()
        task.executableURL = executable
        task.arguments = ["--json", "--", archive.path, output.path]
        task.standardOutput = reportHandle
        task.standardError = handle
        task.standardInput = FileHandle.nullDevice
        lock.lock()
        if cancelled {
            lock.unlock()
            _ = rmdir(output.path)
            return ExtractionResult(output: nil, status: 1, cancelled: true, details: "Extraction stopped.", report: nil)
        }
        process = task
        do { try task.run() }
        catch {
            process = nil
            lock.unlock()
            _ = rmdir(output.path)
            throw error
        }
        lock.unlock()
        task.waitUntilExit()
        lock.lock()
        process = nil
        let wasCancelled = cancelled
        lock.unlock()

        let reader = try FileHandle(forReadingFrom: logFile)
        defer { try? reader.close() }
        let limit = 128 * 1024
        let data = try reader.read(upToCount: limit + 1) ?? Data()
        var details = String(decoding: data.prefix(limit), as: UTF8.self)
        if data.count > limit { details += "\nFurther messages omitted.\n" }
        let reportReader = try FileHandle(forReadingFrom: reportFile)
        defer { try? reportReader.close() }
        let reportData = try reportReader.read(upToCount: 64 * 1024) ?? Data()
        let decoded = try? JSONDecoder().decode(ExtractionReport.self, from: reportData)
        let report = decoded?.schemaVersion == 1 && decoded?.status == task.terminationStatus ? decoded : nil
        if report == nil && !wasCancelled { details += "\nThe extractor did not return a valid recovery report.\n" }
        if wasCancelled { details = "Extraction stopped. Files already recovered remain in the output folder.\n\n" + details }
        let empty = (try? FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty) == true
        let failed = task.terminationStatus != 0 || wasCancelled || report == nil
        if failed && empty { _ = rmdir(output.path) }
        return ExtractionResult(output: failed && empty ? nil : output, status: failed ? 1 : 0,
                                cancelled: wasCancelled, details: details, report: report)
    }

    private static func reserveOutput(for archive: URL, in parent: URL) throws -> URL {
        var name = archive.deletingPathExtension().lastPathComponent
        while name.utf8.count > 180 { name.removeLast() }
        if name.isEmpty || name == "." || name == ".." { name = "Archive" }
        for suffix in 1...10_000 {
            let leaf = name + " (extracted)" + (suffix == 1 ? "" : " \(suffix)")
            let output = parent.appendingPathComponent(leaf, isDirectory: true)
            if mkdir(output.path, 0o755) == 0 { return output }
            if errno != EEXIST { throw Failure("Cannot create an extraction folder here: " + String(cString: strerror(errno))) }
        }
        throw Failure("There are too many extraction folders with this name. Choose another destination.")
    }

    private static func canonicalURL(_ url: URL) throws -> URL {
        // Foundation can abbreviate /private/var back to the /var symlink.
        // The CLI deliberately requires every output component to be real.
        guard let path = realpath(url.path, nil) else {
            throw Failure("Cannot open this location: " + String(cString: strerror(errno)))
        }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path))
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
