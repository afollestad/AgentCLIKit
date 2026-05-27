import XCTest

@testable import AgentCLIKit

final class AgentDiagnosticsTests: XCTestCase {
    func testAgentErrorExposesStableCodeAndMetadata() {
        let error = AgentCLIError.commandFailed(
            executable: "/bin/tool",
            arguments: ["--flag"],
            exitCode: 7,
            stderr: "denied"
        )

        XCTAssertEqual(error.code, .commandFailed)
        XCTAssertEqual(error.metadata["executable"], .string("/bin/tool"))
        XCTAssertEqual(error.metadata["arguments"], .array([.string("--flag")]))
        XCTAssertEqual(error.metadata["exit_code"], .number(7))
        XCTAssertEqual(error.metadata["stderr"], .string("denied"))
    }

    func testDiagnosticEventRoundTripsCodeAndMetadata() throws {
        let diagnostic = AgentDiagnosticEvent(
            code: .providerDecodeFailed,
            severity: .error,
            message: "Could not decode provider output.",
            metadata: ["raw_stdout_line": .string("{")]
        )

        let data = try JSONEncoder().encode(diagnostic)
        let decoded = try JSONDecoder().decode(AgentDiagnosticEvent.self, from: data)

        XCTAssertEqual(decoded, diagnostic)
    }

    func testDiagnosticEventDecodesLegacyPayloadWithoutCodeOrMetadata() throws {
        let data = Data(#"{"severity":"warning","message":"legacy"}"#.utf8)

        let decoded = try JSONDecoder().decode(AgentDiagnosticEvent.self, from: data)

        XCTAssertNil(decoded.code)
        XCTAssertEqual(decoded.severity, .warning)
        XCTAssertEqual(decoded.message, "legacy")
        XCTAssertEqual(decoded.metadata, [:])
    }
}
