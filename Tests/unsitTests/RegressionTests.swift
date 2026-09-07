import Foundation
import XCTest
@testable import unsit

final class RegressionTests: XCTestCase {
    func testStoredNativeForksAndCLI() throws {
        let s = try Sandbox()
        let result = try s.run(Fixture.archive([Fixture.member(data: Array("DATA".utf8), rsrc: Array("RESOURCE".utf8))]))
        XCTAssertEqual(result.0, 0, result.2)
        XCTAssertEqual(try s.bytes("f"), Array("DATA".utf8))
        XCTAssertEqual(try s.bytes("f/..namedfork/rsrc"), Array("RESOURCE".utf8))
        XCTAssertTrue(result.1.contains("Extracted 1 file(s)"))
        XCTAssertEqual(try s.command(["--self-test"]).0, 0)
    }
    func testPresetAndDynamicGoldenBytes() throws {
        for name in (1...5).map({ "valid_preset_\($0)" }) + ["valid_dynamic", "valid_dynamic_separate"] {
            let s = try Sandbox()
            let result = try s.run(Fixture.golden(name))
            XCTAssertEqual(result.0, 0, name + result.2)
            XCTAssertEqual(try s.bytes("f"), Array("AAAAAAAB".utf8), name)
        }
    }
}
