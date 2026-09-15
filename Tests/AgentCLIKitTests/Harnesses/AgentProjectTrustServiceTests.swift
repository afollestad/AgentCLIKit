import XCTest

@testable import AgentCLIKit

final class AgentProjectTrustServiceTests: XCTestCase {
    func testDefaultServiceTreatsHarnessesWithoutSetupAsNotRequiringTrust() async {
        let service = DefaultAgentProjectTrustService()
        let projectURL = URL(fileURLWithPath: "/tmp/project")

        XCTAssertEqual(service.cachedStatus(harnessId: .claude, projectURL: projectURL), .notRequired)
        let status = await service.status(harnessId: .claude, projectURL: projectURL)

        XCTAssertEqual(status, .notRequired)
        XCTAssertTrue(status.allowsHarnessWork)
    }

    func testDefaultServiceDelegatesToHarnessSetup() async throws {
        let setup = RecordingHarnessSetup(harnessId: .claude)
        let service = DefaultAgentProjectTrustService(setups: [setup])
        let projectURL = URL(fileURLWithPath: "/tmp/project")

        XCTAssertEqual(service.cachedStatus(harnessId: .claude, projectURL: projectURL), .notTrusted)
        let statusBeforeTrust = await service.status(harnessId: .claude, projectURL: projectURL)
        XCTAssertEqual(statusBeforeTrust, .notTrusted)

        try await service.trustProject(harnessId: .claude, projectURL: projectURL)

        XCTAssertEqual(service.cachedStatus(harnessId: .claude, projectURL: projectURL), .trusted)
        let statusAfterTrust = await service.status(harnessId: .claude, projectURL: projectURL)
        XCTAssertEqual(statusAfterTrust, .trusted)
    }
}

private final class RecordingHarnessSetup: AgentHarnessSetup, @unchecked Sendable {
    let harnessId: AgentHarnessID
    private let lock = NSLock()
    private var trustedProjects = Set<String>()

    init(harnessId: AgentHarnessID) {
        self.harnessId = harnessId
    }

    func cachedProjectTrustStatus(for projectURL: URL) -> AgentProjectTrustStatus {
        lock.withLock {
            trustedProjects.contains(projectURL.path) ? .trusted : .notTrusted
        }
    }

    func projectTrustStatus(for projectURL: URL) async throws -> AgentProjectTrustStatus {
        cachedProjectTrustStatus(for: projectURL)
    }

    func trustProject(at projectURL: URL) async throws {
        lock.withLock {
            _ = trustedProjects.insert(projectURL.path)
        }
    }
}
