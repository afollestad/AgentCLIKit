import XCTest

@testable import AgentCLIKit

final class AgentCLIKitSmokeTests: XCTestCase {
    func testPackageMetadataName() {
        XCTAssertEqual(AgentCLIKitMetadata.name, "AgentCLIKit")
    }
}
