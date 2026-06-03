import Foundation
import XCTest

final class CodexAppServerCaptureRedactorTests: XCTestCase {
    func testRedactsSensitiveCaptureFields() throws {
        let rawCaptureJSON = """
        {
          "method": "turn/start",
          "params": {
            "account": { "id": "acct_live_123" },
            "workspaceId": "ws_live_456",
            "installationId": "019e8e0f-9140-7b90-9347-f8d55104c871",
            "environmentId": "env_live_789",
            "authorization": "Bearer sk-proj-live-token",
            "cwd": "/Users/afollestad/Development/AgentCLIKit",
            "model": "gpt-sensitive-model",
            "input": [
              { "type": "text", "text": "Do secret local work" }
            ],
            "command": "cat /Users/afollestad/.env",
            "rateLimits": { "remaining": 123 }
          },
          "safe": "keep"
        }
        """
        let rawCapture = Data(rawCaptureJSON.utf8)

        let redacted = try CodexAppServerCaptureRedactor.redactedJSONString(from: rawCapture)

        XCTAssertTrue(redacted.contains(#""safe" : "keep""#))
        XCTAssertFalse(redacted.contains("acct_live"))
        XCTAssertFalse(redacted.contains("ws_live"))
        XCTAssertFalse(redacted.contains("019e8e0f"))
        XCTAssertFalse(redacted.contains("env_live"))
        XCTAssertFalse(redacted.contains("sk-proj"))
        XCTAssertFalse(redacted.contains("/Users/afollestad"))
        XCTAssertFalse(redacted.contains("gpt-sensitive-model"))
        XCTAssertFalse(redacted.contains("Do secret local work"))
        XCTAssertFalse(redacted.contains("remaining"))
    }
}

enum CodexAppServerCaptureRedactor {
    static func redactedJSONString(from data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data)
        let redacted = redact(object, key: nil)
        let redactedData = try JSONSerialization.data(
            withJSONObject: redacted,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        guard let string = String(data: redactedData, encoding: .utf8) else {
            throw CodexAppServerCaptureRedactorError.invalidUTF8
        }
        return string
    }

    private static func redact(_ value: Any, key: String?) -> Any {
        if shouldRedactValue(for: key) {
            return redactionToken(for: key)
        }

        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, element in
                result[element.key] = redact(element.value, key: element.key)
            }
        }

        if let array = value as? [Any] {
            return array.map { redact($0, key: key) }
        }

        if let string = value as? String {
            return redactString(string)
        }

        return value
    }

    private static func shouldRedactValue(for key: String?) -> Bool {
        guard let key else {
            return false
        }

        let normalized = key.lowercased()
        return [
            "account",
            "authorization",
            "command",
            "delta",
            "entitlement",
            "environment",
            "input",
            "installation",
            "model",
            "prompt",
            "ratelimit",
            "secret",
            "text",
            "token",
            "workspace"
        ].contains { normalized.contains($0) }
    }

    private static func redactionToken(for key: String?) -> String {
        guard let key else {
            return "<redacted>"
        }

        return "<redacted:\(key)>"
    }

    private static func redactString(_ string: String) -> String {
        var redacted = string
        let replacements: [(String, String)] = [
            (#"sk-[A-Za-z0-9_-]+"#, "<redacted:token>"),
            (#"Bearer [A-Za-z0-9._-]+"#, "Bearer <redacted:token>"),
            (#"/Users/[^\s"']+"#, "<redacted:path>"),
            (#"/private/tmp/[^\s"']+"#, "<redacted:path>"),
            (#"/tmp/[^\s"']+"#, "<redacted:path>"),
            (
                #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#,
                "<redacted:id>"
            )
        ]

        for replacement in replacements {
            redacted = redacted.replacingOccurrences(
                of: replacement.0,
                with: replacement.1,
                options: .regularExpression
            )
        }
        return redacted
    }
}

enum CodexAppServerCaptureRedactorError: Error {
    case invalidUTF8
}
