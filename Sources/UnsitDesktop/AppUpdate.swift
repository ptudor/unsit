// Copyright (c) 2026 Patrick Tudor. SPDX-License-Identifier: MIT
import CryptoKit
import Darwin
import Foundation

public struct ReleaseVersion: Comparable, CustomStringConvertible, Sendable {
    private let parts: [Int]
    public let description: String
    public init?(_ text: String) {
        let words = text.split(separator: ".", omittingEmptySubsequences: false)
        guard words.count == 3, words.allSatisfy({ word in
            !word.isEmpty && word.utf8.allSatisfy { (48...57).contains($0) }
                && (word.count == 1 || word.first != "0") && (Int(word) ?? -1) >= 0
        }) else { return nil }
        parts = words.map { Int($0)! }
        description = text
    }
    public static func < (a: Self, b: Self) -> Bool { a.parts.lexicographicallyPrecedes(b.parts) }
}

public struct UpdateAsset: Decodable, Sendable {
    public let name: String
    public let size: Int
    public let digest: String?
    public let browser_download_url: URL

    func validate(repository: String, tag: String, limit: Int) throws {
        let expected = "https://github.com/\(repository)/releases/download/\(tag)/\(name)"
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"),
              browser_download_url.absoluteString == expected,
              size > 0, size <= limit,
              let digest = digest, digest.hasPrefix("sha256:"), digest.count == 71,
              digest.dropFirst(7).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw UpdateError("The release asset has an invalid address, size, or SHA-256 digest.")
        }
    }
}

struct GitHubRelease: Decodable {
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    let assets: [UpdateAsset]
}

struct UpdateManifest: Decodable {
    let schemaVersion: Int
    let version: String
    let bundleIdentifier: String
    let minimumSystemVersion: String
    let assetName: String
}

public struct AppUpdate: Sendable {
    public let version: ReleaseVersion
    public let minimumSystemVersion: ReleaseVersion
    public let asset: UpdateAsset
    public let releaseNotes: URL
}

