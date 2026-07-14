import Foundation
import XCTest

@testable import AgentCLIKit

final class CodexCodeModeHostConfigurationTests: XCTestCase {
    func testInjectsCodeModeHostBesideCanonicalCodexExecutable() async throws {
        let installation = try CodexTestInstallation.make()
        defer { try? FileManager.default.removeItem(at: installation.root) }
        let resolver = RecordingExecutableResolver(path: installation.symlink.path)
        let configuration = CodexProviderAdapter.Configuration(executableResolver: resolver)

        let resolved = await configuration.resolvingExecutableIfNeeded(for: CodexProviderDefinition.definition)

        XCTAssertEqual(resolved.executablePath, installation.symlink.path)
        XCTAssertEqual(
            resolved.environment["CODEX_CODE_MODE_HOST_PATH"],
            installation.codeModeHost.path
        )
    }

    func testPreservesExplicitCodeModeHostOverride() async throws {
        let installation = try CodexTestInstallation.make()
        defer { try? FileManager.default.removeItem(at: installation.root) }
        let configuration = CodexProviderAdapter.Configuration(
            executablePath: installation.symlink.path,
            environment: ["CODEX_CODE_MODE_HOST_PATH": "/custom/codex-code-mode-host"]
        )

        let resolved = await configuration.resolvingExecutableIfNeeded(for: CodexProviderDefinition.definition)

        XCTAssertEqual(
            resolved.environment["CODEX_CODE_MODE_HOST_PATH"],
            "/custom/codex-code-mode-host"
        )
    }
}

private struct CodexTestInstallation {
    let root: URL
    let symlink: URL
    let codeModeHost: URL

    static func make() throws -> Self {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let installationDirectory = root.appendingPathComponent("installation/bin", isDirectory: true)
        let linkDirectory = root.appendingPathComponent("links", isDirectory: true)
        try FileManager.default.createDirectory(at: installationDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linkDirectory, withIntermediateDirectories: true)

        let codexExecutable = installationDirectory.appendingPathComponent("codex")
        let codeModeHost = installationDirectory.appendingPathComponent("codex-code-mode-host")
        for executable in [codexExecutable, codeModeHost] {
            try "#!/bin/sh\n".write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }

        let symlink = linkDirectory.appendingPathComponent("codex")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: codexExecutable)
        return Self(root: root, symlink: symlink, codeModeHost: codeModeHost)
    }
}
