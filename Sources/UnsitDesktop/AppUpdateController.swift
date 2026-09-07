// Copyright (c) 2026 Patrick Tudor. SPDX-License-Identifier: MIT
import Combine
import Foundation

@available(macOS 12.0, *)
@MainActor
public final class AppUpdateController: ObservableObject {
    public enum Interval: Int, CaseIterable, Identifiable {
        case sixHours = 21_600, daily = 86_400, weekly = 604_800
        public var id: Int { rawValue }
        public var label: String {
            switch self { case .sixHours: return "Every 6 hours"; case .daily: return "Daily"; case .weekly: return "Weekly" }
        }
    }
    @Published public var automaticChecks: Bool {
        didSet { defaults.set(automaticChecks, forKey: "updates.automatic") }
    }
    @Published public var interval: Interval {
        didSet { defaults.set(interval.rawValue, forKey: "updates.interval") }
    }
    @Published public private(set) var message = "Not checked yet."
    @Published public private(set) var isChecking = false
    @Published public private(set) var isDownloading = false
    @Published public private(set) var available: AppUpdate?
    @Published public private(set) var requiresNewerOS = false
    @Published public private(set) var downloaded: URL?
    @Published public private(set) var lastChecked: Date?
    @Published public var isPresented = false

    private let defaults: UserDefaults
    private let current: ReleaseVersion
    private let system: ReleaseVersion
    private let now: () -> Date
    private let fetch: (ReleaseVersion, ReleaseVersion?) async throws -> AppUpdate?
    private let download: (AppUpdate) async throws -> URL

    public convenience init(repository: String, version: String, automaticByDefault: Bool) {
        let client = try? AppUpdateClient(repository: repository)
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("net.ptudor.Unsit/Updates", isDirectory: true)
        self.init(defaults: .standard, current: ReleaseVersion(version) ?? ReleaseVersion("0.0.0")!,
                  system: ReleaseVersion("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")!,
                  automaticByDefault: automaticByDefault, fetch: { current, highest in
            guard let client = client else { throw UpdateError("The release repository is not configured.") }
            return try await client.latest(after: current, architecture: architecture, highestSeen: highest)
        }, download: { update in
            guard let client = client else { throw UpdateError("The release repository is not configured.") }
            return try await client.download(update, into: directory)
        })
    }

    // Dependency injection keeps network, clock, compatibility, and retry tests local.
    init(defaults: UserDefaults, current: ReleaseVersion, system: ReleaseVersion,
         automaticByDefault: Bool, now: @escaping () -> Date = Date.init,
         fetch: @escaping (ReleaseVersion, ReleaseVersion?) async throws -> AppUpdate?,
         download: @escaping (AppUpdate) async throws -> URL) {
        self.defaults = defaults; self.current = current; self.system = system
        self.now = now; self.fetch = fetch; self.download = download
        automaticChecks = defaults.object(forKey: "updates.automatic") as? Bool ?? automaticByDefault
        interval = Interval(rawValue: defaults.integer(forKey: "updates.interval")) ?? .daily
        lastChecked = defaults.object(forKey: "updates.lastCheck") as? Date
    }

    public func checkIfDue() async {
        guard automaticChecks, !isChecking, !isDownloading else { return }
        let date = now()
        if let lastChecked = lastChecked, date.timeIntervalSince(lastChecked) < TimeInterval(interval.rawValue) { return }
        if let attempted = defaults.object(forKey: "updates.lastAttempt") as? Date,
           date.timeIntervalSince(attempted) < 900 { return }
        await checkNow()
        if available != nil { isPresented = true }
    }

    public func checkNow() async {
        guard !isChecking, !isDownloading else { return }
        isChecking = true
        downloaded = nil
        defaults.set(now(), forKey: "updates.lastAttempt")
        message = "Checking for updates…"
        defer { isChecking = false }
        do {
            let highest = defaults.string(forKey: "updates.highestVersion").flatMap(ReleaseVersion.init)
            let update = try await fetch(current, highest)
            available = update; downloaded = nil; requiresNewerOS = false
            if let update = update {
                if highest == nil || update.version > highest! {
                    defaults.set(update.version.description, forKey: "updates.highestVersion")
                }
                requiresNewerOS = system < update.minimumSystemVersion
                message = requiresNewerOS
                    ? "Unsit \(update.version) is available and requires macOS \(update.minimumSystemVersion) or later."
                    : "Unsit \(update.version) is available."
            } else { message = "Unsit is up to date." }
            lastChecked = now()
            defaults.set(lastChecked, forKey: "updates.lastCheck")
        } catch {
            available = nil; requiresNewerOS = false
            message = "Update check failed: " + error.localizedDescription
        }
    }

    public func downloadUpdate() async -> URL? {
        guard !isDownloading, !isChecking, !requiresNewerOS, let update = available else { return nil }
        isDownloading = true; downloaded = nil
        message = "Downloading Unsit \(update.version)…"
        defer { isDownloading = false }
        do {
            let url = try await download(update)
            downloaded = url
            message = "Downloaded and verified. Quit Unsit, then drag the new app into Applications."
            return url
        } catch {
            message = Task.isCancelled || error is CancellationError
                ? "Update download cancelled." : "Update download failed: " + error.localizedDescription
        }
        return nil
    }
}
