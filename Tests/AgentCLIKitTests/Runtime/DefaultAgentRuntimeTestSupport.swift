import Foundation
import XCTest

@testable import AgentCLIKit

extension XCTestCase {
    func spawnConfig(workingDirectory: URL = FileManager.default.temporaryDirectory) -> AgentSpawnConfig {
        AgentSpawnConfig(providerId: .claude, workingDirectory: workingDirectory)
    }

    func shell(_ script: String) -> AgentLaunchConfiguration {
        AgentLaunchConfiguration(executable: "/bin/sh", arguments: ["-c", script])
    }

    func waitForExit(
        runtime: DefaultAgentRuntime,
        conversationId: AgentConversationID
    ) async -> AgentRuntimeStatus? {
        for _ in 0..<100 {
            let status = await runtime.status(conversationId: conversationId)
            if status?.state == .exited || status?.state == .failed {
                return status
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await runtime.status(conversationId: conversationId)
    }

    static func collect(
        _ stream: AsyncStream<AgentEventEnvelope>,
        limit: Int = 20,
        until isComplete: @escaping @Sendable ([AgentEventEnvelope]) -> Bool = { _ in false }
    ) async -> [AgentEventEnvelope] {
        let accumulator = EventAccumulator()
        let collector = Task {
            var events: [AgentEventEnvelope] = []
            for await event in stream {
                events.append(event)
                await accumulator.replace(with: events)
                if events.count >= limit || isComplete(events) {
                    break
                }
            }
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await collector.value
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            _ = await group.next()
            collector.cancel()
            group.cancelAll()
        }
        return await accumulator.events
    }
}

private actor EventAccumulator {
    private(set) var events: [AgentEventEnvelope] = []

    func replace(with events: [AgentEventEnvelope]) {
        self.events = events
    }
}

struct DelayedEncodingProviderAdapter: AgentProviderAdapter {
    let definition = AgentProviderDefinition(id: .claude, displayName: "Fake", executableNames: ["fake"])
    let command: AgentLaunchConfiguration

    func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration {
        command
    }

    func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] {
        if let text = line.removingPrefix("message:") {
            return [.message(AgentMessageEvent(role: .assistant, text: text))]
        }
        return []
    }

    func encodeInput(_ input: AgentInput) async throws -> Data {
        guard case let .userMessage(message) = input else {
            return Data()
        }
        if message.text == "first" {
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        return Data((message.text + "\n").utf8)
    }
}

struct DeferredToolStopProviderAdapter: AgentProviderAdapter {
    let definition = AgentProviderDefinition(id: .claude, displayName: "Fake", executableNames: ["fake"])
    let command: AgentLaunchConfiguration

    func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration {
        command
    }

    func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] {
        switch line {
        case "deferred":
            [.usage(AgentUsageEvent(model: nil, inputTokens: nil, outputTokens: nil, stopReason: "tool_deferred"))]
        case let message where message.hasPrefix("message:"):
            [.message(AgentMessageEvent(role: .assistant, text: String(message.dropFirst("message:".count))))]
        default:
            []
        }
    }

    func encodeInput(_ input: AgentInput) async throws -> Data {
        Data()
    }
}

struct SequencedProviderAdapter: AgentProviderAdapter {
    let definition = AgentProviderDefinition(id: .claude, displayName: "Fake", executableNames: ["fake"])
    let launchSequence: LaunchSequence

    func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration {
        await launchSequence.next()
    }

    func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] {
        if let text = line.removingPrefix("message:") {
            return [.message(AgentMessageEvent(role: .assistant, text: text))]
        }
        return []
    }

    func encodeInput(_ input: AgentInput) async throws -> Data {
        Data()
    }
}

struct DelayedDecodingProviderAdapter: AgentProviderAdapter {
    let definition = AgentProviderDefinition(id: .claude, displayName: "Fake", executableNames: ["fake"])
    let launchSequence: LaunchSequence

    func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration {
        await launchSequence.next()
    }

    func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] {
        if line == "message:old" {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        if let text = line.removingPrefix("message:") {
            return [.message(AgentMessageEvent(role: .assistant, text: text))]
        }
        return []
    }

    func encodeInput(_ input: AgentInput) async throws -> Data {
        Data()
    }
}

