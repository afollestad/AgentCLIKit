import XCTest

@testable import AgentCLIKit

final class OpenCodeOneShotOutputTests: XCTestCase {
    static let completedOutput = """
    {"type":"step_start","sessionID":"ses_one","part":{"messageID":"msg_final"}}
    {"type":"text","sessionID":"ses_one","part":{"id":"part_final","messageID":"msg_final","text":"Final answer","time":{"end":1}}}
    {"type":"step_finish","sessionID":"ses_one","part":{"messageID":"msg_final","reason":"stop"}}
    """

    func testReturnsOnlyFinalCompletedStepAndDeduplicatesText() async throws {
        let preamble = """
        {"type":"step_start","sessionID":"ses_one","part":{"messageID":"msg_tool"}}
        {"type":"text","sessionID":"ses_one","part":{"id":"part_preamble","messageID":"msg_tool","text":"I will inspect","time":{"end":1}}}
        {"type":"tool_use","sessionID":"ses_one","part":{"messageID":"msg_tool","tool":"read","state":{"status":"completed"}}}
        {"type":"step_finish","sessionID":"ses_one","part":{"messageID":"msg_tool","reason":"tool-calls"}}
        """
        let duplicate = """
        {"type":"text","sessionID":"ses_one","part":{"id":"part_final","messageID":"msg_final","text":"Final answer","time":{"end":1}}}
        """
        let text = try await parse(preamble + "\n" + Self.completedOutput + "\n" + duplicate)
        XCTAssertEqual(text, "Final answer")
    }

    func testUnicodeNewlinesInsideJSONTextAreNotRecordSeparators() async throws {
        let expected = "First\u{0085}Second\u{2028}Third\u{2029}Fourth"
        for separator in ["\n", "\r\n"] {
            let output = Self.completedOutput.replacingOccurrences(of: "Final answer", with: expected)
                .replacingOccurrences(of: "\n", with: separator) + separator
            let text = try await parse(output)
            XCTAssertEqual(text, expected)
        }
    }

    func testRejectsIncompleteOrTruncatedSuccessAndMalformedStreams() async throws {
        for output in [
            "", "not JSON", "{}", Self.completedOutput.replacingOccurrences(of: "\"stop\"", with: "\"length\""),
            Self.completedOutput.components(separatedBy: "\n").dropLast().joined(separator: "\n"),
            Self.completedOutput + "\n" + #"{"type":"step_start","sessionID":"ses_one","part":{"messageID":"unfinished"}}"#,
            Self.completedOutput + "\n" + #"{"type":"step_finish","sessionID":"other","part":{"messageID":"msg_final","reason":"stop"}}"#
        ] {
            do {
                _ = try await parse(output)
                XCTFail("Expected incomplete/malformed stream failure")
            } catch AgentOneShotPromptError.malformedOutput { }
        }
    }

    func testStructuredErrorCannotReturnEarlierAssistantText() async throws {
        do {
            _ = try await parse(Self.completedOutput + "\n" + #"{"type":"error","error":{"data":{"message":"Model request failed"}}}"#)
            XCTFail("Expected structured failure")
        } catch AgentOneShotPromptError.harnessReportedError(_, let message, _, _) {
            XCTAssertEqual(message, "Model request failed")
        }
    }

    func testForbiddenToolAndQuestionsFailClosed() async throws {
        for tool in ["bash", "task", "write", "webfetch", "mcp_tool", "question"] {
            let output = "{\"type\":\"tool_use\",\"sessionID\":\"ses_one\",\"part\":{\"messageID\":\"msg_tool\",\"tool\":\"\(tool)\"}}"
            do { _ = try await parse(output); XCTFail("Expected forbidden \(tool)") } catch AgentOneShotPromptError.approvalRequired {
                XCTAssertNotEqual(tool, "question")
            } catch AgentOneShotPromptError.promptRequired { XCTAssertEqual(tool, "question") }
        }
    }

    private func parse(_ stdout: String) async throws -> String {
        try await OpenCodeHarnessAdapter().finalOneShotPromptText(
            stdout: stdout, stderr: "", request: AgentOneShotPromptRequest(
                harnessId: .opencode, workingDirectory: URL(fileURLWithPath: "/tmp"), prompt: "Review", model: "fixture/model"
            )
        )
    }
}
