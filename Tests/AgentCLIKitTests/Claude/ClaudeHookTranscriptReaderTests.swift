import Foundation
import XCTest

@testable import AgentCLIKit

final class ClaudeHookTranscriptReaderTests: XCTestCase {
    func testRestoresAllowFromSessionPathOverload() throws {
        let homeDirectory = try temporaryDirectory()
        let workingDirectory = try temporaryDirectory()
        let sessionId = AgentSessionID(rawValue: "session-1")
        let sessionFileURL = ClaudePathEncoder.sessionFileURL(
            sessionId: sessionId,
            workingDirectory: workingDirectory,
            homeDirectory: homeDirectory
        )
        try writeSessionFile([
            attachmentLine(
                type: "hook_success",
                toolUseId: "tool-1",
                stdout: #"{"hookSpecificOutput":{"permissionDecision":"allow"}}"#
            )
        ], to: sessionFileURL)

        let resolution = ClaudeHookTranscriptReader(homeDirectory: homeDirectory).resolution(
            forToolUseId: AgentInteractionID(rawValue: "tool-1"),
            sessionId: sessionId,
            workingDirectory: workingDirectory
        )

        XCTAssertEqual(resolution, .permissionDecision(.allow))
    }

    func testRestoresDenyFromExplicitFileURL() throws {
        let sessionFileURL = try temporaryDirectory().appendingPathComponent("session.jsonl")
        try writeSessionFile([
            attachmentLine(
                type: "hook_success",
                toolUseId: "tool-1",
                stdout: #"{"hookSpecificOutput":{"permissionDecision":"deny"}}"#
            )
        ], to: sessionFileURL)

        let resolution = ClaudeHookTranscriptReader().resolution(
            forToolUseId: AgentInteractionID(rawValue: "tool-1"),
            sessionFileURL: sessionFileURL
        )

        XCTAssertEqual(resolution, .permissionDecision(.deny))
    }

