import CryptoKit
import Foundation
import XCTest
@testable import UnsitDesktop

private final class UpdateProtocol: URLProtocol {
    struct Reply { let data: Data; var status = 200; var length: Int? }
    private static let lock = NSLock()
    private static var replies: [String: Reply] = [:]
    static func set(_ replies: [String: Reply]) { lock.lock(); defer { lock.unlock() }; self.replies = replies }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let reply = Self.replies[request.url!.absoluteString]; Self.lock.unlock()
        guard let reply = reply else { client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return }
        let headers = reply.length.map { ["Content-Length": String($0)] } ?? [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@available(macOS 12.0, *)
final class AppUpdateTests: XCTestCase {
    private let api = "https://api.github.com/repos/ptudor/unsit/releases/latest"
    private let base = "https://github.com/ptudor/unsit/releases/download/v1.2.3/"
    private let installer = Data("synthetic installer bytes".utf8)
    private func hash(_ data: Data) -> String { "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func encode(_ json: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: json, options: .sortedKeys) }
    private func client() throws -> AppUpdateClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [UpdateProtocol.self]
        let session = URLSession(configuration: config)
        addTeardownBlock { session.invalidateAndCancel() }
        return try AppUpdateClient(repository: "ptudor/unsit", session: session)
    }
    private func prepare(arch: String = "arm64", minimum: String = "12.0.0", product: String = "net.ptudor.Unsit",
                         digest: Bool = true, unsafe: Bool = false, prerelease: Bool = false,
                         download: Data? = nil, declared: Int? = nil, tamperManifest: Bool = false) throws {
        let prefix = "Unsit-1.2.3-macos-" + arch
        let manifest = try encode(["schemaVersion": 1, "version": "1.2.3", "bundleIdentifier": product,
                                   "minimumSystemVersion": minimum, "assetName": prefix + ".dmg"])
        var assets: [[String: Any]] = []
        for (name, bytes) in [(prefix + ".update.json", manifest), (prefix + ".dmg", installer)] {
            var asset: [String: Any] = ["name": name, "size": bytes.count,
                                        "browser_download_url": (unsafe ? "http://github.com/ptudor/unsit/releases/download/v1.2.3/" : base) + name]
            if digest { asset["digest"] = hash(bytes) }
            assets.append(asset)
        }
        let release = try encode(["tag_name": "v1.2.3", "draft": false, "prerelease": prerelease, "assets": assets])
        UpdateProtocol.set([
            api: .init(data: release),
            base + prefix + ".update.json": .init(data: tamperManifest ? Data("{}".utf8) : manifest),
            base + prefix + ".dmg": .init(data: download ?? installer, length: declared),
        ])
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("unsit-update-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func rejected(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected rejection", file: file, line: line) } catch {}
    }

    func testVersionOrderingAndRedirectTrust() throws {
        XCTAssertLessThan(ReleaseVersion("1.2.9")!, ReleaseVersion("1.10.0")!)
        for invalid in ["1.0", "1.0.0-rc.1", "01.0.0", "-1.0.0", "1.0.0/path", "1.0.٠", "999999999999999999999.0.0"] {
            XCTAssertNil(ReleaseVersion(invalid), invalid)
        }
        XCTAssertThrowsError(try AppUpdateClient(repository: "../../wrong"))
        let source = URL(string: api)!
        XCTAssertFalse(AppUpdateClient.allowsRedirect(from: source, to: URL(string: "https://example.com")))
        XCTAssertFalse(AppUpdateClient.allowsRedirect(from: source, to: URL(string: "http://api.github.com/path")))
        XCTAssertTrue(AppUpdateClient.allowsRedirect(from: source, to: source))
        XCTAssertTrue(AppUpdateClient.allowsRedirect(from: URL(string: base), to: URL(string: "https://release-assets.githubusercontent.com/path")))
        XCTAssertFalse(AppUpdateClient.allowsRedirect(from: URL(string: base), to: URL(string: "https://githubusercontent.com.example.com/path")))
    }

    func testVerifiedInstallerKeepsQuarantineAndAvoidsCollisions() async throws {
        try prepare()
        let client = try client()
        let found = try await client.latest(after: ReleaseVersion("1.0.0")!, architecture: "arm64")
        let update = try XCTUnwrap(found)
        XCTAssertEqual(update.minimumSystemVersion, ReleaseVersion("12.0.0"))
        let root = try temporaryDirectory()
        let first = try await client.download(update, into: root)
        let second = try await client.download(update, into: root)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first), installer)
        XCTAssertEqual(try Data(contentsOf: second), installer)
        XCTAssertGreaterThan(getxattr(first.path, "com.apple.quarantine", nil, 0, 0, 0), 0)
    }

    func testManifestIdentityCompatibilityAndDigestFailures() async throws {
        let client = try client()
        for mode in 0..<6 {
            try prepare(minimum: mode == 0 ? "twelve" : "12.0.0", product: mode == 1 ? "other.app" : "net.ptudor.Unsit",
                        digest: mode != 2, unsafe: mode == 3, prerelease: mode == 4, tamperManifest: mode == 5)
            await rejected { _ = try await client.latest(after: ReleaseVersion("1.0.0")!, architecture: "arm64") }
        }
    }

    func testDownloadLimitsDigestAndCancellationLeaveNoPartialFile() async throws {
        let client = try client(), root = try temporaryDirectory()
        for bytes in [Data("changed installer bytes!!".utf8), Data(installer.dropLast()), installer + Data([0])] {
            try prepare(download: bytes)
            let update = try await client.latest(after: ReleaseVersion("1.0.0")!, architecture: "arm64")!
            await rejected { _ = try await client.download(update, into: root) }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
        try prepare(declared: 256 * 1024 * 1024)
        let update = try await client.latest(after: ReleaseVersion("1.0.0")!, architecture: "arm64")!
        await rejected { _ = try await client.download(update, into: root) }
        try prepare()
        let task = Task { try await client.download(update, into: root) }
        task.cancel()
        await rejected { _ = try await task.value }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testNoReleaseIsDistinctFromCurrentVersionAndRollback() async throws {
        let client = try client()
        for status in [404, 500] {
            UpdateProtocol.set([api: .init(data: Data(), status: status)])
            await rejected { _ = try await client.latest(after: ReleaseVersion("1.0.0")!, architecture: "arm64") }
        }
        try prepare(arch: "universal")
        let universal = try await client.latest(after: ReleaseVersion("1.0.0")!, architecture: "x86_64")
        XCTAssertTrue(universal!.asset.name.contains("universal"))
        let current = try await client.latest(after: ReleaseVersion("1.2.3")!, architecture: "arm64")
        XCTAssertNil(current)
        await rejected { _ = try await client.latest(after: ReleaseVersion("1.0.0")!, architecture: "arm64", highestSeen: ReleaseVersion("2.0.0")!) }
    }
}
