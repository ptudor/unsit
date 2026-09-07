// Copyright (c) 2026 Patrick Tudor. SPDX-License-Identifier: MIT
import Foundation

/// Versioned CLI output shared with the desktop app. Counts refer to published
/// member files, not forks; damagedForks counts each affected fork once.
public struct ExtractionReport: Codable, Sendable {
    public var schemaVersion = 1
    public var status: Int32 = 1
    public var outputDirectory: String?
    public var completeFiles = 0
    public var partialFiles = 0
    public var failedFiles = 0
    public var damagedForks = 0
    public var unsupportedForks = 0
    public var recoveredAfterDamage = 0
    public var damagedHeaderGaps = 0
    public var skippedArchiveBytes = 0
    public var archiveStructureDamaged = false
    public var archiveValidationIncomplete = false
    public var forkChecksSkipped = false
    public var restorationFailures = 0
    public var problem: String?

    public init() {}
    public var recoveredFiles: Int { completeFiles + partialFiles }
    public var damageDetected: Bool { damagedForks > 0 || archiveStructureDamaged }

    public var headline: String {
        let noun = recoveredFiles == 1 ? "file" : "files"
        if damageDetected {
            return recoveredFiles > 0
                ? "Unsit recovered \(recoveredFiles) \(noun) despite archive damage"
                : "Archive damage detected; no files recovered"
        }
        if status != 0 && recoveredFiles == 0 { return "Couldn’t extract any files" }
        return status == 0 ? "Extracted \(recoveredFiles) \(noun)" : "Saved \(recoveredFiles) \(noun) with warnings"
    }

    public var fileSummary: String {
        "\(completeFiles) complete · \(partialFiles) partial · \(failedFiles) not saved"
    }
}