    func testRestoresTopLevelDecision() throws {
        let sessionFileURL = try temporaryDirectory().appendingPathComponent("session.jsonl")
        try writeSessionFile([
            attachmentLine(type: "hook_success", toolUseId: "tool-1", stdout: #"{"decision":"allow"}"#)
        ], to: sessionFileURL)

        let resolution = ClaudeHookTranscriptReader().resolution(
            forToolUseId: AgentInteractionID(rawValue: "tool-1"),
            sessionFileURL: sessionFileURL
        )

        XCTAssertEqual(resolution, .permissionDecision(.allow))
    }

    func testRestoresTopLevelDecisionWhenHookSpecificOutputIsMalformed() throws {
        let sessionFileURL = try temporaryDirectory().appendingPathComponent("session.jsonl")
        try writeSessionFile([
            attachmentLine(type: "hook_success", toolUseId: "tool-1", stdout: #"{"hookSpecificOutput":{},"decision":"deny"}"#)
        ], to: sessionFileURL)

        let resolution = ClaudeHookTranscriptReader().resolution(
            forToolUseId: AgentInteractionID(rawValue: "tool-1"),
            sessionFileURL: sessionFileURL
        )

        XCTAssertEqual(resolution, .permissionDecision(.deny))
    }

    func testRestoresDeferredOnlyWhenNoTerminalResultExists() throws {
        let sessionFileURL = try temporaryDirectory().appendingPathComponent("session.jsonl")
        try writeSessionFile([
            attachmentLine(
                type: "hook_success",
                toolUseId: "tool-1",
                stdout: #"{"hookSpecificOutput":{"permissionDecision":"defer"}}"#
            )
        ], to: sessionFileURL)

        let resolution = ClaudeHookTranscriptReader().resolution(
            forToolUseId: AgentInteractionID(rawValue: "tool-1"),
            sessionFileURL: sessionFileURL
        )

        XCTAssertEqual(resolution, .permissionDecision(.deferDecision))
    }

    func testLaterTerminalResultWinsOverDeferredResult() throws {
        let sessionFileURL = try temporaryDirectory().appendingPathComponent("session.jsonl")
        try writeSessionFile([
            attachmentLine(
                type: "hook_success",
                toolUseId: "tool-1",
                stdout: #"{"hookSpecificOutput":{"permissionDecision":"defer"}}"#
            ),
            attachmentLine(
                type: "hook_success",
                toolUseId: "tool-1",
                stdout: #"{"hookSpecificOutput":{"permissionDecision":"allow"}}"#
            )
        ], to: sessionFileURL)

        let resolution = ClaudeHookTranscriptReader().resolution(
            forToolUseId: AgentInteractionID(rawValue: "tool-1"),
            sessionFileURL: sessionFileURL
        )

        XCTAssertEqual(resolution, .permissionDecision(.allow))
    }

    func testReturnsFirstMatchingTerminalResult() throws {
        let sessionFileURL = try temporaryDirectory().appendingPathComponent("session.jsonl")
        try writeSessionFile([
            attachmentLine(
                type: "hook_success",
                toolUseId: "tool-1",
                stdout: #"{"hookSpecificOutput":{"permissionDecision":"allow"}}"#
            ),
            attachmentLine(
                type: "hook_success",
                toolUseId: "tool-1",
                stdout: #"{"hookSpecificOutput":{"permissionDecision":"deny"}}"#
            )
        ], to: sessionFileURL)

        let resolution = ClaudeHookTranscriptReader().resolution(
            forToolUseId: AgentInteractionID(rawValue: "tool-1"),
            sessionFileURL: sessionFileURL
        )

        XCTAssertEqual(resolution, .permissionDecision(.allow))
    }

    func testRestoresNonBlockingError() throws {
        let sessionFileURL = try temporaryDirectory().appendingPathComponent("session.jsonl")
        try writeSessionFile([
            attachmentLine(type: "hook_non_blocking_error", toolUseId: "tool-1")
        ], to: sessionFileURL)

        let resolution = ClaudeHookTranscriptReader().resolution(
            forToolUseId: AgentInteractionID(rawValue: "tool-1"),
            sessionFileURL: sessionFileURL
        )

        XCTAssertEqual(resolution, .nonBlockingError)
    }

    func testMatchesAllToolUseIdSpellings() throws {
        for key in ["toolUseID", "toolUseId", "tool_use_id"] {
            let sessionFileURL = try temporaryDirectory().appendingPathComponent("\(key).jsonl")
            try writeSessionFile([
                attachmentLine(
                    type: "hook_success",
                    toolUseIdKey: key,
                    toolUseId: "tool-1",
                    stdout: #"{"hookSpecificOutput":{"permissionDecision":"allow"}}"#
                )
            ], to: sessionFileURL)

            let resolution = ClaudeHookTranscriptReader().resolution(
                forToolUseId: AgentInteractionID(rawValue: "tool-1"),
                sessionFileURL: sessionFileURL
            )

            XCTAssertEqual(resolution, .permissionDecision(.allow), key)
        }
    }

    func testIgnoresUnrelatedToolUseIds() throws {
        let sessionFileURL = try temporaryDirectory().appendingPathComponent("session.jsonl")
        try writeSessionFile([
            attachmentLine(
                type: "hook_success",
                toolUseId: "other-tool",
                stdout: #"{"hookSpecificOutput":{"permissionDecision":"allow"}}"#
            )
        ], to: sessionFileURL)

        let resolution = ClaudeHookTranscriptReader().resolution(
            forToolUseId: AgentInteractionID(rawValue: "tool-1"),
            sessionFileURL: sessionFileURL
        )

        XCTAssertNil(resolution)
    }

    func testMalformedTranscriptDataReturnsNil() throws {
        let sessionFileURL = try temporaryDirectory().appendingPathComponent("session.jsonl")
        try writeSessionFile([
            "{not-json",
            attachmentLine(type: "hook_success", toolUseId: "tool-1", stdout: "{not-json"),
            attachmentLine(type: "hook_success", toolUseId: "tool-1", stdout: #"{"hookSpecificOutput":{}}"#),
            attachmentLine(
                type: "hook_success",
                toolUseId: "tool-1",
                stdout: #"{"hookSpecificOutput":{"permissionDecision":"maybe"}}"#
            )
        ], to: sessionFileURL)

        let resolution = ClaudeHookTranscriptReader().resolution(
            forToolUseId: AgentInteractionID(rawValue: "tool-1"),
            sessionFileURL: sessionFileURL
        )

        XCTAssertNil(resolution)
    }

    func testMissingSessionFileReturnsNil() {
        let sessionFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("missing.jsonl")

        let resolution = ClaudeHookTranscriptReader().resolution(
            forToolUseId: AgentInteractionID(rawValue: "tool-1"),
            sessionFileURL: sessionFileURL
        )

        XCTAssertNil(resolution)
    }

    func testRestoresFromWorkingDirectoryPathOverload() throws {
        let homeDirectory = try temporaryDirectory()
        let workingDirectory = try temporaryDirectory()
        let sessionId = AgentSessionID(rawValue: "session-1")
        let sessionFileURL = ClaudePathEncoder.sessionFileURL(
            sessionId: sessionId,
            workingDirectoryPath: workingDirectory.path,
            homeDirectory: homeDirectory
        )
        try writeSessionFile([
            attachmentLine(
                type: "hook_success",
                toolUseId: "tool-1",
                stdout: #"{"hookSpecificOutput":{"permissionDecision":"allow"}}"#
            )
        ], to: sessionFileURL)

        let resolution = ClaudeHookTranscriptReader(homeDirectory: homeDirectory).resolution(
            forToolUseId: AgentInteractionID(rawValue: "tool-1"),
            sessionId: sessionId,
            workingDirectoryPath: workingDirectory.path
        )

        XCTAssertEqual(resolution, .permissionDecision(.allow))
    }

    func testFindsDeferredToolMarkerFromWorkingDirectoryPathOverload() throws {
        let homeDirectory = try temporaryDirectory()
        let workingDirectory = try temporaryDirectory()
        let sessionId = AgentSessionID(rawValue: "session-1")
        let sessionFileURL = ClaudePathEncoder.sessionFileURL(
            sessionId: sessionId,
            workingDirectory: workingDirectory,
            homeDirectory: homeDirectory
        )
        try writeSessionFile([
            attachmentLine(type: "hook_deferred_tool", toolUseId: "tool-1")
        ], to: sessionFileURL)

        let reader = ClaudeHookTranscriptReader(homeDirectory: homeDirectory)

        XCTAssertTrue(reader.hasDeferredToolMarker(
            forToolUseId: AgentInteractionID(rawValue: "tool-1"),
            sessionId: sessionId,
            workingDirectoryPath: workingDirectory.path
        ))
        XCTAssertFalse(reader.hasDeferredToolMarker(
            forToolUseId: AgentInteractionID(rawValue: "tool-2"),
            sessionId: sessionId,
            workingDirectoryPath: workingDirectory.path
        ))
    }

    func testDeferredToolMarkerIgnoresOtherAttachmentsAndMissingFiles() throws {
        let sessionFileURL = try temporaryDirectory().appendingPathComponent("session.jsonl")
        try writeSessionFile([
            "not json",
            attachmentLine(
                type: "hook_success",
                toolUseId: "tool-1",
                stdout: #"{"hookSpecificOutput":{"permissionDecision":"defer"}}"#
            )
        ], to: sessionFileURL)

        let reader = ClaudeHookTranscriptReader()

        XCTAssertFalse(reader.hasDeferredToolMarker(
            forToolUseId: AgentInteractionID(rawValue: "tool-1"),
            sessionFileURL: sessionFileURL
        ))
        XCTAssertFalse(reader.hasDeferredToolMarker(
            forToolUseId: AgentInteractionID(rawValue: "tool-1"),
            sessionFileURL: sessionFileURL.deletingLastPathComponent().appendingPathComponent("missing.jsonl")
        ))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func writeSessionFile(_ lines: [String], to sessionFileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: sessionFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try lines.joined(separator: "\n").write(to: sessionFileURL, atomically: true, encoding: .utf8)
    }

    private func attachmentLine(
        type: String,
        toolUseIdKey: String = "toolUseID",
        toolUseId: String,
        stdout: String? = nil
    ) throws -> String {
        var attachment: [String: Any] = [
            "type": type,
            toolUseIdKey: toolUseId
        ]
        if let stdout {
            attachment["stdout"] = stdout
        }
        let event: [String: Any] = [
            "type": "attachment",
            "attachment": attachment
        ]
        let data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}
