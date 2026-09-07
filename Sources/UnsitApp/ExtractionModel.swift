// Copyright (c) 2026 Patrick Tudor. SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import UnsitDesktop
import UnsitReport

struct ArchiveJob: Identifiable {
    enum State { case queued, extracting, complete, warning, failed, stopped }
    let id = UUID()
    let archive: URL
    let destination: URL
    var state: State = .queued
    var output: URL?
    var details = ""
    var report: ExtractionReport?
    var status: String {
        if let report = report, state != .stopped { return report.headline }
        switch state {
        case .queued: return "Waiting"
        case .extracting: return "Extracting…"
        case .complete: return "Ready"
        case .warning: return "Recovered with warnings"
        case .failed: return "Couldn’t extract"
        case .stopped: return "Stopped"
        }
    }
}

struct AppMessage: Identifiable {
    let id = UUID()
    let text: String
}

@MainActor
final class ExtractionModel: ObservableObject {
    static let shared = ExtractionModel()
    @Published var jobs: [ArchiveJob] = []
    @Published var destination: URL?
    @Published var message: AppMessage?
    private let worker = DispatchQueue(label: "net.ptudor.unsit.extract", qos: .userInitiated)
    private var operation: ExtractionOperation?
    var isBusy: Bool { operation != nil }

    func chooseArchives() {
        let panel = NSOpenPanel()
        panel.title = "Open classic StuffIt archives"
        panel.allowedFileTypes = ["sit"]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { enqueue(panel.urls) }
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = "Save extracted files in"
        panel.prompt = "Choose Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK { destination = panel.url }
    }

    func enqueue(_ urls: [URL]) {
        for url in urls {
            guard url.isFileURL, url.pathExtension.lowercased() == "sit" else {
                message = AppMessage(text: "Choose a classic StuffIt (.sit) archive. Other archive formats, including .sitx, aren’t supported.")
                continue
            }
            jobs.append(ArchiveJob(archive: url, destination: destination ?? url.deletingLastPathComponent()))
        }
        startNext()
    }

    func stop() {
        for index in jobs.indices where jobs[index].state == .queued { jobs[index].state = .stopped }
        operation?.cancel()
    }

    func clearFinished() { jobs.removeAll { $0.state != .queued && $0.state != .extracting } }

    private func startNext() {
        guard operation == nil, let index = jobs.firstIndex(where: { $0.state == .queued }) else { return }
        let job = jobs[index]
        let task = ExtractionOperation()
        operation = task
        jobs[index].state = .extracting
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/unsit")
        let development = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("unsit")
        let executable = Bundle.main.bundleURL.pathExtension == "app" ? bundled : development
        worker.async {
            let result = Result { try task.run(archive: job.archive, destination: job.destination, executable: executable) }
            DispatchQueue.main.async {
                if let index = self.jobs.firstIndex(where: { $0.id == job.id }) {
                    switch result {
                    case .success(let result):
                        self.jobs[index].output = result.output
                        self.jobs[index].details = result.details
                        self.jobs[index].report = result.report
                        self.jobs[index].state = result.cancelled ? .stopped : result.status == 0 ? .complete : result.output == nil ? .failed : .warning
                    case .failure(let error):
                        self.jobs[index].state = .failed
                        self.jobs[index].details = error.localizedDescription
                    }
                }
                self.operation = nil
                self.startNext()
            }
        }
    }
}
