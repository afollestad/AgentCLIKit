import XCTest

@testable import AgentCLIKit

/// Covers the one signal a host has for telling "sign in again" apart from an ordinary turn failure:
/// Claude reports both as a plain `result` error string, so the code the decoder attaches is load
/// bearing.
final class ClaudeStreamDecoderAuthFailureTests: XCTestCase {
    func testCodesExpiredOAuthSessionAsAuthenticationRequired() throws {
        let decoder = ClaudeStreamDecoder()
        let line = #"{"type":"result","subtype":"error","result":"Failed to authenticate: OAuth session expired and could not be refreshed"}"#

        let events = try decoder.decodeLine(line)

        XCTAssertEqual(Self.diagnostics(in: events), [
            AgentDiagnosticEvent(
                code: .providerAuthenticationRequired,
                severity: .error,
                message: "Failed to authenticate: OAuth session expired and could not be refreshed"
            )
        ])
    }

    func testCodesIsErrorResultAsAuthenticationRequired() throws {
        let decoder = ClaudeStreamDecoder()
        let line = #"{"type":"result","is_error":true,"result":"Invalid API key · Please run /login"}"#

        let events = try decoder.decodeLine(line)

        XCTAssertEqual(Self.diagnostics(in: events).map(\.code), [.providerAuthenticationRequired])
    }

    func testLeavesOrdinaryResultErrorUncoded() throws {
        let decoder = ClaudeStreamDecoder()
        let line = #"{"type":"result","subtype":"error","result":"The tool call exceeded its output limit"}"#

        let events = try decoder.decodeLine(line)

        XCTAssertEqual(Self.diagnostics(in: events), [
            AgentDiagnosticEvent(severity: .error, message: "The tool call exceeded its output limit")
        ])
    }

    func testMissingResultTextStaysUncoded() throws {
        let decoder = ClaudeStreamDecoder()

        let events = try decoder.decodeLine(#"{"type":"result","subtype":"error"}"#)

        XCTAssertEqual(Self.diagnostics(in: events), [
            AgentDiagnosticEvent(severity: .error, message: "Claude result error")
        ])
    }

    func testRecognizesAuthenticationFailureTextCaseInsensitively() {
        XCTAssertTrue(ClaudeAuthFailureText.isAuthenticationFailure("OAuth session expired"))
        XCTAssertTrue(ClaudeAuthFailureText.isAuthenticationFailure("failed to authenticate"))
        XCTAssertTrue(ClaudeAuthFailureText.isAuthenticationFailure("API Error: authentication_error"))
        XCTAssertTrue(ClaudeAuthFailureText.isAuthenticationFailure("You are not logged in."))
        XCTAssertTrue(ClaudeAuthFailureText.isAuthenticationFailure("Run `claude auth login`"))
    }

    func testDoesNotRecognizeUnrelatedFailureText() {
        XCTAssertFalse(ClaudeAuthFailureText.isAuthenticationFailure("Rate limit exceeded"))
        XCTAssertFalse(ClaudeAuthFailureText.isAuthenticationFailure("The model refused to continue"))
        XCTAssertFalse(ClaudeAuthFailureText.isAuthenticationFailure(""))
    }
}

private extension ClaudeStreamDecoderAuthFailureTests {
    static func diagnostics(in events: [AgentEvent]) -> [AgentDiagnosticEvent] {
        events.compactMap { event in
            guard case let .diagnostic(diagnostic) = event else {
                return nil
            }
            return diagnostic
        }
    }
}
