import Foundation
import XCTest
@testable import UnsitDesktop

@available(macOS 12.0, *)
@MainActor
final class AppUpdateControllerTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "unsit-update-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
    private func update(minimum: String = "12.0.0") -> AppUpdate {
        AppUpdate(version: ReleaseVersion("2.0.0")!, minimumSystemVersion: ReleaseVersion(minimum)!,
                  asset: UpdateAsset(name: "test.dmg", size: 1, digest: nil, browser_download_url: URL(string: "https://example.com/test.dmg")!),
                  releaseNotes: URL(string: "https://example.com/release")!)
    }
    func testAutomaticFailureBackoffManualRetryAndSuccessInterval() async {
        var now = Date(timeIntervalSince1970: 10_000), attempts = 0, fail = true
        let defaults = defaults()
        let controller = AppUpdateController(defaults: defaults, current: ReleaseVersion("1.0.0")!, system: ReleaseVersion("26.0.0")!,
            automaticByDefault: true, now: { now }, fetch: { _, _ in
                attempts += 1
                if fail { throw UpdateError("offline") }
                return nil
            }, download: { _ in throw UpdateError("unexpected download") })
        await controller.checkIfDue()
        XCTAssertEqual(attempts, 1); XCTAssertNil(controller.lastChecked)
        await controller.checkIfDue(); XCTAssertEqual(attempts, 1)
        now.addTimeInterval(899)
        await controller.checkIfDue(); XCTAssertEqual(attempts, 1)
        await controller.checkNow(); XCTAssertEqual(attempts, 2)
        now.addTimeInterval(901); fail = false
        await controller.checkIfDue(); XCTAssertEqual(attempts, 3)
        XCTAssertEqual(controller.lastChecked, now)
        now.addTimeInterval(900)
        await controller.checkIfDue(); XCTAssertEqual(attempts, 3)
        controller.automaticChecks = false
        now.addTimeInterval(100_000)
        await controller.checkIfDue(); XCTAssertEqual(attempts, 3)
        XCTAssertEqual(defaults.object(forKey: "updates.automatic") as? Bool, false)
    }
    func testNewerOSAdvisoryAndHighestVersionSurviveChecks() async {
        let defaults = defaults(), update = update(minimum: "99.0.0")
        var highest: ReleaseVersion?
        let controller = AppUpdateController(defaults: defaults, current: ReleaseVersion("1.0.0")!, system: ReleaseVersion("26.0.0")!,
            automaticByDefault: false, fetch: { _, seen in highest = seen; return update },
            download: { _ in XCTFail("Incompatible update must not download"); throw UpdateError("unexpected download") })
        await controller.checkNow()
        XCTAssertTrue(controller.requiresNewerOS)
        XCTAssertTrue(controller.message.contains("requires macOS"))
        let downloaded = await controller.downloadUpdate(); XCTAssertNil(downloaded)
        await controller.checkNow()
        XCTAssertEqual(highest, update.version)
    }
    func testFailedDownloadIsNeverOfferedAsAnInstaller() async {
        let update = update()
        let controller = AppUpdateController(defaults: defaults(), current: ReleaseVersion("1.0.0")!, system: ReleaseVersion("26.0.0")!,
            automaticByDefault: false, fetch: { _, _ in update }, download: { _ in throw UpdateError("hash mismatch") })
        await controller.checkNow()
        let result = await controller.downloadUpdate()
        XCTAssertNil(result); XCTAssertNil(controller.downloaded)
        XCTAssertFalse(controller.isDownloading)
        XCTAssertTrue(controller.message.contains("hash mismatch"))
    }
}
