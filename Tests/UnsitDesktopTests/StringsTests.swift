import Foundation
import XCTest
@testable import UnsitDesktop

final class StringsTests: XCTestCase {
    /// A bundle holding one "Probe" table, laid out the way scripts/package.py
    /// lays out the app's compiled catalogs.
    private func bundle(strings: [String: String] = [:], plurals: [String: [String: String]] = [:]) throws -> Bundle {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("unsit-strings-test-" + UUID().uuidString + ".bundle")
        let tables = root.appendingPathComponent("en.lproj")
        try FileManager.default.createDirectory(at: tables, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let rules = plurals.mapValues { forms -> [String: Any] in
            let value = forms.merging(["NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": "lld"]) { form, _ in form }
            return ["NSStringLocalizedFormatKey": "%#@value@", "value": value]
        }
        for (name, contents) in [("Probe.strings", strings as [String: Any]), ("Probe.stringsdict", rules)] {
            try PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0)
                .write(to: tables.appendingPathComponent(name))
        }
        return try XCTUnwrap(Bundle(url: root))
    }

    func testPluralFormFollowsTheCount() throws {
        let tables = try bundle(plurals: ["Extracted %lld files": ["one": "Extracted %lld file", "other": "Extracted %lld files"]])
        XCTAssertEqual(Strings.lookup("Extracted %lld files", table: "Probe", arguments: [1], bundle: tables), "Extracted 1 file")
        XCTAssertEqual(Strings.lookup("Extracted %lld files", table: "Probe", arguments: [2], bundle: tables), "Extracted 2 files")
    }

    func testTranslationMayReorderArguments() throws {
        let tables = try bundle(strings: ["Unsit %1$@ requires macOS %2$@": "macOS %2$@ is required by Unsit %1$@"])
        XCTAssertEqual(Strings.lookup("Unsit %1$@ requires macOS %2$@", table: "Probe", arguments: ["1.2.0", "13.0"], bundle: tables),
                       "macOS 13.0 is required by Unsit 1.2.0")
    }

    func testTextWithoutArgumentsIsNotAFormat() throws {
        let tables = try bundle(strings: ["Ready": "100% ready %@"])
        XCTAssertEqual(Strings.lookup("Ready", table: "Probe", arguments: [], bundle: tables), "100% ready %@")
    }

    func testMissingTranslationFallsBackToTheEnglishKey() throws {
        let tables = try bundle()
        XCTAssertEqual(Strings.lookup("Downloading Unsit %@…", table: "Probe", arguments: ["1.2.0"], bundle: tables), "Downloading Unsit 1.2.0…")
        XCTAssertEqual(Strings.updates("Unsit is up to date."), "Unsit is up to date.")
    }
}
