// Copyright (c) 2026 Patrick Tudor. SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UnsitDesktop

@main
@available(macOS 12.0, *)
struct UnsitApplication {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@available(macOS 12.0, *)
struct MainView: View {
    @ObservedObject var model: ExtractionModel
    @ObservedObject var updates: AppUpdateController
    private let updateTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    var body: some View {
        ContentView(model: model)
            .frame(minWidth: 580, minHeight: 480)
            .task { await updates.checkIfDue() }
            .onReceive(updateTimer) { _ in Task { await updates.checkIfDue() } }
            .sheet(isPresented: $updates.isPresented) { UpdateView(updates: updates, extraction: model) }
    }
}

@available(macOS 12.0, *)
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let model = ExtractionModel.shared
    private let updates = AppUpdateController(
        repository: Bundle.main.object(forInfoDictionaryKey: "UnsitReleaseRepository") as? String ?? "ptudor/unsit",
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
        automaticByDefault: Bundle.main.object(forInfoDictionaryKey: "UnsitAutomaticUpdatesDefault") as? Bool ?? false)

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        makeMenu()
        showWindow()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        showWindow()
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        showWindow()
        model.enqueue(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        showWindow()
        model.enqueue(urls)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }
    @objc private func showWindow() {
        if window == nil {
            let new = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            new.title = "Unsit"
            new.isReleasedWhenClosed = false
            new.contentView = NSHostingView(rootView: MainView(model: model, updates: updates))
            new.contentMinSize = NSSize(width: 580, height: 480)
            new.center()
            new.setFrameAutosaveName("UnsitMainWindow")
            window = new
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func openArchives() { showWindow(); model.chooseArchives() }
    @objc private func checkUpdates() {
        showWindow(); updates.isPresented = true
        Task { await updates.checkNow() }
    }
    @objc private func showHelp() {
        if let url = Bundle.main.url(forResource: "Help", withExtension: "html") { NSWorkspace.shared.open(url) }
    }
    private func makeMenu() {
        let bar = NSMenu()
        func menu(_ name: String) -> NSMenu {
            let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: name); item.submenu = menu; bar.addItem(item)
            return menu
        }
        func item(_ menu: NSMenu, _ name: String, _ action: Selector, _ key: String = "", target: AnyObject? = nil) {
            let item = NSMenuItem(title: name, action: action, keyEquivalent: key)
            item.target = target; menu.addItem(item)
        }
        let app = menu("Unsit")
        item(app, "About Unsit", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        item(app, "Check for Updates…", #selector(checkUpdates), target: self)
        app.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services"); app.addItem(services); NSApp.servicesMenu = services.submenu
        app.addItem(.separator())
        item(app, "Hide Unsit", #selector(NSApplication.hide(_:)), "h")
        item(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        item(app, "Quit Unsit", #selector(NSApplication.terminate(_:)), "q")
        let file = menu("File")
        item(file, "Open Archives…", #selector(openArchives), "o", target: self)
        item(file, "Close Window", #selector(NSWindow.performClose(_:)), "w")
        let edit = menu("Edit")
        for (title, selector, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            item(edit, title, NSSelectorFromString(selector), key)
        }
        let windows = menu("Window")
        item(windows, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        item(windows, "Zoom", #selector(NSWindow.performZoom(_:)))
        item(windows, "Show Unsit", #selector(showWindow), target: self)
        NSApp.windowsMenu = windows
        let help = menu("Help")
        item(help, "Unsit Help", #selector(showHelp), target: self)
        NSApp.helpMenu = help
        NSApp.mainMenu = bar
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ExtractionModel.shared.isBusy else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Stop extracting and quit?"
        alert.informativeText = "Files already extracted will stay in their output folders."
        alert.addButton(withTitle: "Keep Extracting")
        alert.addButton(withTitle: "Stop and Quit")
        if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        ExtractionModel.shared.stop()
        return .terminateNow
    }
}

struct ContentView: View {
    @ObservedObject var model: ExtractionModel
    @State private var targeted = false
    @State private var detail: ArchiveJob?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "archivebox.fill").font(.system(size: 36)).foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Unsit").font(.largeTitle).fontWeight(.semibold)
                    Text("Bring your classic Mac archives back.").foregroundColor(.secondary)
                }
                Spacer()
            }
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.doc").font(.system(size: 30, weight: .light)).foregroundColor(.accentColor)
                Text("Drop StuffIt archives here").font(.title3).fontWeight(.medium)
                Button("Choose Archives…", action: model.chooseArchives)
                Text("Classic .sit archives")
                    .font(.caption).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 22)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(targeted ? 0.14 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(targeted ? 0.8 : 0.3), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $targeted, perform: receiveDrop)
            HStack {
                Image(systemName: "folder").foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.destination?.lastPathComponent ?? "Next to each archive").fontWeight(.medium)
                    Text("Each archive gets a new folder.").font(.caption).foregroundColor(.secondary)
                }
                .help(model.destination?.path ?? "Save alongside the original archive")
                Spacer()
                Menu("Save To") {
                    Button("Next to Each Archive") { model.destination = nil }
                    Button("Choose Folder…", action: model.chooseDestination)
                }.fixedSize()
            }
            Divider()
            if model.jobs.isEmpty {
                Spacer(minLength: 0)
                Text("Your archives stay intact. Recovered files appear here when they’re ready.")
                    .foregroundColor(.secondary).font(.callout).frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.jobs) { job in
                            HStack(spacing: 12) {
                                if job.state == .extracting { ProgressView().scaleEffect(0.65).frame(width: 24, height: 24) }
                                else { Image(systemName: symbol(job)).foregroundColor(color(job)).frame(width: 24) }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(job.archive.lastPathComponent).fontWeight(.medium).lineLimit(1)
                                    Text(job.status).font(.caption).foregroundColor(color(job))
                                    if let report = job.report {
                                        Text(report.fileSummary).font(.caption).foregroundColor(.secondary)
                                        if report.damageDetected {
                                            Text("Damage or possible bitrot was found in this archive.").font(.caption).foregroundColor(.orange)
                                        }
                                        if report.recoveredAfterDamage > 0 {
                                            Text("\(report.recoveredAfterDamage) \(report.recoveredAfterDamage == 1 ? "file" : "files") found beyond damaged records; folder placement is uncertain.")
                                                .font(.caption).foregroundColor(.secondary)
                                        }
                                    }
                                }
                                Spacer()
                                if !job.details.isEmpty { Button("Details") { detail = job } }
                                if let output = job.output {
                                    Button("Open Folder") { NSWorkspace.shared.open(output) }
                                }
                            }.padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
                        }
                    }
                }
                HStack {
                    Button("Clear Finished", action: model.clearFinished)
                    Spacer()
                    if model.isBusy { Button("Stop", action: model.stop) }
                }
            }
        }
        .padding(24)
        .alert(item: $model.message) { Alert(title: Text("Unable to Open"), message: Text($0.text), dismissButton: .default(Text("OK"))) }
        .sheet(item: $detail) { job in
            VStack(alignment: .leading, spacing: 16) {
                Text(job.status).font(.title2)
                Text(job.archive.lastPathComponent).foregroundColor(.secondary)
                ScrollView { Text(job.details).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading) }
                HStack {
                    Button("Copy Details") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(job.details, forType: .string) }
                    Spacer()
                    Button("Done") { detail = nil }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 580, height: 360)
        }
    }

    private func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                if let url = url { DispatchQueue.main.async { model.enqueue([url]) } }
            }
        }
        return !providers.isEmpty
    }
    private func symbol(_ job: ArchiveJob) -> String {
        switch job.state {
        case .complete: return "checkmark.circle.fill"
        case .warning, .failed: return "exclamationmark.triangle.fill"
        case .stopped: return "stop.circle"
        default: return "doc.zipper"
        }
    }
    private func color(_ job: ArchiveJob) -> Color {
        switch job.state {
        case .complete: return .green
        case .warning: return .orange
        case .failed: return .red
        default: return .secondary
        }
    }
}
