import XCTest

@testable import AgentCLIKit

final class OpenCodeOneShotProviderTests: XCTestCase {
    func testCopiesOnlySelectedProviderAndAuthWithoutLoadingProjectOrExtensions() throws {
        let root = try temporaryDirectory()
        let config = root.appendingPathComponent(".config/opencode/opencode.jsonc")
        let original = #"""
        {
          // Unrelated setup must never enter the isolated worker.
          "plugin": ["file:///untrusted/plugin.ts"],
          "mcp": {"host": {"type":"local", "command":["touch", "marker"]}},
          "instructions": ["{file:missing-instructions}"],
          "provider": {
            "alpha": {"options":{"baseURL":"https://example.invalid/v1", "apiKey":"{env:CUSTOM_KEY}"},
                      "models":{"model":{"name":"Configured model"},"unrelated":{"provider":{"npm":"file:///bad.js"}}}},
            "beta": {"options":{"apiKey":"do-not-copy"}}
          }
        }
        """#
        try write(original, to: config)
        let workspace = root.appendingPathComponent("project")
        try write(#"{"provider":{"alpha":{"options":{"baseURL":"https://wrong.invalid"}}}}"#,
                  to: workspace.appendingPathComponent("opencode.json"))
        let auth = root.appendingPathComponent(".local/share/opencode/auth.json")
        try write(#"{"alpha":{"type":"api","key":"selected"},"beta":{"type":"api","key":"other"}}"#, to: auth)
        let loaded = try OpenCodeOneShotProviderConfiguration.load(
            model: "alpha/model", environment: ["HOME": root.path, "CUSTOM_KEY": "quoted\"\nvalue", "BETA_API_KEY": "other"],
            workingDirectory: workspace, managedConfigPaths: []
        )

        XCTAssertEqual(Set(loaded.configuration.keys), ["provider"])
        XCTAssertEqual(Set(loaded.configuration["provider"]?.ocObject?.keys.map { $0 } ?? []), ["alpha"])
        let options = loaded.configuration["provider"]?[oc: "alpha"]?[oc: "options"]
        XCTAssertEqual(options?[oc: "apiKey"], .string("quoted\"\nvalue"))
        XCTAssertEqual(options?[oc: "baseURL"], .string("https://example.invalid/v1"))
        XCTAssertNil(loaded.configuration["provider"]?[oc: "alpha"]?[oc: "models"]?[oc: "unrelated"])
        XCTAssertEqual(loaded.authentication, .object(["alpha": .object(["type": .string("api"), "key": .string("selected")])]))
        XCTAssertTrue(loaded.providerEnvironment.isEmpty)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), original)
    }

    func testMergesExplicitAndInlineProviderOverridesAndResolvesCredentialFilesAtTheirSource() throws {
        let root = try temporaryDirectory()
        let configDirectory = root.appendingPathComponent(".config/opencode")
        try write(#"{"provider":{"openai":{"options":{"apiKey":"{file:{env:KEY_FILE}}","baseURL":"https://old.invalid"}}}}"#,
                  to: configDirectory.appendingPathComponent("config.json"))
        try write("file-key\n", to: configDirectory.appendingPathComponent("key.txt"))
        try write(#"{"provider":{"openai":{"options":{"baseURL":"https://explicit.invalid"}}}}"#,
                  to: root.appendingPathComponent("explicit.json"))
        let loaded = try OpenCodeOneShotProviderConfiguration.load(
            model: "openai/model", environment: [
                "HOME": root.path, "OPENCODE_CONFIG": "explicit.json", "KEY_FILE": "key.txt",
                "OPENCODE_CONFIG_CONTENT": #"{"provider":{"openai":{"options":{"headers":{"User-Agent":"isolated"}}}}}"#,
                "OPENAI_API_KEY": "selected-env", "ANTHROPIC_API_KEY": "unrelated-env", "NODE_OPTIONS": "--import=bad"
            ], workingDirectory: root, managedConfigPaths: []
        )

        let options = loaded.configuration["provider"]?[oc: "openai"]?[oc: "options"]
        XCTAssertEqual(options?[oc: "apiKey"], .string("file-key"))
        XCTAssertEqual(options?[oc: "baseURL"], .string("https://explicit.invalid"))
        XCTAssertEqual(options?[oc: "headers"]?[oc: "User-Agent"], .string("isolated"))
        XCTAssertEqual(loaded.providerEnvironment, ["OPENAI_API_KEY": "selected-env"])
    }

    func testMaterializesDeclaredCredentialWithoutForwardingExecutableEnvironmentControls() throws {
        let root = try temporaryDirectory()
        for key in ["CUSTOM_INFERENCE_KEY", "NODE_OPTIONS"] {
            let loaded = try OpenCodeOneShotProviderConfiguration.load(
                model: "custom/model", environment: [
                    "HOME": root.path, key: "selected-value",
                    "OPENCODE_CONFIG_CONTENT": "{\"provider\":{\"custom\":{\"env\":[\"\(key)\"]}}}"
                ], workingDirectory: root, managedConfigPaths: []
            )
            XCTAssertEqual(loaded.configuration["provider"]?[oc: "custom"]?[oc: "options"]?[oc: "apiKey"], .string("selected-value"))
            XCTAssertTrue(loaded.providerEnvironment.isEmpty)
        }
    }

    func testRefusesRemoteConfigurationAuthAndManagedOverrides() throws {
        let root = try temporaryDirectory()
        XCTAssertThrowsError(try OpenCodeOneShotProviderConfiguration.load(
            model: "alpha/model", environment: [
                "HOME": root.path, "OPENCODE_AUTH_CONTENT": #"{"alpha":{"type":"wellknown","key":"remote","token":"secret"}}"#
            ], workingDirectory: root, managedConfigPaths: []
        ))
        let managed = root.appendingPathComponent("managed.json")
        try write("{}", to: managed)
        XCTAssertThrowsError(try OpenCodeOneShotProviderConfiguration.load(
            model: "alpha/model", environment: ["HOME": root.path], workingDirectory: root, managedConfigPaths: [managed.path]
        ))
        XCTAssertThrowsError(try OpenCodeOneShotProviderConfiguration.load(
            model: "default", environment: ["HOME": root.path], workingDirectory: root, managedConfigPaths: []
        ))
    }

    func testStoredAuthenticationKeepsPrecedenceOverDeclaredEnvironmentKey() throws {
        let root = try temporaryDirectory()
        let loaded = try OpenCodeOneShotProviderConfiguration.load(
            model: "custom/model", environment: [
                "HOME": root.path, "CUSTOM_KEY": "environment-account",
                "OPENCODE_CONFIG_CONTENT": #"{"provider":{"custom":{"env":["CUSTOM_KEY"]}}}"#,
                "OPENCODE_AUTH_CONTENT": #"{"custom":{"type":"api","key":"stored-account"}}"#
            ], workingDirectory: root, managedConfigPaths: []
        )
        XCTAssertNil(loaded.configuration["provider"]?[oc: "custom"]?[oc: "options"]?[oc: "apiKey"])
        XCTAssertEqual(loaded.authentication?[oc: "custom"]?[oc: "key"], .string("stored-account"))
    }

    func testRejectsExecutableProviderExtensionsButAcceptsBundledSDKs() throws {
        let root = try temporaryDirectory()
        for provider in [
            #"{"npm":"file:///untrusted/provider.js"}"#,
            #"{"models":{"model":{"provider":{"npm":"untrusted-package"}}}}"#
        ] {
            XCTAssertThrowsError(try OpenCodeOneShotProviderConfiguration.load(
                model: "alpha/model", environment: ["HOME": root.path, "OPENCODE_CONFIG_CONTENT": "{\"provider\":{\"alpha\":\(provider)}}"],
                workingDirectory: root, managedConfigPaths: []
            ))
        }
        let loaded = try OpenCodeOneShotProviderConfiguration.load(
            model: "alpha/model", environment: [
                "HOME": root.path, "OPENCODE_CONFIG_CONTENT": #"{"provider":{"alpha":{"npm":"@ai-sdk/openai-compatible"}}}"#
            ], workingDirectory: root, managedConfigPaths: []
        )
        XCTAssertEqual(loaded.configuration["provider"]?[oc: "alpha"]?[oc: "npm"], .string("@ai-sdk/openai-compatible"))
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("opencode-provider-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func write(_ contents: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }
}
