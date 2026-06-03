import XCTest

@testable import AgentCLIKit

final class AgentProjectTrustServiceTests: XCTestCase {
    func testDefaultServiceTreatsProvidersWithoutSetupAsNotRequiringTrust() async {
        let service = DefaultAgentProjectTrustService()
        let projectURL = URL(fileURLWithPath: "/tmp/project")

        XCTAssertEqual(service.cachedStatus(providerId: .claude, projectURL: projectURL), .notRequired)
        let status = await service.status(providerId: .claude, projectURL: projectURL)

        XCTAssertEqual(status, .notRequired)
        XCTAssertTrue(status.allowsProviderWork)
    }

    func testDefaultServiceDelegatesToProviderSetup() async throws {
        let setup = RecordingProviderSetup(providerId: .claude)
        let service = DefaultAgentProjectTrustService(setups: [setup])
        let projectURL = URL(fileURLWithPath: "/tmp/project")

        XCTAssertEqual(service.cachedStatus(providerId: .claude, projectURL: projectURL), .notTrusted)
        let statusBeforeTrust = await service.status(providerId: .claude, projectURL: projectURL)
        XCTAssertEqual(statusBeforeTrust, .notTrusted)

        try await service.trustProject(providerId: .claude, projectURL: projectURL)

        XCTAssertEqual(service.cachedStatus(providerId: .claude, projectURL: projectURL), .trusted)
        let statusAfterTrust = await service.status(providerId: .claude, projectURL: projectURL)
        XCTAssertEqual(statusAfterTrust, .trusted)
    }
}

private final class RecordingProviderSetup: AgentProviderSetup, @unchecked Sendable {
    let providerId: AgentProviderID
    private let lock = NSLock()
    private var trustedProjects = Set<String>()

    init(providerId: AgentProviderID) {
        self.providerId = providerId
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
