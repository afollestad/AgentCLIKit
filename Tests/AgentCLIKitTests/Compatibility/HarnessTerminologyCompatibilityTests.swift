import XCTest

@testable import AgentCLIKit

/// Literal pre-rename payloads protect persisted contracts independently of renamed Swift symbols.
final class HarnessTerminologyCompatibilityTests: XCTestCase {
    func testHarnessIdentifiersKeepCLIIdentityRatherThanModelVendorNames() throws {
        let identities: [(AgentHarnessID, String)] = [(.claude, "claude"), (.codex, "codex")]
        for (identity, rawValue) in identities {
            let data = Data("\"\(rawValue)\"".utf8)
            XCTAssertEqual(try JSONDecoder().decode(AgentHarnessID.self, from: data), identity)
            XCTAssertEqual(try JSONEncoder().encode(identity), data)
        }
        for vendor in ["anthropic", "openai"] {
            XCTAssertNil(AgentHarnessID(rawValue: vendor))
        }
    }

    func testLegacySpawnConfigRetainsItsSerializedIdentityKey() throws {
        let config = try decode(AgentSpawnConfig.self, from: """
        {"providerId":"codex","workingDirectory":"file:///tmp/project","model":"gpt-5.5"}
        """)

        XCTAssertEqual(config.harnessId, .codex)
        XCTAssertEqual(config.model, "gpt-5.5")
        XCTAssertEqual(config.arguments, [])
        XCTAssertFalse(config.forkSession)
        let encoded = try encodedObject(config)
        XCTAssertEqual(encoded["providerId"], .string("codex"))
        XCTAssertNil(encoded["harnessId"])
    }

    func testLegacySessionRecordRetainsIdentityTitleAndLineage() throws {
        let record = try decode(AgentSessionRecord.self, from: """
        {
          "conversationId":"conversation","providerId":"codex","providerSessionId":"current",
          "providerSessionName":"Saved title","providerSessionPreview":"Saved preview",
          "generation":4,"createdAt":0,"updatedAt":10,
          "metadata":{"superseded_provider_session_ids":["first","second"],"host_tag":"kept"}
        }
        """)

        XCTAssertEqual(record.harnessId, .codex)
        XCTAssertEqual(record.harnessSessionId, "current")
        XCTAssertEqual(record.harnessSessionName, "Saved title")
        XCTAssertEqual(record.harnessSessionPreview, "Saved preview")
        XCTAssertEqual(record.supersededHarnessSessionIds, ["first", "second"])
        let encoded = try encodedObject(record)
        XCTAssertEqual(encoded["providerId"], .string("codex"))
        XCTAssertEqual(encoded["providerSessionId"], .string("current"))
        XCTAssertEqual(encoded["providerSessionName"], .string("Saved title"))
        XCTAssertEqual(encoded["providerSessionPreview"], .string("Saved preview"))
        XCTAssertNil(encoded["harnessId"])
        XCTAssertNil(encoded["harnessSessionId"])
        XCTAssertNil(encoded["harnessSessionName"])
        XCTAssertNil(encoded["harnessSessionPreview"])
        XCTAssertEqual(encoded["metadata"], .object(record.metadata))

        let updated = AgentSessionRecord.appendingSupersededHarnessSessionId("current", to: record.metadata)
        XCTAssertEqual(updated["superseded_provider_session_ids"], .array([.string("first"), .string("second"), .string("current")]))
        XCTAssertNil(updated["superseded_harness_session_ids"])
        let retargeted = record.retargeted(to: "first")
        XCTAssertEqual(retargeted.harnessSessionId, "first")
        XCTAssertEqual(retargeted.metadata, ["host_tag": .string("kept")])
        XCTAssertEqual(retargeted.supersededHarnessSessionIds, [])
    }

    func testLegacyRuntimeStatusRetainsSerializedSessionMetadataKeys() throws {
        let status = try decode(AgentRuntimeStatus.self, from: """
        {
          "conversationId":"conversation","providerId":"claude","generation":2,"state":"running","lastEventIndex":8,
          "providerSessionId":"session","providerSessionName":"Title","providerSessionPreview":"Preview"
        }
        """)

        XCTAssertEqual(status.harnessId, .claude)
        XCTAssertEqual(status.harnessSessionId, "session")
        XCTAssertEqual(status.harnessSessionName, "Title")
        XCTAssertEqual(status.harnessSessionPreview, "Preview")
        XCTAssertFalse(status.isTurnActive)
        let encoded = try encodedObject(status)
        XCTAssertEqual(encoded["providerId"], .string("claude"))
        XCTAssertEqual(encoded["providerSessionId"], .string("session"))
        XCTAssertEqual(encoded["providerSessionName"], .string("Title"))
        XCTAssertEqual(encoded["providerSessionPreview"], .string("Preview"))
        XCTAssertNil(encoded["harnessId"])
        XCTAssertNil(encoded["harnessSessionId"])
        XCTAssertNil(encoded["harnessSessionName"])
        XCTAssertNil(encoded["harnessSessionPreview"])
    }

