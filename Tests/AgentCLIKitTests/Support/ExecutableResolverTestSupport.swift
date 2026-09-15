import Foundation

@testable import AgentCLIKit

actor RecordingExecutableResolver: AgentHarnessExecutableResolving {
    private let path: String?
    private(set) var requestedDefinitions: [AgentHarnessDefinition] = []

    init(path: String?) {
        self.path = path
    }

    func resolvedExecutablePath(for definition: AgentHarnessDefinition) async -> String? {
        requestedDefinitions.append(definition)
        return path
    }
}

final class CodexTransportConfigurationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedConfigurations: [CodexHarnessAdapter.Configuration] = []

    var executablePaths: [String] {
        lock.withLock {
            recordedConfigurations.map(\.executablePath)
        }
    }

    func record(_ configuration: CodexHarnessAdapter.Configuration) {
        lock.withLock {
            recordedConfigurations.append(configuration)
        }
    }
}
