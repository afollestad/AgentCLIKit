import XCTest

@testable import AgentCLIKit

extension ClaudeHookTests {
    func testPreToolUseMatcherIncludesNativeReadOnlyTools() {
        for toolName in ["Read", "Grep", "Glob", "LS", "NotebookRead"] {
            XCTAssertTrue(ClaudeHookPolicy.preToolUseMatcher.contains(toolName), toolName)
        }
    }

    func testPreToolUseReturnsNoDecisionForEditInAcceptEditsModeWithoutStoringInteraction() async {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let token = await tokenStore.issue(validFor: 60)
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: interactionStore)

        let response = await server.handle(preToolUse(token: token.value, toolName: "Edit", permissionMode: "acceptEdits"))
        let pending = await interactionStore.pending(conversationId: "conversation")

        XCTAssertEqual(response, .noDecision)
        XCTAssertEqual(pending, [])
    }

    func testPreToolUseStillDefersBashAndMutatingMCPInAcceptEditsMode() async {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let token = await tokenStore.issue(validFor: 60)
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: interactionStore)

        let bash = await server.handle(preToolUse(token: token.value, toolName: "Bash", permissionMode: "acceptEdits"))
        let mcp = await server.handle(preToolUse(token: token.value, toolName: "mcp__repo__write_file", permissionMode: "acceptEdits"))

        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: bash), .deferDecision)
        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: mcp), .deferDecision)
    }

    func testPreToolUseReturnsNoDecisionForSafeNativeReadOnlyTools() async {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let token = await tokenStore.issue(validFor: 60)
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: interactionStore)
        let processToken = UUID()
        let workingDirectory = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        await server.registerCompactHooks(processToken: processToken, token: token.value)
        await server.registerLaunchContext(
            processToken: processToken,
            workingDirectory: workingDirectory,
            homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
        )

        let requests: [(toolName: String, toolInput: JSONValue)] = [
            ("Read", .object(["file_path": .string("Sources/App.swift")])),
            ("LS", .object(["path": .string("Sources")])),
            ("NotebookRead", .object(["notebook_path": .string("Notebooks/Analysis.ipynb")])),
            ("Grep", .object(["pattern": .string("ClaudeHookPolicy"), "path": .string("Sources")])),
            ("Grep", .object(["pattern": .string("ClaudeHookPolicy"), "glob": .string("Sources/**/*.swift")])),
            ("Glob", .object(["pattern": .string("Sources/**/*.swift")]))
        ]

        for request in requests {
            let response = await server.handle(preToolUse(
                token: token.value,
                toolName: request.toolName,
                toolInput: request.toolInput,
                processToken: processToken
            ))
            XCTAssertEqual(response, .noDecision, request.toolName)
        }

        let pending = await interactionStore.pending(conversationId: "conversation")
        XCTAssertEqual(pending, [])
    }

    func testPreToolUseDefersEscapingNativeReadOnlyTools() async {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let token = await tokenStore.issue(validFor: 60)
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: interactionStore)
        let processToken = UUID()
        await server.registerCompactHooks(processToken: processToken, token: token.value)
        await server.registerLaunchContext(
            processToken: processToken,
            workingDirectory: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
            homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
        )

        let requests: [(toolName: String, toolInput: JSONValue)] = [
            ("Read", .object(["file_path": .string("/tmp/other/Secrets.swift")])),
            ("LS", .object(["path": .string("../other")])),
            ("NotebookRead", .object(["notebook_path": .string("~/Notebook.ipynb")])),
            ("Grep", .object(["pattern": .string("token"), "path": .string("/tmp/other")])),
            ("Grep", .object(["pattern": .string("token"), "glob": .string("../**/*.swift")])),
            ("Glob", .object(["pattern": .string("/tmp/other/**/*.swift")]))
        ]

        for request in requests {
            let response = await server.handle(preToolUse(
                token: token.value,
                toolName: request.toolName,
                toolInput: request.toolInput,
                processToken: processToken
            ))
            XCTAssertEqual(ClaudeHookResponseMapper.decision(from: response), .deferDecision, request.toolName)
        }
    }

    func testPreToolUseDefersEscapingNativeReadOnlyToolsInAcceptEditsMode() async {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let token = await tokenStore.issue(validFor: 60)
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: interactionStore)
        let processToken = UUID()
        await server.registerCompactHooks(processToken: processToken, token: token.value)
        await server.registerLaunchContext(
            processToken: processToken,
            workingDirectory: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
            homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
        )

        let response = await server.handle(preToolUse(
            token: token.value,
            toolName: "Read",
            toolInput: .object(["file_path": .string("/tmp/other/Settings.json")]),
            permissionMode: "acceptEdits",
            processToken: processToken
        ))

        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: response), .deferDecision)
    }

    func testPreToolUseReturnsNoDecisionForToolsInAutoBypassAndDontAskModes() async {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let token = await tokenStore.issue(validFor: 60)
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: interactionStore)

        for mode in ["auto", "bypassPermissions", "dontAsk"] {
            let response = await server.handle(preToolUse(token: token.value, toolName: "Bash", permissionMode: mode))
            XCTAssertEqual(response, .noDecision)
        }

        let outsideReadInput: JSONValue = .object(["file_path": .string("/tmp/other/Settings.json")])
        for mode in ["auto", "bypassPermissions", "dontAsk"] {
            let response = await server.handle(preToolUse(
                token: token.value,
                toolName: "Read",
                toolInput: outsideReadInput,
                permissionMode: mode
            ))
            XCTAssertEqual(response, .noDecision)
        }

        let pending = await interactionStore.pending(conversationId: "conversation")
        XCTAssertEqual(pending, [])
    }

    func testPreToolUseDefersNativeReadOnlyWhenLaunchContextIsMissing() async {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let token = await tokenStore.issue(validFor: 60)
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: interactionStore)

        let response = await server.handle(preToolUse(
            token: token.value,
            toolName: "Read",
            toolInput: .object(["file_path": .string("Sources/App.swift")])
        ))

        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: response), .deferDecision)
    }

    func testPreToolUseClearsLaunchContextWhenTokenInvalidates() async {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let firstToken = await tokenStore.issue(validFor: 60)
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: interactionStore)
        let processToken = UUID()
        await server.registerCompactHooks(processToken: processToken, token: firstToken.value)
        await server.registerLaunchContext(
            processToken: processToken,
            workingDirectory: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
            homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
        )

        let safeInput: JSONValue = .object(["file_path": .string("Sources/App.swift")])
        let beforeInvalidation = await server.handle(preToolUse(
            token: firstToken.value,
            toolName: "Read",
            toolInput: safeInput,
            processToken: processToken
        ))
        await server.invalidateToken(firstToken.value)
        let secondToken = await tokenStore.issue(validFor: 60)
        let afterInvalidation = await server.handle(preToolUse(
            token: secondToken.value,
            toolName: "Read",
            toolInput: safeInput,
            processToken: processToken
        ))

        XCTAssertEqual(beforeInvalidation, .noDecision)
        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: afterInvalidation), .deferDecision)
    }

    func testPreToolUseReturnsNoDecisionForReadOnlyMCPInAcceptEditsMode() async {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let token = await tokenStore.issue(validFor: 60)
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: interactionStore)

        let response = await server.handle(preToolUse(
            token: token.value,
            toolName: "mcp__repo__read_file",
            permissionMode: "acceptEdits"
        ))

        XCTAssertEqual(response, .noDecision)
    }

    func testPreToolUseExitPlanModeOnlyDefersInPlanMode() async {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let token = await tokenStore.issue(validFor: 60)
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: interactionStore)

        let defaultMode = await server.handle(preToolUse(
            token: token.value,
            toolName: "ExitPlanMode",
            permissionMode: "default"
        ))
        let planMode = await server.handle(preToolUse(token: token.value, toolName: "ExitPlanMode", permissionMode: "plan"))
        let pending = await interactionStore.pending(conversationId: "conversation")

        XCTAssertEqual(defaultMode, .noDecision)
        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: planMode), .deferDecision)
        XCTAssertEqual(pending.first?.kind, .planModeExit)
    }
}