struct FailableLaunchProviderAdapter: AgentProviderAdapter {
    let definition = AgentProviderDefinition(id: .claude, displayName: "Fake", executableNames: ["fake"])
    let launchSequence: FailableLaunchSequence

    func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration {
        try await launchSequence.next()
    }

    func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] {
        if let text = line.removingPrefix("message:") {
            return [.message(AgentMessageEvent(role: .assistant, text: text))]
        }
        return []
    }

    func encodeInput(_ input: AgentInput) async throws -> Data {
        Data()
    }
}

struct SessionReportingProviderAdapter: AgentProviderAdapter {
    let definition = AgentProviderDefinition(id: .claude, displayName: "Fake", executableNames: ["fake"])
    let command: AgentLaunchConfiguration

    func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration {
        command
    }

    func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] {
        guard let sessionId = line.removingPrefix("session:") else {
            return []
        }
        return [.diagnostic(AgentDiagnosticEvent(
            severity: .info,
            message: "session",
            metadata: ["session_id": .string(sessionId)]
        ))]
    }

    func sessionID(from event: AgentEvent) -> AgentSessionID? {
        guard case let .diagnostic(diagnostic) = event, case let .string(sessionId)? = diagnostic.metadata["session_id"] else {
            return nil
        }
        return AgentSessionID(rawValue: sessionId)
    }

    func encodeInput(_ input: AgentInput) async throws -> Data {
        Data()
    }
}

struct SequencedSessionReportingProviderAdapter: AgentProviderAdapter {
    let definition = AgentProviderDefinition(id: .claude, displayName: "Fake", executableNames: ["fake"])
    let launchSequence: LaunchSequence

    func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration {
        await launchSequence.next()
    }

    func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] {
        if let sessionId = line.removingPrefix("session:") {
            return [.diagnostic(AgentDiagnosticEvent(
                severity: .info,
                message: "session",
                metadata: ["session_id": .string(sessionId)]
            ))]
        }
        if let text = line.removingPrefix("message:") {
            return [.message(AgentMessageEvent(role: .assistant, text: text))]
        }
        return []
    }

    func sessionID(from event: AgentEvent) -> AgentSessionID? {
        guard case let .diagnostic(diagnostic) = event, case let .string(sessionId)? = diagnostic.metadata["session_id"] else {
            return nil
        }
        return AgentSessionID(rawValue: sessionId)
    }

    func encodeInput(_ input: AgentInput) async throws -> Data {
        Data()
    }
}

actor ProviderLifecycleProbe {
    private(set) var prepareCount = 0
    private(set) var terminatedProcessTokens: [UUID] = []
    private(set) var shutdownCount = 0

    func recordPrepare() {
        prepareCount += 1
    }

    func recordTermination(processToken: UUID) {
        terminatedProcessTokens.append(processToken)
    }

    func recordShutdown() {
        shutdownCount += 1
    }
}

struct LifecycleTrackingProviderAdapter: AgentProviderAdapter {
    let definition = AgentProviderDefinition(id: .claude, displayName: "Fake", executableNames: ["fake"])
    let command: AgentLaunchConfiguration
    let probe: ProviderLifecycleProbe

    func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration {
        command
    }

    func prepareLaunchConfiguration(
        _ launch: AgentLaunchConfiguration,
        spawnConfig: AgentSpawnConfig,
        conversationId: AgentConversationID,
        processToken: UUID
    ) async throws -> AgentLaunchConfiguration {
        await probe.recordPrepare()
        return AgentLaunchConfiguration(
            executable: launch.executable,
            arguments: launch.arguments,
            environment: launch.environment.merging(["AGENTCLIKIT_TEST_PREPARED": "prepared"]) { _, new in new },
            workingDirectory: launch.workingDirectory,
            sessionContinuity: launch.sessionContinuity
        )
    }

    func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] {
        if let text = line.removingPrefix("message:") {
            return [.message(AgentMessageEvent(role: .assistant, text: text))]
        }
        return []
    }

    func encodeInput(_ input: AgentInput) async throws -> Data {
        Data()
    }

    func processDidTerminate(processToken: UUID) async {
        await probe.recordTermination(processToken: processToken)
    }

    func shutdownProviderResources() async {
        await probe.recordShutdown()
    }
}

