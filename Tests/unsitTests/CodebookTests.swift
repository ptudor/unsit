import CryptoKit
import Foundation
import XCTest
@testable import unsit

final class CodebookTests: XCTestCase {
    func testEveryPresetSymbolAgainstFrozenOracleVerifiedForks() throws {
        struct Expected: Decodable { let length: Int; let sha256: String }
        let manifest = Bundle.module.url(forResource: "codebooks", withExtension: "json", subdirectory: "Fixtures")!
        let expected = try JSONDecoder().decode([String: Expected].self, from: Data(contentsOf: manifest))
        for name in expected.keys.sorted() {
            let result = try XCTUnwrap(expected[name])
            let sandbox = try Sandbox()
            let extraction = try sandbox.run(Fixture.golden(name))
            XCTAssertEqual(extraction.0, 0, extraction.2)
            for path in ["f", "f/..namedfork/rsrc"] {
                let data = Data(try sandbox.bytes(path))
                XCTAssertEqual(data.count, result.length)
                XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), result.sha256)
            }
        }
    }
}
