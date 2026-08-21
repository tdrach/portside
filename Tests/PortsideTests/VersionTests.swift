import XCTest
@testable import Portside

final class VersionTests: XCTestCase {
    func testVersionIsSemver() {
        XCTAssertNotNil(AppVersion.current.range(
            of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression
        ))
    }

    func testDiagnosticsHelpers() {
        XCTAssertFalse(Diagnostics.hardwareModel().isEmpty)
        XCTAssertTrue(["arm64", "x86_64"].contains(Diagnostics.architecture()))
    }
}