struct FailingPrepareProviderAdapter: AgentProviderAdapter {
    let definition = AgentProviderDefinition(id: .claude, displayName: "Fake", executableNames: ["fake"])
    let command: AgentLaunchConfiguration
    let probe: ProviderLifecycleProbe

    func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration {
        command
    }

    func prepareLaunchConfiguration(
        _ launch: AgentLaunchConfiguration,
        spawnConfig: AgentSpawnConfig,
        conversationId: AgentConversationID,
        processToken: UUID
    ) async throws -> AgentLaunchConfiguration {
        await probe.recordPrepare()
        throw AgentCLIError.invalidInput("prepare failed")
    }

    func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] {
        []
    }

    func encodeInput(_ input: AgentInput) async throws -> Data {
        Data()
    }

    func processDidTerminate(processToken: UUID) async {
        await probe.recordTermination(processToken: processToken)
    }
}

actor LaunchSequence {
    private var index = 0
    private let launches: [AgentLaunchConfiguration]

    init(_ launches: [AgentLaunchConfiguration]) {
        self.launches = launches
    }

    func next() -> AgentLaunchConfiguration {
        defer {
            index += 1
        }
        return launches[min(index, launches.count - 1)]
    }
}

actor FailableLaunchSequence {
    enum Step: Sendable {
        case launch(AgentLaunchConfiguration)
        case delayedLaunch(UInt64, AgentLaunchConfiguration)
        case fail(String)
    }

    private var index = 0
    private let steps: [Step]

    init(_ steps: [Step]) {
        self.steps = steps
    }

    func next() async throws -> AgentLaunchConfiguration {
        defer {
            index += 1
        }
        switch steps[min(index, steps.count - 1)] {
        case let .launch(configuration):
            return configuration
        case let .delayedLaunch(delay, configuration):
            try await Task.sleep(nanoseconds: delay)
            return configuration
        case let .fail(message):
            throw AgentCLIError.invalidInput(message)
        }
    }
}

actor SlowSessionStore: AgentSessionStore {
    private var records: [AgentConversationID: AgentSessionRecord] = [:]
    private let saveDelay: UInt64

    init(saveDelay: UInt64) {
        self.saveDelay = saveDelay
    }

    func record(conversationId: AgentConversationID, providerId: AgentProviderID) async throws -> AgentSessionRecord? {
        records[conversationId]
    }

    func save(_ record: AgentSessionRecord) async throws {
        try await Task.sleep(nanoseconds: saveDelay)
        records[record.conversationId] = record
    }

    func remove(conversationId: AgentConversationID, providerId: AgentProviderID) async throws {
        records[conversationId] = nil
    }

    func allRecords() async throws -> [AgentSessionRecord] {
        Array(records.values)
    }
}

actor FailingSlowSessionStore: AgentSessionStore {
    private let saveDelay: UInt64

    init(saveDelay: UInt64) {
        self.saveDelay = saveDelay
    }

    func record(conversationId: AgentConversationID, providerId: AgentProviderID) async throws -> AgentSessionRecord? {
        nil
    }

    func save(_ record: AgentSessionRecord) async throws {
        try await Task.sleep(nanoseconds: saveDelay)
        throw AgentCLIError.invalidInput("session store rejected save")
    }

    func remove(conversationId: AgentConversationID, providerId: AgentProviderID) async throws {}

    func allRecords() async throws -> [AgentSessionRecord] {
        []
    }
}

actor OutOfOrderSessionStore: AgentSessionStore {
    private var records: [AgentConversationID: AgentSessionRecord] = [:]
    private let delays: [String: UInt64]

    init(delays: [String: UInt64]) {
        self.delays = delays
    }

    func record(conversationId: AgentConversationID, providerId: AgentProviderID) async throws -> AgentSessionRecord? {
        records[conversationId]
    }

    func save(_ record: AgentSessionRecord) async throws {
        if let delay = delays[record.providerSessionId.rawValue] {
            try await Task.sleep(nanoseconds: delay)
        }
        records[record.conversationId] = record
    }

    func remove(conversationId: AgentConversationID, providerId: AgentProviderID) async throws {
        records[conversationId] = nil
    }

    func allRecords() async throws -> [AgentSessionRecord] {
        Array(records.values)
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else {
            return nil
        }
        return String(dropFirst(prefix.count))
    }
}
