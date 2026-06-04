import Foundation

@testable import AgentCLIKit

actor RecordingExecutableResolver: AgentProviderExecutableResolving {
    private let path: String?
    private(set) var requestedDefinitions: [AgentProviderDefinition] = []

    init(path: String?) {
        self.path = path
    }

    func resolvedExecutablePath(for definition: AgentProviderDefinition) async -> String? {
        requestedDefinitions.append(definition)
        return path
    }
}

final class CodexTransportConfigurationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedConfigurations: [CodexProviderAdapter.Configuration] = []

    var executablePaths: [String] {
        lock.withLock {
            recordedConfigurations.map(\.executablePath)
        }
    }

    func record(_ configuration: CodexProviderAdapter.Configuration) {
        lock.withLock {
            recordedConfigurations.append(configuration)
        }
    }
}
