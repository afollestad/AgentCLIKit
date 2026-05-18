import Foundation

/// Service that detects whether registered provider executables are available.
public struct AgentProviderDetector: Sendable {
    private let shellRunner: any ShellRunning

    /// Creates a provider detector.
    public init(shellRunner: any ShellRunning = ProcessShellRunner()) {
        self.shellRunner = shellRunner
    }

    /// Detects availability for a single provider definition.
    public func availability(for definition: AgentProviderDefinition) async -> AgentProviderAvailability {
        for executable in definition.executableNames {
            if let path = await resolveExecutable(executable) {
                let version = await versionDescription(for: path)
                return AgentProviderAvailability(providerId: definition.id, executablePath: path, versionDescription: version)
            }
        }
        return AgentProviderAvailability(providerId: definition.id, executablePath: nil)
    }

    /// Detects availability for every registered provider.
    public func availability(for definitions: [AgentProviderDefinition]) async -> [AgentProviderAvailability] {
        var results: [AgentProviderAvailability] = []
        for definition in definitions {
            results.append(await availability(for: definition))
        }
        return results
    }

    private func resolveExecutable(_ executable: String) async -> String? {
        if executable.contains("/") {
            return executablePathIfRunnable(executable)
        }
        do {
            let result = try await shellRunner.run(ShellCommand(executable: "/usr/bin/env", arguments: ["which", executable]))
            let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return result.exitCode == 0 && !path.isEmpty ? path : nil
        } catch {
            return nil
        }
    }

    private func executablePathIfRunnable(_ executable: String) -> String? {
        let url = URL(fileURLWithPath: executable).standardizedFileURL
        var isDirectory: ObjCBool = false
        // Provider definitions may pin an exact CLI path; those should not depend on PATH lookup.
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: url.path) else {
            return nil
        }
        return url.path
    }

    private func versionDescription(for executablePath: String) async -> String? {
        do {
            let result = try await shellRunner.run(ShellCommand(executable: executablePath, arguments: ["--version"]))
            let output = result.stdout.isEmpty ? result.stderr : result.stdout
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return result.exitCode == 0 && !trimmed.isEmpty ? trimmed : nil
        } catch {
            return nil
        }
    }
}
