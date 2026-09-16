import Darwin
import Foundation
import XCTest

@testable import AgentCLIKit

final class OpenCodeServerTransportTests: XCTestCase {
    func testStartupAddressWaitsForCompletePortLine() {
        var decoder = OpenCodeServerAddressDecoder()
        XCTAssertNil(decoder.consume(Data("opencode server listening on http://127.0.0.1:4".utf8)))
        XCTAssertEqual(decoder.consume(Data("3210\n".utf8))?.port, 43210)
    }

    func testStartupAddressRejectsNonLoopbackAndDecoratedURLs() {
        var decoder = OpenCodeServerAddressDecoder()
        let rejected = [
            "http://example.com:43210", "http://0.0.0.0:43210", "https://127.0.0.1:43210",
            "http://user@127.0.0.1:43210", "http://127.0.0.1:43210/foreign", "http://127.0.0.1:43210?token=secret",
            "http://127.0.0.1:0", "http://127.0.0.1:70000"
        ]
        for address in rejected {
            XCTAssertNil(decoder.consume(Data("opencode server listening on \(address)\n".utf8)))
        }
        XCTAssertEqual(decoder.consume(Data("logs\nopencode server listening on http://127.0.0.1:43210\r\n".utf8))?.port, 43210)
    }

    func testSSEHandlesAllLineEndingsAndMultilineData() throws {
        for ending in ["\n", "\r\n", "\r"] {
            let stream = [":heartbeat", "event: message", "id: 123", "data: {", "data: \"text\": \"Hello\"}", "", ""]
                .joined(separator: ending)
            XCTAssertEqual(try decode(stream), [.object(["text": .string("Hello")])])
        }
    }

    func testSSEPreservesUnicodeNewlinesInsideJSONText() throws {
        let text = "first\u{2028}second\u{0085}third\u{2029}🦋"
        let stream = "data: {\"text\": \"\(text)\"}\n\n"
        XCTAssertEqual(try decode(stream), [.object(["text": .string(text)])])
    }

    func testSSERequiresFrameBoundaryAndResetsBetweenFrames() throws {
        var decoder = OpenCodeSSEDecoder()
        XCTAssertNil(try decoder.consume(line: "data: {\"first\":1}"))
        XCTAssertEqual(try decoder.consume(line: ""), .object(["first": .number(1)]))
        XCTAssertNil(try decoder.consume(line: ""))
        XCTAssertNil(try decoder.consume(line: "data:{\"second\":2}"))
        XCTAssertEqual(try decoder.consume(line: ""), .object(["second": .number(2)]))
    }

    func testSSERejectsMalformedUTF8JSONAndOversizedFrames() throws {
        var invalidUTF8 = OpenCodeSSEDecoder()
        XCTAssertNil(try invalidUTF8.consume(byte: 0xFF))
        XCTAssertThrowsError(try invalidUTF8.consume(byte: 10))
        var invalidJSON = OpenCodeSSEDecoder()
        XCTAssertNil(try invalidJSON.consume(line: "data: not-json"))
        XCTAssertThrowsError(try invalidJSON.consume(line: ""))
        var oversized = OpenCodeSSEDecoder()
        let line = "data:" + String(repeating: "x", count: OpenCodeSSEDecoder.maximumFrameBytes)
        XCTAssertThrowsError(try oversized.consume(line: line))
    }

    func testServerExitDuringStartupFailsAndStopIsIdempotent() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeExecutable(in: directory, body: "exit 0")
        let transport = OpenCodeHTTPServerTransport(configuration: OpenCodeServerConfiguration(
            executablePath: executable.path, workingDirectory: directory, startupTimeout: 1, shutdownTimeout: 0.05
        ))
        do {
            try await transport.start()
            XCTFail("An exited server must not start")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("exited during startup"))
        }
        await transport.stop()
        await transport.stop()
        do {
            _ = try await transport.request(method: "GET", path: "/global/health", body: nil)
            XCTFail("A stopped server must reject requests")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not running"))
        }
    }

    func testStartupTimeoutTerminatesUnresponsiveServer() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeExecutable(in: directory, body: "trap '' TERM\nexec /bin/sleep 30")
        let transport = OpenCodeHTTPServerTransport(configuration: OpenCodeServerConfiguration(
            executablePath: executable.path, workingDirectory: directory, startupTimeout: 0.05, shutdownTimeout: 0.05
        ))
        let start = Date()
        do {
            try await transport.start()
            XCTFail("Expected startup timeout")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("startup timed out"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testCancelledStartupStillCompletesTeardown() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeExecutable(in: directory, body: "trap '' TERM\nexec /bin/sleep 30")
        let transport = OpenCodeHTTPServerTransport(configuration: OpenCodeServerConfiguration(
            executablePath: executable.path, workingDirectory: directory, startupTimeout: 5, shutdownTimeout: 0.05
        ))
        let startup = Task { try await transport.start() }
        try await Task.sleep(for: .milliseconds(50))
        startup.cancel()
        do {
            try await startup.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await transport.stop()
    }

    func testConcurrentStopsJoinServerLaunchedOnAnotherExecutor() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = OpenCodeServerProcessRegistry()
        defer { registry.shutdown(grace: 0.05) }
        let executable = try makeExecutable(in: directory, body: "trap '' TERM\necho $$ > server.pid\nexec /bin/sleep 30")
        let transport = OpenCodeHTTPServerTransport(configuration: OpenCodeServerConfiguration(
            executablePath: executable.path, workingDirectory: directory, startupTimeout: 5, shutdownTimeout: 0.05
        ), processRegistry: registry)
        let startup = Task.detached { try await transport.start() }
        let pidFile = directory.appendingPathComponent("server.pid")
        let deadline = Date().addingTimeInterval(3)
        var publishedPID: Int32?
        while publishedPID == nil, Date() < deadline {
            publishedPID = (try? String(contentsOf: pidFile, encoding: .utf8))
                .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if publishedPID != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try XCTUnwrap(publishedPID)
        let first = Task.detached { await transport.stop() }
        await transport.stop()
        await first.value
        let signalResult = kill(pid, 0)
        let signalError = errno
        XCTAssertEqual(signalResult, -1)
        XCTAssertEqual(signalError, ESRCH)
        do {
            try await startup.value
            XCTFail("Stopped startup must fail")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    private func decode(_ stream: String) throws -> [JSONValue] {
        var decoder = OpenCodeSSEDecoder()
        return try stream.utf8.compactMap { try decoder.consume(byte: $0) }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeExecutable(in directory: URL, body: String) throws -> URL {
        let executable = directory.appendingPathComponent("fake-opencode")
        try ("#!/bin/sh\n" + body + "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }
}
