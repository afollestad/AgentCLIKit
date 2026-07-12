import XCTest

@testable import AgentCLIKit

final class CodexSensitiveRedactionTests: XCTestCase {
    func testStderrBufferRedactsBearerSplitAcrossReads() {
        var buffer = CodexStderrRedactingBuffer()
        let sensitiveValues: Set<String> = ["secret-token"]

        let first = buffer.append(Data("Bearer secret-".utf8), sensitiveValues: sensitiveValues)
        let second = buffer.append(Data("token\n".utf8), sensitiveValues: sensitiveValues)

        XCTAssertEqual(first, [])
        XCTAssertEqual(second, ["Bearer <redacted>"])
    }

    func testStderrBufferRedactsFinalFragmentOnFlush() {
        var buffer = CodexStderrRedactingBuffer()
        let sensitiveValues: Set<String> = ["secret-token"]

        XCTAssertEqual(buffer.append(Data("Bearer secret-token".utf8), sensitiveValues: sensitiveValues), [])
        XCTAssertEqual(buffer.flush(sensitiveValues: sensitiveValues), "Bearer <redacted>")
        XCTAssertNil(buffer.flush(sensitiveValues: sensitiveValues))
    }

    func testStderrBufferBoundsNewlineFreeOutputAndDropsUnsafeBoundaryPrefix() {
        var buffer = CodexStderrRedactingBuffer(maxBufferedBytes: 128)
        let sensitiveValues: Set<String> = ["secret-token"]
        let largeFragment = Data((String(repeating: "x", count: 1_000_000) + "secret-").utf8)

        XCTAssertEqual(buffer.append(largeFragment, sensitiveValues: sensitiveValues), [])
        XCTAssertLessThanOrEqual(buffer.bufferedByteCount, 128)

        let lines = buffer.append(Data("token\n".utf8), sensitiveValues: sensitiveValues)
        XCTAssertEqual(lines.count, 1)
        XCTAssertFalse(lines[0].contains("secret-token"))
        XCTAssertFalse(lines[0].contains("ecret-token"))
        XCTAssertLessThanOrEqual(lines[0].utf8.count, 128)
    }

    func testRetiredTransportBearerWindowIsBounded() async {
        let transport = CodexStdioAppServerTransport(configuration: CodexProviderAdapter.Configuration())

        for index in 0..<100 {
            let processToken = UUID()
            await transport.registerSensitiveValues(["token-\(index)"], processToken: processToken)
            await transport.unregisterSensitiveValues(processToken: processToken)
        }

        let retainedCount = await transport.retainedSensitiveValueCount
        XCTAssertEqual(retainedCount, 64)
    }

    func testTransportShutdownClearsActiveAndRetiredBearers() async {
        let transport = CodexStdioAppServerTransport(configuration: CodexProviderAdapter.Configuration())
        let activeToken = UUID()
        let retiredToken = UUID()
        await transport.registerSensitiveValues(["active-secret"], processToken: activeToken)
        await transport.registerSensitiveValues(["retired-secret"], processToken: retiredToken)
        await transport.unregisterSensitiveValues(processToken: retiredToken)

        let countBeforeShutdown = await transport.retainedSensitiveValueCount
        XCTAssertEqual(countBeforeShutdown, 2)

        await transport.shutdown()
        await transport.registerSensitiveValues(["late-secret"], processToken: UUID())

        let countAfterShutdown = await transport.retainedSensitiveValueCount
        XCTAssertEqual(countAfterShutdown, 0)
    }

    func testIncomingStreamCreatedAfterShutdownFinishesImmediately() async {
        let transport = CodexStdioAppServerTransport(configuration: CodexProviderAdapter.Configuration())
        await transport.shutdown()

        let stream = transport.incomingMessages()
        var iterator = stream.makeAsyncIterator()
        let event = await iterator.next()

        XCTAssertNil(event)
    }
}
