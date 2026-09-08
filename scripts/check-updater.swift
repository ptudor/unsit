// Copyright (c) 2026 Patrick Tudor. SPDX-License-Identifier: MIT
// Compile with Sources/UnsitDesktop/AppUpdate.swift; see RELEASE.md.
import Foundation

@available(macOS 12.0, *)
@main
struct CheckUpdater {
    static func main() async throws {
        var values: [String: String] = [:]
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count.isMultiple(of: 2) else { throw UpdateError("Expected --version VERSION --arch ARCH --directory PATH") }
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let option = arguments[index]
            guard ["--version", "--arch", "--directory"].contains(option), values[option] == nil else {
                throw UpdateError("Unknown or repeated option: \(option)")
            }
            values[option] = arguments[index + 1]
        }
        guard let versionText = values["--version"], let expected = ReleaseVersion(versionText),
              let architecture = values["--arch"], ["arm64", "x86_64"].contains(architecture),
              let directory = values["--directory"] else {
            throw UpdateError("Expected --version VERSION --arch arm64|x86_64 --directory PATH")
        }
        let client = try AppUpdateClient(repository: "ptudor/unsit")
        guard let update = try await client.latest(after: ReleaseVersion("0.0.0")!, architecture: architecture),
              update.version == expected else { throw UpdateError("The public stable feed does not offer the expected version.") }
        let installer = try await client.download(update, into: URL(fileURLWithPath: directory, isDirectory: true))
        guard try await client.latest(after: expected, architecture: architecture, highestSeen: expected) == nil else {
            throw UpdateError("The released version was offered another update.")
        }
        print("PASS: \(expected) \(architecture), manifest and installer digests, quarantined download, and current-version check")
        print(installer.path)
    }
}
