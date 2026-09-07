import Foundation
import XCTest
import UnsitReport
@testable import unsit

final class ReportTests: XCTestCase {
    private func report(_ bytes: [UInt8], flags: [String] = []) throws -> (ExtractionReport, String) {
        let result = try Sandbox().run(bytes, ["--json"] + flags)
        let report = try JSONDecoder().decode(ExtractionReport.self, from: Data(result.1.utf8))
        XCTAssertEqual(report.status, result.0)
        XCTAssertEqual(report.schemaVersion, 1)
        return (report, result.2)
    }

    func testCountsPublishedMembersAndDamagedForksSeparately() throws {
        let bytes = Fixture.archive([
            Fixture.member("good", data: [1], rsrc: [2]),
            Fixture.member("damaged", data: [3], rsrc: [4], dataCRC: 0, rsrcCRC: 0),
        ])
        let (r, warnings) = try report(bytes)
        XCTAssertTrue(r.damageDetected)
        XCTAssertEqual(r.completeFiles, 1)
        XCTAssertEqual(r.partialFiles, 1)
        XCTAssertEqual(r.damagedForks, 2)
        XCTAssertEqual(r.recoveredFiles, 2)
        XCTAssertEqual(r.failedFiles, 0)
        XCTAssertTrue(warnings.contains("Unsit recovered 2 file(s): 1 complete, 1 partial"))
        let quiet = try report(bytes, flags: ["--quiet"])
        XCTAssertTrue(quiet.1.contains("possible bitrot"))
    }

    func testCreditForRecoveryAcrossHeaderDamageAndTerminalGaps() throws {
        let (r, warnings) = try report(Fixture.archive([
            Fixture.member("first", data: [1]), [UInt8](repeating: 63, count: 17),
            Fixture.member("later", data: [2]),
        ], count: 2))
        XCTAssertTrue(r.archiveStructureDamaged)
        XCTAssertEqual(r.damagedHeaderGaps, 1)
        XCTAssertEqual(r.skippedArchiveBytes, 17)
        XCTAssertEqual(r.recoveredAfterDamage, 1)
        XCTAssertEqual(r.completeFiles, 2)
        XCTAssertEqual(r.damagedForks, 0)
        XCTAssertTrue(warnings.contains("1 file(s) recovered beyond damaged archive records"))
        let terminal = try report(Fixture.archive([Fixture.member(data: [1]), [63, 63, 63]], count: 1)).0
        XCTAssertTrue(terminal.damageDetected)
        XCTAssertEqual(terminal.damagedHeaderGaps, 1)
        XCTAssertEqual(terminal.skippedArchiveBytes, 3)
    }

    func testUnsupportedMethodsAndUnverifiedCountsAreNotCalledBitrot() throws {
        let unsupported = try report(Fixture.archive([Fixture.member(data: [1], dm: 99)]))
        XCTAssertFalse(unsupported.0.damageDetected)
        XCTAssertEqual(unsupported.0.unsupportedForks, 1)
        XCTAssertEqual(unsupported.0.failedFiles, 1)
        XCTAssertFalse(unsupported.1.contains("CRC mismatch"))
        XCTAssertFalse(unsupported.1.contains("bitrot"))
        var version = Fixture.archive([Fixture.member(data: [1])]); version[14] = 2
        let unverified = try report(version).0
        XCTAssertTrue(unverified.archiveValidationIncomplete)
        XCTAssertFalse(unverified.damageDetected)
        XCTAssertEqual(unverified.completeFiles, 1)
        let limited = try report(Fixture.archive([Fixture.member(data: [1, 2])]), flags: ["--max-fork-bytes", "1"]).0
        XCTAssertFalse(limited.damageDetected)
        XCTAssertEqual(limited.failedFiles, 1)
    }

    func testCleanQuietReportEarlyFailureAndUsageConflict() throws {
        let clean = try report(Fixture.archive([Fixture.member(data: [1])]), flags: ["--quiet"])
        XCTAssertEqual(clean.0.status, 0)
        XCTAssertFalse(clean.0.damageDetected)
        XCTAssertTrue(clean.1.isEmpty)
        let skipped = try report(Fixture.archive([Fixture.member(data: [1], dataCRC: 0)]), flags: ["--no-verify"]).0
        XCTAssertTrue(skipped.forkChecksSkipped)
        XCTAssertFalse(skipped.damageDetected)
        let failure = try report([1, 2, 3]).0
        XCTAssertEqual(failure.status, 1)
        XCTAssertNotNil(failure.problem)
        XCTAssertFalse(failure.damageDetected)
        let conflict = try Sandbox().run(Fixture.archive([]), ["--json", "--list"])
        XCTAssertEqual(conflict.0, 2)
        XCTAssertTrue(conflict.1.isEmpty)
    }

    func testDamageAndRecoveryCreditSurviveLaterTraversalFailure() throws {
        let bytes = Fixture.archive([Fixture.member("saved", data: [1], dataCRC: 0), Fixture.member("later", data: [2])])
        let (r, warnings) = try report(bytes, flags: ["--max-members", "1", "--quiet"])
        XCTAssertEqual(r.partialFiles, 1)
        XCTAssertNotNil(r.problem)
        XCTAssertTrue(r.damageDetected)
        XCTAssertTrue(warnings.contains("Unsit recovered 1 file(s): 0 complete, 1 partial"))
        let gap = Fixture.archive([[UInt8](repeating: 63, count: 17), Fixture.member(data: [1])], count: 1)
        let stopped = try report(gap, flags: ["--max-recovery-bytes", "0"]).0
        XCTAssertTrue(stopped.archiveStructureDamaged)
        XCTAssertEqual(stopped.damagedHeaderGaps, 1)
        XCTAssertEqual(stopped.recoveredFiles, 0)
    }
}
