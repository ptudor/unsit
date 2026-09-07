import Foundation
import XCTest
@testable import UnsitDesktop

final class ExtractionOperationTests: XCTestCase {
    private var binary: URL { Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("unsit") }
    private func sandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("unsit-desktop-test-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }
    func testPackagedHelperContractAndRepeatedExtraction() throws {
        let root = try sandbox()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("unsitTests/Fixtures/valid_preset_1.sit")
        let archive = root.appendingPathComponent("--a sample.sit")
        try FileManager.default.copyItem(at: fixture, to: archive)
        let original = try Data(contentsOf: archive)
        let first = try ExtractionOperation().run(archive: archive, destination: root, executable: binary)
        let second = try ExtractionOperation().run(archive: archive, destination: root, executable: binary)
        XCTAssertEqual(first.status, 0, first.details)
        XCTAssertEqual(second.status, 0, second.details)
        XCTAssertNotEqual(first.output, second.output)
        for output in [try XCTUnwrap(first.output), try XCTUnwrap(second.output)] {
            XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("f")), Data("AAAAAAAB".utf8))
        }
        XCTAssertEqual(try Data(contentsOf: archive), original)
    }
    func testInvalidArchiveAndCancellationDoNotLeaveEmptyDestinations() throws {
        let root = try sandbox()
        let archive = root.appendingPathComponent("bad.sit")
        try Data([1, 2, 3]).write(to: archive)
        let failed = try ExtractionOperation().run(archive: archive, destination: root, executable: binary)
        XCTAssertNotEqual(failed.status, 0)
        XCTAssertNil(failed.output)
        XCTAssertFalse(failed.details.isEmpty)
        let cancelled = ExtractionOperation()
        cancelled.cancel()
        XCTAssertTrue(try cancelled.run(archive: archive, destination: root, executable: binary).cancelled)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["bad.sit"])
    }

    func testCancellationStopsRunningHelperAndRetainsPublishedOutput() throws {
        let root = try sandbox()
        let archive = root.appendingPathComponent("sample.sit")
        try Data().write(to: archive)
        let helper = root.appendingPathComponent("slow-helper")
        try Data("#!/bin/sh\n/bin/mkdir \"$4/ready\"\nexec /bin/sleep 30\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let operation = ExtractionOperation()
        let finished = expectation(description: "Cancelled helper exits promptly")
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do {
                let result = try operation.run(archive: archive, destination: root, executable: helper)
                XCTAssertTrue(result.cancelled)
                let output = try XCTUnwrap(result.output)
                XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("ready").path))
            } catch { XCTFail(String(describing: error)) }
        }
        let ready = root.appendingPathComponent("sample (extracted)/ready")
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: ready.path) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        operation.cancel()
        wait(for: [finished], timeout: 5)
        XCTAssertThrowsError(try operation.run(archive: archive, destination: root, executable: helper))
    }
}