    func testLegacyEventEnvelopeRetainsNestedSessionMetadataKeys() throws {
        let envelope = try decode(AgentEventEnvelope.self, from: """
        {
          "generation":2,"index":8,"providerId":"claude","conversationId":"conversation",
          "providerSessionId":"session","source":"stdout","createdAt":0,
          "event":{"sessionMetadata":{"_0":{"providerSessionId":"session","name":"Title","metadata":{}}}}
        }
        """)

        XCTAssertEqual(envelope.harnessId, .claude)
        XCTAssertEqual(envelope.harnessSessionId, "session")
        guard case let .sessionMetadata(metadata) = envelope.event else {
            return XCTFail("Expected persisted session metadata")
        }
        XCTAssertEqual(metadata.harnessSessionId, "session")
        XCTAssertEqual(metadata.name, "Title")
        let encoded = try encodedObject(envelope)
        XCTAssertEqual(encoded["providerId"], .string("claude"))
        XCTAssertEqual(encoded["providerSessionId"], .string("session"))
        XCTAssertNil(encoded["harnessId"])
        XCTAssertNil(encoded["harnessSessionId"])
        let encodedMetadata = try encodedObject(metadata)
        XCTAssertEqual(encodedMetadata["providerSessionId"], .string("session"))
        XCTAssertNil(encodedMetadata["harnessSessionId"])
    }

    func testLegacyDiscoveryStatusRetainsNestedHarnessIdentityKeys() throws {
        let status = try decode(AgentHarnessStatus.self, from: """
        {
          "providerId":"codex","installation":"installed","isEnabled":true,"setup":"ready","diagnostics":[],
          "availability":{"providerId":"codex","executablePath":"/usr/local/bin/codex"},
          "modelOptions":[{"providerId":"codex","id":"gpt-5.5","model":"gpt-5.5","label":"GPT-5.5"}]
        }
        """)

        XCTAssertEqual(status.harnessId, .codex)
        XCTAssertTrue(status.isReadyInProject)
        let availability = try XCTUnwrap(status.availability)
        let option = try XCTUnwrap(status.modelOptions.first)
        XCTAssertEqual(availability.harnessId, .codex)
        XCTAssertEqual(option.harnessId, .codex)
        for encoded in [try encodedObject(status), try encodedObject(availability), try encodedObject(option)] {
            XCTAssertEqual(encoded["providerId"], .string("codex"))
            XCTAssertNil(encoded["harnessId"])
        }
    }

    func testLegacyHookEventRetainsSerializedHarnessIdentityKey() throws {
        let event = try decode(AgentHookEvent.self, from: """
        {"id":"hook","providerId":"claude","name":"PreToolUse","payload":{},"receivedAt":0}
        """)

        XCTAssertEqual(event.harnessId, .claude)
        let encoded = try encodedObject(event)
        XCTAssertEqual(encoded["providerId"], .string("claude"))
        XCTAssertNil(encoded["harnessId"])
    }

    func testRenamedErrorsRetainMachineCodesAndMetadataKeys() throws {
        let errors: [(AgentCLIError, String)] = [
            (.harnessNotRegistered(.codex), "providerNotRegistered"),
            (.harnessUnavailable(.codex), "providerUnavailable")
        ]
        for (error, persistedCode) in errors {
            XCTAssertEqual(error.code.rawValue, persistedCode)
            XCTAssertEqual(try decode(AgentErrorCode.self, from: "\"\(persistedCode)\""), error.code)
            XCTAssertEqual(try JSONEncoder().encode(error.code), Data("\"\(persistedCode)\"".utf8))
            XCTAssertEqual(error.metadata, ["provider_id": .string("codex")])
        }
        let unsupported = AgentCLIError.unsupportedCapability(harnessId: .claude, capability: "goal")
        XCTAssertEqual(unsupported.metadata["provider_id"], .string("claude"))
        XCTAssertNil(unsupported.metadata["harness_id"])
    }

    func testRenamedDiagnosticsRetainPersistedRawValues() throws {
        let codes: [(AgentDiagnosticCode, String)] = [
            (.harnessStderr, "providerStderr"),
            (.harnessDecodeFailed, "providerDecodeFailed"),
            (.harnessAuthenticationRequired, "providerAuthenticationRequired")
        ]
        for (code, persistedCode) in codes {
            let event = try decode(AgentDiagnosticEvent.self, from: """
            {"code":"\(persistedCode)","severity":"warning","message":"Saved diagnostic","metadata":{"provider_id":"claude"}}
            """)
            XCTAssertEqual(event.code, code)
            XCTAssertEqual(code.rawValue, persistedCode)
            let encoded = try encodedObject(event)
            XCTAssertEqual(encoded["code"], .string(persistedCode))
            XCTAssertEqual(encoded["metadata"], .object(["provider_id": .string("claude")]))
        }
    }

    func testCodexModelProviderRemainsAModelVendorWireField() throws {
        var decoder = CodexAppServerNotificationDecoder()
        let events = decoder.decode(CodexAppServerNotification(
            method: "thread/settings/updated",
            params: .object([
                "threadId": .string("thread"),
                "threadSettings": .object([
                    "model": .string("gpt-5.5"),
                    "modelProvider": .string("openai")
                ])
            ])
        ))

        let event = try XCTUnwrap(events.first)
        guard case let .diagnostic(diagnostic) = event.event else {
            return XCTFail("Expected the Codex settings diagnostic")
        }
        XCTAssertEqual(diagnostic.metadata["codex_model_provider"], .string("openai"))
        XCTAssertNil(diagnostic.metadata["codex_model_harness"])
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from json: String) throws -> Value {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func encodedObject<Value: Codable & Equatable>(_ value: Value) throws -> [String: JSONValue] {
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(Value.self, from: data), value)
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }
}
