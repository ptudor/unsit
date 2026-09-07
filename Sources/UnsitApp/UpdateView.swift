// Copyright (c) 2026 Patrick Tudor. SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import UnsitDesktop

@available(macOS 12.0, *)
struct UpdateView: View {
    @ObservedObject var updates: AppUpdateController
    @ObservedObject var extraction: ExtractionModel
    @State private var downloadTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Unsit Updates").font(.title2).fontWeight(.semibold)
            Text(updates.message).fixedSize(horizontal: false, vertical: true)
            if updates.isChecking || updates.isDownloading { ProgressView().scaleEffect(0.7) }
            Toggle("Automatically check for updates", isOn: $updates.automaticChecks)
            Picker("Check", selection: $updates.interval) {
                ForEach(AppUpdateController.Interval.allCases) { interval in Text(interval.label).tag(interval) }
            }.disabled(!updates.automaticChecks)
            Text("Checks contact GitHub. Your archives and extracted files stay on your Mac.")
                .font(.caption).foregroundColor(.secondary)
            if let date = updates.lastChecked {
                Text("Last checked: \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundColor(.secondary)
            }
            if extraction.isBusy && updates.available != nil {
                Text("Finish extracting before installing an update.").font(.caption)
            }
            HStack {
                Button("Check Now") { Task { await updates.checkNow() } }
                    .disabled(updates.isChecking || updates.isDownloading)
                if let update = updates.available {
                    Button("Release Notes") { NSWorkspace.shared.open(update.releaseNotes) }
                }
                Spacer()
                if updates.isDownloading {
                    Button("Cancel Download") { downloadTask?.cancel() }
                } else if let downloaded = updates.downloaded {
                    Button("Open Installer") { NSWorkspace.shared.open(downloaded) }.disabled(extraction.isBusy)
                } else if updates.available != nil && !updates.requiresNewerOS {
                    Button("Download Update") {
                        downloadTask = Task {
                            if let url = await updates.downloadUpdate(), !extraction.isBusy { NSWorkspace.shared.open(url) }
                        }
                    }.disabled(extraction.isBusy)
                }
                Button("Done") { updates.isPresented = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 560)
    }
}
