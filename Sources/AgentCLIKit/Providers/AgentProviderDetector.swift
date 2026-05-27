import Foundation

/// Service that detects whether registered provider executables are available.
public struct AgentProviderDetector: Sendable {
    /// Fallback directories checked after PATH and login-shell lookup.
    public static let defaultFallbackExecutableDirectories: [String] = [
        "~/.local/bin",
        "~/.claude/local",
        "/opt/homebrew/bin",
        "/usr/local/bin"
    ]

    private let shellRunner: any ShellRunning
    private let fallbackExecutableDirectories: [String]
    private let loginShellExecutablePaths: [String]
    private let homeDirectory: URL

    /// Creates a provider detector.
    public init(
        shellRunner: any ShellRunning = ProcessShellRunner(),
        fallbackExecutableDirectories: [String] = Self.defaultFallbackExecutableDirectories,
        loginShellExecutablePaths: [String] = Self.defaultLoginShellExecutablePaths(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.shellRunner = shellRunner
        self.fallbackExecutableDirectories = fallbackExecutableDirectories
        self.loginShellExecutablePaths = loginShellExecutablePaths
        self.homeDirectory = homeDirectory
    }

    /// Detects availability for a single provider definition.
    public func availability(for definition: AgentProviderDefinition) async -> AgentProviderAvailability {
        for executable in definition.executableNames {
            if let path = await resolveExecutable(executable) {
                let version = await versionDescription(for: path, arguments: definition.versionArguments)
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
            return executablePathIfRunnable(AgentPathHelpers.expandingTilde(in: executable, homeDirectory: homeDirectory).path)
        }
        do {
            let result = try await shellRunner.run(ShellCommand(executable: "/usr/bin/env", arguments: ["which", executable]))
            let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.exitCode == 0 && !path.isEmpty {
                return path
            }
        } catch {
            // Fall through to login-shell and fallback-directory lookup below.
        }

        if let path = await resolveExecutableWithLoginShell(executable) {
            return path
        }

        for directory in fallbackExecutableDirectories {
            let candidate = AgentPathHelpers.expandingTilde(in: directory, homeDirectory: homeDirectory)
                .appendingPathComponent(executable)
                .path
            if let path = executablePathIfRunnable(candidate) {
                return path
            }
        }

        return nil
    }

    private func executablePathIfRunnable(_ executable: String) -> String? {
        let url = AgentPathHelpers.canonicalFileURL(URL(fileURLWithPath: executable))
        var isDirectory: ObjCBool = false
        // Provider definitions may pin an exact CLI path; those should not depend on PATH lookup.
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: url.path) else {
            return nil
        }
        return url.path
    }

    private func resolveExecutableWithLoginShell(_ executable: String) async -> String? {
        let outputPrefix = "__AGENTCLIKIT_EXECUTABLE_PATH__"
        let command = "resolved=$(command -v \(shellQuoted(executable))) && printf '%s%s\\n' '\(outputPrefix)' \"$resolved\""
        for shellPath in loginShellExecutablePaths where FileManager.default.isExecutableFile(atPath: shellPath) {
            do {
                let result = try await shellRunner.run(ShellCommand(executable: shellPath, arguments: ["-lc", command]))
                guard result.exitCode == 0,
                      let resolvedPath = result.stdout
                      .split(whereSeparator: \.isNewline)
                      .first(where: { $0.hasPrefix(outputPrefix) })?
                      .dropFirst(outputPrefix.count)
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                      let executablePath = executablePathIfRunnable(resolvedPath) else {
                    continue
                }
                return executablePath
            } catch {
                continue
            }
        }
        return nil
    }

    private func versionDescription(for executablePath: String, arguments: [String]) async -> String? {
        do {
            let result = try await shellRunner.run(ShellCommand(executable: executablePath, arguments: arguments))
            let output = result.stdout.isEmpty ? result.stderr : result.stdout
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return result.exitCode == 0 && !trimmed.isEmpty ? trimmed : nil
        } catch {
            return nil
        }
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// Returns login-shell paths checked after direct PATH lookup.
    public static func defaultLoginShellExecutablePaths() -> [String] {
        var paths: [String] = []
        if let shell = ProcessInfo.processInfo.environment["SHELL"],
           !shell.isEmpty {
            paths.append(shell)
        }
        paths.append(contentsOf: ["/bin/zsh", "/bin/bash"])
        return paths.reduce(into: []) { uniquePaths, path in
            if !uniquePaths.contains(path) {
                uniquePaths.append(path)
            }
        }
    }
}