public struct UpdateError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Release metadata is authenticated by HTTPS to GitHub. Its asset digest checks
/// downloaded bytes; it is not an independent publisher signature or notarization.
@available(macOS 12.0, *)
public struct AppUpdateClient {
    public let repository: String
    private let session: URLSession
    public init(repository: String, session: URLSession = .shared) throws {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
        } }) else { throw UpdateError("The release repository is not configured correctly.") }
        self.repository = repository
        self.session = session
    }

    /// nil means no newer stable version; a missing feed, bad asset, and unsupported
    /// platform are errors so callers cannot incorrectly report "up to date".
    public func latest(after current: ReleaseVersion, architecture: String,
                       highestSeen: ReleaseVersion? = nil) async throws -> AppUpdate? {
        guard ["arm64", "x86_64"].contains(architecture) else { throw UpdateError("This Mac architecture is not supported.") }
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        let data = try await fetch(url, limit: 1_048_576)
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard !release.draft, !release.prerelease, release.tag_name.hasPrefix("v"),
              let version = ReleaseVersion(String(release.tag_name.dropFirst())) else {
            throw UpdateError("The latest release is not a valid stable version.")
        }
        if let highestSeen = highestSeen, version < highestSeen {
            throw UpdateError("The server returned an older release than one already seen. Try again later.")
        }
        guard version > current else { return nil }
        let prefix = "Unsit-\(version)-macos-"
        let arch: String
        if release.assets.contains(where: { $0.name == prefix + architecture + ".update.json" }) { arch = architecture }
        else { arch = "universal" }
        let manifests = release.assets.filter { $0.name == prefix + arch + ".update.json" }
        guard manifests.count == 1, let manifestAsset = manifests.first else {
            throw UpdateError("A newer release exists, but its update information for this Mac is missing.")
        }
        try manifestAsset.validate(repository: repository, tag: release.tag_name, limit: 16_384)
        let manifestData = try await fetch(manifestAsset.browser_download_url, limit: manifestAsset.size)
        try Self.verify(manifestData, asset: manifestAsset)
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: manifestData)
        guard manifest.schemaVersion == 1, manifest.version == version.description,
              manifest.bundleIdentifier == "net.ptudor.Unsit",
              let minimum = ReleaseVersion(manifest.minimumSystemVersion),
              manifest.assetName == prefix + arch + ".dmg" else {
            throw UpdateError("The update information does not match this app or has an invalid minimum macOS version.")
        }
        let assets = release.assets.filter { $0.name == manifest.assetName }
        guard assets.count == 1, let asset = assets.first else { throw UpdateError("The update installer is missing or ambiguous.") }
        try asset.validate(repository: repository, tag: release.tag_name, limit: 256 * 1024 * 1024)
        return AppUpdate(version: version, minimumSystemVersion: minimum, asset: asset,
                         releaseNotes: URL(string: "https://github.com/\(repository)/releases/tag/\(release.tag_name)")!)
    }

    public func download(_ update: AppUpdate, into directory: URL) async throws -> URL {
        try update.asset.validate(repository: repository, tag: "v\(update.version)", limit: 256 * 1024 * 1024)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // A private, exclusive directory also prevents name collisions and partial
        // download leftovers. Only a fully verified DMG is returned to the caller.
        let staging = directory.appendingPathComponent("Unsit Update " + UUID().uuidString, isDirectory: true)
        guard mkdir(staging.path, 0o700) == 0 else { throw UpdateError("Cannot create an update download folder.") }
        var placed = false
        defer { if !placed { try? fm.removeItem(at: staging) } }
        let file = staging.appendingPathComponent(update.asset.name)
        guard fm.createFile(atPath: file.path, contents: nil) else { throw UpdateError("Cannot create the update download.") }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let (bytes, response) = try await stream(update.asset.browser_download_url)
        defer { bytes.task.cancel() }
        try Self.validate(response, limit: update.asset.size)
        var hash = SHA256(), count = 0
        var buffer = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard count < update.asset.size else { throw UpdateError("The download exceeded its expected size.") }
            count += 1; buffer.append(byte)
            if buffer.count == 262_144 {
                hash.update(data: buffer); try handle.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true)
            }
        }
        hash.update(data: buffer); try handle.write(contentsOf: buffer)
        try handle.synchronize()
        guard count == update.asset.size, "sha256:" + Self.hex(hash.finalize()) == update.asset.digest else {
            throw UpdateError("The download failed its size or SHA-256 check. It was removed.")
        }
        // Native downloads must retain Gatekeeper's normal downloaded-file checks.
        let quarantine = "0083;" + String(Int(Date().timeIntervalSince1970), radix: 16) + ";Unsit;" + UUID().uuidString
        let marked = quarantine.withCString { setxattr(file.path, "com.apple.quarantine", $0, quarantine.utf8.count, 0, 0) }
        guard marked == 0 else { throw UpdateError("Cannot mark the installer as a downloaded file.") }
        placed = true
        return file
    }

    private func fetch(_ url: URL, limit: Int) async throws -> Data {
        let (bytes, response) = try await stream(url)
        defer { bytes.task.cancel() }
        try Self.validate(response, limit: limit)
        var result = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard result.count < limit else { throw UpdateError("The update response is too large.") }
            result.append(byte)
        }
        return result
    }

    private func stream(_ url: URL) async throws -> (URLSession.AsyncBytes, URLResponse) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("Unsit", forHTTPHeaderField: "User-Agent")
        if url.host == "api.github.com" {
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        }
        return try await session.bytes(for: request, delegate: HTTPSRedirects())
    }
    private static func validate(_ response: URLResponse, limit: Int) throws {
        guard let response = response as? HTTPURLResponse, response.url?.scheme == "https" else {
            throw UpdateError("The update server returned an invalid response.")
        }
        if response.statusCode == 404 { throw UpdateError("No public release is available yet.") }
        guard response.statusCode == 200 else { throw UpdateError("Update server returned HTTP \(response.statusCode). Try again later.") }
        guard response.expectedContentLength <= limit else { throw UpdateError("The update response is too large.") }
    }
    private static func verify(_ data: Data, asset: UpdateAsset) throws {
        guard data.count == asset.size, "sha256:" + hex(SHA256.hash(data: data)) == asset.digest else {
            throw UpdateError("The update information failed its size or SHA-256 check.")
        }
    }
    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
    static func allowsRedirect(from source: URL?, to target: URL?) -> Bool {
        guard let target = target, target.scheme == "https", target.user == nil, target.password == nil,
              target.port == nil || target.port == 443, let host = target.host else { return false }
        if source?.host == "api.github.com" { return host == "api.github.com" }
        return host == "github.com" || host.hasSuffix(".githubusercontent.com")
    }
    private final class HTTPSRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            AppUpdateClient.allowsRedirect(from: task.originalRequest?.url, to: request.url) ? request : nil
        }
    }
}
