import Darwin
import XCTest

@testable import AgentCLIKit

/// Owns a disposable native database, Git worktrees and localhost model server for one test.
final class OpenCodeLiveFixture: @unchecked Sendable {
    let root: URL
    let workspace: URL
    let destination: URL
    let adapter: OpenCodeHarnessAdapter
    let provider: Process
    let providerExit: Task<Void, Never>
    let endpoints: [String: String]

    private init(root: URL, executable: String, provider: Process, providerExit: Task<Void, Never>, endpoints: [String: String]) throws {
        self.root = root
        self.provider = provider
        self.providerExit = providerExit
        self.endpoints = endpoints
        workspace = root.appendingPathComponent("source workspace", isDirectory: true)
        destination = root.appendingPathComponent("fork workspace", isDirectory: true)
        let environment = try Self.environment(root: root, endpoints: endpoints)
        adapter = OpenCodeHarnessAdapter(configuration: .init(
            executablePath: executable, environment: environment, startupTimeout: 20, requestTimeout: 30, shutdownTimeout: 2
        ))
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Self.run("/usr/bin/git", ["init", "--quiet"], directory: workspace, environment: environment)
        try Self.run("/usr/bin/git", [
            "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--quiet", "--allow-empty", "-m", "Fixture"
        ], directory: workspace, environment: environment)
        try Self.run("/usr/bin/git", ["worktree", "add", "--quiet", "--detach", destination.path],
                     directory: workspace, environment: environment)
        let version = try Self.run(executable, ["--version"], directory: workspace, environment: environment)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard version == "1.18.31" else { throw LiveOpenCodeError("Expected pinned OpenCode 1.18.31, received \(version).") }
    }

