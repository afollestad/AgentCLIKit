import XCTest

@testable import AgentCLIKit

final class OpenCodeMetadataTests: XCTestCase {
    func testOneShotCapabilityDefaultsOffAndSurvivesCapabilityOverlays() throws {
        let old = try JSONDecoder().decode(AgentHarnessCapabilities.self, from: Data("{}".utf8))
        XCTAssertFalse(old.supportsReadOnlyOneShotPrompts)
        for definition in [ClaudeHarnessDefinition.definition, CodexHarnessDefinition.definition, OpenCodeHarnessDefinition.definition] {
            let capabilities = definition.capabilities.withSpeedModeSupport(true).withGoalModeSupport(false, supportedGoalActions: [])
            let decoded = try JSONDecoder().decode(AgentHarnessCapabilities.self, from: JSONEncoder().encode(capabilities))
            XCTAssertTrue(decoded.supportsReadOnlyOneShotPrompts)
        }
        let openCode = OpenCodeHarnessDefinition.definition
        XCTAssertTrue(openCode.capabilities.supportsReadOnlyOneShotPrompts)
        XCTAssertFalse(openCode.capabilities.supportsHooks)
        XCTAssertFalse(openCode.capabilities.supportsGoalMode)
        XCTAssertFalse(openCode.capabilities.supportsSpeedMode)
        XCTAssertFalse(openCode.capabilities.supportsPermissionPrompts)
        XCTAssertEqual(openCode.supportedPermissionModes?.map(\.value), ["configured", "ask", "fullAccess"])
        XCTAssertEqual(OpenCodeHarnessDefinition.defaultPermissionMode, "ask")
    }

    func testVersionGateRejectsOldPrereleaseAndUnknownMajorVersions() throws {
        for supported in ["1.18.31", "v1.18.32", "1.19.0", "1.18.31+build"] {
            XCTAssertNoThrow(try OpenCodeVersionSupport.validate(supported))
        }
        for unsupported in ["1.18.30", "1.17.99", "2.0.0", "1.18.31-beta.1", "latest", "1.18", "-1.18.31"] {
            XCTAssertThrowsError(try OpenCodeVersionSupport.validate(unsupported), unsupported)
        }
    }

    func testDefaultModelRoutingKeepsOpenCodeDiscoveryStatic() async {
        let options = await DefaultAgentModelOptionSource().modelOptions(for: .opencode)
        XCTAssertEqual(options, AgentDefaultModelOptions.staticOptions(for: .opencode))
        XCTAssertEqual(options.count, 1)
        XCTAssertNil(options.first?.model)
        XCTAssertTrue(options.first?.isDefault == true)
        let capabilities = await DefaultAgentHarnessCapabilitySource().capabilities(
            for: OpenCodeHarnessDefinition.definition, availability: nil
        )
        XCTAssertEqual(capabilities, OpenCodeHarnessDefinition.definition.capabilities)
    }

    func testProviderModelsKeepIdentityVariantsAndActualImageCapabilities() throws {
        let models = try OpenCodeModelOptionSource.parseProviderResponse(openCodeProviderFixture())
        XCTAssertEqual(models.map(\.id), ["alpha/family/model", "beta/family/model"])
        let first = try XCTUnwrap(models.first)
        XCTAssertEqual(first.model, "alpha/family/model")
        XCTAssertEqual(first.shortName, "alpha/family/model")
        XCTAssertEqual(first.contextWindowSize, 200_000)
        XCTAssertEqual(first.supportedEffortOptions.map(\.value), ["high", "low"])
        XCTAssertEqual(first.metadata[OpenCodeModelMetadata.providerID], .string("alpha"))
        XCTAssertEqual(first.metadata[OpenCodeModelMetadata.modelID], .string("family/model"))
        XCTAssertEqual(first.metadata[OpenCodeModelMetadata.supportsImageInput], .bool(true))
        XCTAssertEqual(first.metadata[OpenCodeModelMetadata.inputTokenLimit], .number(180_000))
        XCTAssertEqual(first.metadata[OpenCodeModelMetadata.outputTokenLimit], .number(20_000))
        XCTAssertTrue(models.allSatisfy { !$0.isDefault })
        XCTAssertEqual(models.last?.metadata[OpenCodeModelMetadata.supportsImageInput], .bool(false))
    }

    func testInvalidProviderPayloadIsNotReportedAsSuccessfulEmptyCatalog() {
        XCTAssertThrowsError(try OpenCodeModelOptionSource.parseProviderResponse(.object(["all": .array([])])))
    }
}

func openCodeProviderFixture() -> JSONValue {
    func provider(_ identifier: String, image: Bool) -> JSONValue {
        .object([
            "id": .string(identifier), "name": .string(identifier.capitalized),
            "models": .object([
                "family/model": .object([
                    "id": .string("family/model"), "name": .string("Model"),
                    "capabilities": .object(["input": .object(["image": .bool(image)])]),
                    "limit": .object(["context": .number(200_000), "input": .number(180_000), "output": .number(20_000)]),
                    "variants": .object([
                        "high": .object([:]), "low": .object([:]), "hidden": .object(["disabled": .bool(true)])
                    ])
                ])
            ])
        ])
    }
    return .object([
        "all": .array([provider("alpha", image: true), provider("beta", image: false), provider("disconnected", image: true)]),
        "connected": .array([.string("alpha"), .string("beta")]),
        "default": .object(["alpha": .string("family/model"), "beta": .string("family/model")])
    ])
}
