import Foundation

/// Provider setup service for host-controlled preparation before launch.
public protocol AgentProviderSetup: Sendable {
    /// Provider identifier this setup service manages.
    var providerId: AgentProviderID { get }

    /// Marks a working directory as trusted for the provider when supported.
    func trustProject(at projectURL: URL) async throws
}