    static func start() async throws -> OpenCodeLiveFixture {
        guard let executable = ProcessInfo.processInfo.environment["AGENTCLIKIT_OPENCODE_BINARY"], !executable.isEmpty else {
            throw XCTSkip("Set AGENTCLIKIT_OPENCODE_BINARY to the pinned OpenCode 1.18.31 executable to run live adapter checks.")
        }
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw LiveOpenCodeError("AGENTCLIKIT_OPENCODE_BINARY must name an executable absolute path.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("opencode-adapter-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let output = root.appendingPathComponent("provider-output.json")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        let provider = Process()
        let (exits, exitContinuation) = AsyncStream<Void>.makeStream()
        provider.terminationHandler = { _ in exitContinuation.finish() }
        let providerExit = Task { for await _ in exits {} }
        provider.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repository.deleteLastPathComponent() }
        provider.arguments = [repository.appendingPathComponent("scripts/validate-opencode-live.py").path, "--serve-provider-only"]
        provider.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "PYTHONUNBUFFERED": "1"]
        provider.standardOutput = handle
        provider.standardError = FileHandle.nullDevice
        do {
            try provider.run()
            try handle.close()
            for _ in 0..<200 {
                if let data = try? Data(contentsOf: output),
                   let endpoints = try? JSONDecoder().decode([String: String].self, from: data) {
                    return try OpenCodeLiveFixture(
                        root: root, executable: executable, provider: provider, providerExit: providerExit, endpoints: endpoints
                    )
                }
                guard provider.isRunning else { throw LiveOpenCodeError("Local model fixture exited before becoming ready.") }
                try await Task.sleep(for: .milliseconds(25))
            }
            throw LiveOpenCodeError("Local model fixture did not become ready.")
        } catch {
            if provider.isRunning {
                provider.terminate()
                await providerExit.value
            } else { providerExit.cancel() }
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func session(resuming: AgentSessionRecord? = nil, forking: AgentSessionRecord? = nil) async throws -> OpenCodeLiveSession {
        let directory = forking == nil ? resuming?.workingDirectory ?? workspace : destination
        let fork = forking.map {
            AgentSessionForkRequest(sourceSessionId: $0.harnessSessionId, sourceWorkingDirectory: $0.workingDirectory, mode: .worktree)
        }
        let config = AgentSpawnConfig(
            harnessId: .opencode, workingDirectory: directory, model: "fixture/fixture", permissionMode: "configured", sessionFork: fork
        )
        let token = UUID()
        let launch = try await adapter.makeLaunchConfiguration(context: AgentHarnessLaunchContext(
            conversationId: "live-fixture", processToken: token, spawnConfig: config, resumedSession: resuming
        ))
        let id = try XCTUnwrap(launch.harnessSessionId)
        let stream = await adapter.runtimeEvents(context: AgentHarnessRuntimeContext(
            conversationId: "live-fixture", processToken: token, harnessSessionId: id, spawnConfig: config
        ))
        let log = OpenCodeLiveEventLog()
        let collector = Task { for await envelope in stream { await log.append(envelope.event) } }
        return OpenCodeLiveSession(
            adapter: adapter, token: token, id: id, config: config, continuity: launch.sessionContinuity, log: log, collector: collector
        )
    }

    func waitForSlowRequest() async throws {
        for _ in 0..<400 {
            let state = try await get("stateURL")
            if state[oc: "slowStarted"] == .bool(true) { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw LiveOpenCodeError("OpenCode did not reach the fixture's held response.")
    }

    func release() async throws { _ = try await get("releaseURL") }

    func imageRequestCount() async throws -> Int {
        try await get("stateURL")[oc: "imageRequestCount"]?.ocInt ?? 0
    }

    func overflowCount() async throws -> Int {
        try await get("stateURL")[oc: "overflowCount"]?.ocInt ?? 0
    }

    func close() async {
        await adapter.shutdownHarnessResources()
        if provider.isRunning {
            provider.terminate()
            for _ in 0..<100 where provider.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
            if provider.isRunning { kill(provider.processIdentifier, SIGKILL) }
        }
        await providerExit.value
        try? FileManager.default.removeItem(at: root)
    }

    private func get(_ key: String) async throws -> JSONValue {
        let url = try XCTUnwrap(endpoints[key].flatMap(URL.init(string:)))
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func environment(root: URL, endpoints: [String: String]) throws -> [String: String] {
        var environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": root.path, "DO_NOT_TRACK": "1",
            "OPENCODE_DISABLE_AUTOUPDATE": "1", "OPENCODE_DISABLE_MODELS_FETCH": "1",
            "OPENCODE_DISABLE_DEFAULT_PLUGINS": "1", "OPENCODE_DISABLE_PROJECT_CONFIG": "1", "OPENCODE_CONFIG_CONTENT": "{}"
        ]
        for key in ["HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "OPENCODE_CONFIG_DIR"] {
            let directory = root.appendingPathComponent(key.lowercased(), isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            environment[key] = directory.path
        }
        let baseURL = try XCTUnwrap(endpoints["baseURL"])
        let config: JSONValue = .object([
            "model": .string("fixture/fixture"), "small_model": .string("fixture/fixture"),
            "enabled_providers": .array([.string("fixture")]), "share": .string("disabled"), "autoupdate": .bool(false),
            "permission": .object(["*": .string("allow"), "bash": .string("ask")]),
            "provider": .object(["fixture": .object([
                "npm": .string("@ai-sdk/openai-compatible"), "name": .string("Local fixture"),
                "options": .object(["baseURL": .string(baseURL), "apiKey": .string("fixture")]),
                "models": .object(["fixture": .object([
                    "name": .string("Fixture"), "limit": .object(["context": .number(32000), "output": .number(4096)]),
                    "attachment": .bool(true),
                    "modalities": .object(["input": .array([.string("text"), .string("image")]), "output": .array([.string("text")])
                    ])
                ])])
            ])])
        ])
        let file = root.appendingPathComponent("opencode.json")
        let encoder = JSONEncoder()
        // Permission properties are ordered rules; the wildcard must precede the specific bash override.
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(config).write(to: file)
        environment["OPENCODE_CONFIG"] = file.path
        return environment
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String], directory: URL, environment: [String: String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(bytes: data, encoding: .utf8) ?? "Non-UTF8 fixture command output"
        guard process.terminationStatus == 0 else { throw LiveOpenCodeError("Fixture command failed: \(text)") }
        return text
    }
}

struct OpenCodeLiveSession: Sendable {
    let adapter: OpenCodeHarnessAdapter
    let token: UUID
    let id: AgentSessionID
    let config: AgentSpawnConfig
    let continuity: AgentSessionContinuity?
    let log: OpenCodeLiveEventLog
    let collector: Task<Void, Never>

    var record: AgentSessionRecord {
        AgentSessionRecord(conversationId: "live-fixture", harnessId: .opencode, harnessSessionId: id,
                           workingDirectory: config.workingDirectory, generation: 1)
    }

    func send(_ text: String, steering: Bool = false, attachments: [AgentInputAttachment] = []) async throws {
        let metadata: [String: JSONValue] = steering ? [AgentSteeringMetadata.isSteering: .bool(true)] : [:]
        _ = try await adapter.encodeInput(
            .userMessage(AgentMessageInput(text: text, attachments: attachments, metadata: metadata)), context: inputContext
        )
    }

    func resolve(_ request: AgentInteractionEvent, outcome: AgentInteractionOutcome, response: String? = nil) async throws {
        _ = try await adapter.encodeInput(.interactionResolution(AgentInteractionResolution(
            id: request.id, outcome: outcome, responseText: response
        )), context: inputContext)
    }

    func stop() async {
        await adapter.processDidTerminate(processToken: token)
        collector.cancel()
    }

    private var inputContext: AgentHarnessInputContext {
        AgentHarnessInputContext(conversationId: "live-fixture", processToken: token, harnessSessionId: id,
                                 spawnConfig: config, isTurnActive: true)
    }
}

actor OpenCodeLiveEventLog {
    private var values: [AgentEvent] = []
    var count: Int { values.count }
    func append(_ event: AgentEvent) { values.append(event) }
    func events(after index: Int) -> [AgentEvent] { Array(values.dropFirst(index)) }

    func waitForCompletion(after index: Int = 0) async throws -> [AgentEvent] {
        try await wait(after: index) { events in
            events.contains {
                guard case let .usage(usage) = $0 else { return false }
                return usage.isTerminal == true
            }
        }
    }

    func waitForInteraction(kind: AgentInteractionKind, after index: Int) async throws -> AgentInteractionEvent {
        let events = try await wait(after: index) { events in
            events.contains { if case let .interaction(request) = $0 { return request.kind == kind }; return false }
        }
        return try XCTUnwrap(events.compactMap {
            guard case let .interaction(request) = $0, request.kind == kind else { return nil }
            return request
        }.first)
    }

    func wait(after index: Int, matching predicate: @Sendable ([AgentEvent]) -> Bool) async throws -> [AgentEvent] {
        for _ in 0..<1200 {
            let current = events(after: index)
            if predicate(current) { return current }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw LiveOpenCodeError("Timed out waiting for adapter events. Received: \(events(after: index))")
    }
}

private struct LiveOpenCodeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
