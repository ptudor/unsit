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
            Text(Strings.updates("Unsit Updates")).font(.title2).fontWeight(.semibold)
            Text(updates.message).fixedSize(horizontal: false, vertical: true)
            if updates.isChecking || updates.isDownloading { ProgressView().scaleEffect(0.7) }
            Toggle(Strings.updates("Automatically check for updates"), isOn: $updates.automaticChecks)
            Picker(Strings.updates("Check frequency"), selection: $updates.interval) {
                ForEach(AppUpdateController.Interval.allCases) { interval in Text(interval.label).tag(interval) }
            }.disabled(!updates.automaticChecks)
            Text(Strings.updates("Checks contact GitHub. Your archives and extracted files stay on your Mac."))
                .font(.caption).foregroundColor(.secondary)
            if let date = updates.lastChecked {
                Text(Strings.updates("Last checked: %@", date.formatted(date: .abbreviated, time: .shortened)))
                    .font(.caption).foregroundColor(.secondary)
            }
            if extraction.isBusy && updates.available != nil {
                Text(Strings.updates("Finish extracting before installing an update.")).font(.caption)
            }
            HStack {
                Button(Strings.updates("Check Now")) { Task { await updates.checkNow() } }
                    .disabled(updates.isChecking || updates.isDownloading)
                if let update = updates.available {
                    Button(Strings.updates("Release Notes")) { NSWorkspace.shared.open(update.releaseNotes) }
                }
                Spacer()
                if updates.isDownloading {
                    Button(Strings.updates("Cancel Download")) { downloadTask?.cancel() }
                } else if let downloaded = updates.downloaded {
                    Button(Strings.updates("Open Installer")) { NSWorkspace.shared.open(downloaded) }.disabled(extraction.isBusy)
                } else if updates.available != nil && !updates.requiresNewerOS {
                    Button(Strings.updates("Download Update")) {
                        downloadTask = Task {
                            if let url = await updates.downloadUpdate(), !extraction.isBusy { NSWorkspace.shared.open(url) }
                        }
                    }.disabled(extraction.isBusy)
                }
                Button(Strings.updates("Done")) { updates.isPresented = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 560)
    }
}
