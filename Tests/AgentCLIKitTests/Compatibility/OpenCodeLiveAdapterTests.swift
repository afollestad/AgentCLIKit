import XCTest

@testable import AgentCLIKit

/// Opt-in contract checks against the pinned executable; inference and user configuration stay isolated.
final class OpenCodeLiveAdapterTests: XCTestCase {
    func testLiveStreamingInteractionsSteeringAndCompaction() async throws {
        let fixture = try await OpenCodeLiveFixture.start()
        do {
            let session = try await fixture.session()
            try await session.send("FIXTURE_TEXT")
            let text = try await session.log.waitForCompletion()
            XCTAssertEqual(text.assistantTexts, ["Fixture text complete."])
            XCTAssertTrue(text.contains { if case .messageDelta = $0 { return true }; return false })
            XCTAssertTrue(text.contains {
                guard case let .usage(usage) = $0 else { return false }
                return usage.inputTokens == 11 && usage.outputTokens == 5 && usage.totalTokens == 16
            })

            let questionStart = await session.log.count
            try await session.send("FIXTURE_QUESTION")
            let question = try await session.log.waitForInteraction(kind: .prompt, after: questionStart)
            XCTAssertEqual(question.prompt, "Choose a fixture?")
            let waiting = await session.log.events(after: questionStart)
            XCTAssertFalse(waiting.hasTerminalUsage)
            try await session.resolve(question, outcome: .answered, response: "First")
            let questionEvents = try await session.log.waitForCompletion(after: questionStart)
            XCTAssertEqual(questionEvents.assistantTexts, ["Fixture question complete."])

            let permissionStart = await session.log.count
            try await session.send("FIXTURE_PERMISSION")
            let permission = try await session.log.waitForInteraction(kind: .approval, after: permissionStart)
            XCTAssertEqual(permission.metadata["tool_name"], .string("Bash"))
            let beforeApproval = await session.log.events(after: permissionStart)
            XCTAssertFalse(beforeApproval.hasTerminalUsage)
            try await session.resolve(permission, outcome: .approved)
            let permissionEvents = try await session.log.waitForCompletion(after: permissionStart)
            XCTAssertEqual(permissionEvents.assistantTexts, ["Fixture permission complete."])
            XCTAssertTrue(permissionEvents.contains {
                guard case let .toolResult(result) = $0 else { return false }
                return !result.isError && result.content.contains("fixture-tool")
            })
            try await verifySteeringAndCompaction(session, fixture: fixture)
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    private func verifySteeringAndCompaction(_ session: OpenCodeLiveSession, fixture: OpenCodeLiveFixture) async throws {
        let steeringStart = await session.log.count
        try await session.send("FIXTURE_STEER")
        try await fixture.waitForSlowRequest()
        try await session.send("FIXTURE_FOLLOWUP", steering: true)
        _ = try await session.log.wait(after: steeringStart) { events in
            events.contains {
                guard case let .message(message) = $0 else { return false }
                return message.metadata[AgentSteeringMetadata.signal] == .string(AgentSteeringMetadata.signalRuntimeInputAccepted)
            }
        }
        try await fixture.release()
        let steering = try await session.log.waitForCompletion(after: steeringStart)
        XCTAssertEqual(steering.assistantTexts, ["Fixture steer complete.", "Fixture followup complete."])
        XCTAssertEqual(steering.filter(\.isTerminalUsage).count, 1)

        let compactionStart = await session.log.count
        try await session.send("/compact")
        let compaction = try await session.log.waitForCompletion(after: compactionStart)
        let phases = compaction.compactMap { event -> AgentContextCompactionPhase? in
            guard case let .contextCompaction(value) = event else { return nil }
            return value.phase
        }
        XCTAssertEqual(phases, [.started, .completed])
        XCTAssertTrue(compaction.assistantTexts.isEmpty, "Compaction summaries must not appear as assistant replies.")
    }

    func testLiveResumeAndForkIntoWorktreePreserveNativeHistory() async throws {
        let fixture = try await OpenCodeLiveFixture.start()
        do {
            let original = try await fixture.session()
            try await original.send("FIXTURE_TEXT")
            _ = try await original.log.waitForCompletion()
            let record = original.record
            await original.stop()

            let resumed = try await fixture.session(resuming: record)
            XCTAssertEqual(resumed.id, original.id)
            XCTAssertEqual(resumed.continuity, .resumed)
            try await resumed.send("FIXTURE_FOLLOWUP")
            let resumedEvents = try await resumed.log.waitForCompletion()
            XCTAssertEqual(resumedEvents.assistantTexts, ["Fixture followup complete."])
            await resumed.stop()

            let forked = try await fixture.session(forking: record)
            XCTAssertNotEqual(forked.id, record.harnessSessionId)
            XCTAssertEqual(forked.continuity, .forked)
            XCTAssertEqual(forked.config.workingDirectory, fixture.destination)
            try await forked.send("FIXTURE_TEXT")
            let forkEvents = try await forked.log.waitForCompletion()
            XCTAssertEqual(forkEvents.assistantTexts, ["Fixture text complete."])
            let forkRecord = forked.record
            await forked.stop()

            let forkResume = try await fixture.session(resuming: forkRecord)
            XCTAssertEqual(forkResume.id, forkRecord.harnessSessionId)
            try await forkResume.send("FIXTURE_FOLLOWUP")
            let finalEvents = try await forkResume.log.waitForCompletion()
            XCTAssertEqual(finalEvents.assistantTexts, ["Fixture followup complete."])
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    func testLiveCancellationCompletesOnceAndAllowsNextTurn() async throws {
        let fixture = try await OpenCodeLiveFixture.start()
        do {
            let session = try await fixture.session()
            try await session.send("FIXTURE_STEER")
            try await fixture.waitForSlowRequest()
            try await session.adapter.interrupt(context: AgentHarnessInterruptContext(
                conversationId: "live-fixture", processToken: session.token,
                harnessSessionId: session.id, spawnConfig: session.config
            ))
            let cancelled = try await session.log.waitForCompletion()
            XCTAssertEqual(cancelled.filter(\.isTerminalUsage).count, 1)
            XCTAssertTrue(cancelled.assistantTexts.isEmpty)
            try await fixture.release()
            let nextStart = await session.log.count
            try await session.send("FIXTURE_FOLLOWUP")
            let next = try await session.log.waitForCompletion(after: nextStart)
            XCTAssertEqual(next.assistantTexts, ["Fixture followup complete."])
            XCTAssertEqual(next.filter(\.isTerminalUsage).count, 1)
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    func testLivePermissionAndQuestionDenialCloseTheTurn() async throws {
        let fixture = try await OpenCodeLiveFixture.start()
        do {
            let session = try await fixture.session()
            try await session.send("FIXTURE_PERMISSION")
            let permission = try await session.log.waitForInteraction(kind: .approval, after: 0)
            try await session.resolve(permission, outcome: .denied)
            let denial = try await session.log.waitForCompletion()
            XCTAssertEqual(denial.filter(\.isTerminalUsage).count, 1)
            XCTAssertTrue(denial.contains {
                if case let .toolResult(result) = $0 { return result.isError }
                return false
            })

            let questionStart = await session.log.count
            try await session.send("FIXTURE_QUESTION")
            let question = try await session.log.waitForInteraction(kind: .prompt, after: questionStart)
            try await session.resolve(question, outcome: .cancelled)
            let rejection = try await session.log.waitForCompletion(after: questionStart)
            XCTAssertEqual(rejection.filter(\.isTerminalUsage).count, 1)

            let followupStart = await session.log.count
            try await session.send("FIXTURE_FOLLOWUP")
            let followup = try await session.log.waitForCompletion(after: followupStart)
            XCTAssertEqual(followup.assistantTexts, ["Fixture followup complete."])
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    func testLiveSubagentMessagesStayAttributedUntilRootCompletes() async throws {
        let fixture = try await OpenCodeLiveFixture.start()
        do {
            let session = try await fixture.session()
            try await session.send("FIXTURE_TASK")
            let events = try await session.log.waitForCompletion()
            let lifecycle = events.compactMap { event -> AgentSubAgentEvent? in
                guard case let .subAgent(value) = event else { return nil }
                return value
            }
            let completed = try XCTUnwrap(lifecycle.first { $0.phase == .terminal })
            XCTAssertTrue(lifecycle.contains { $0.phase == .started && $0.id == completed.id })
            XCTAssertEqual(completed.childSessionIds.count, 1)
            XCTAssertNotEqual(completed.childSessionIds.first, session.id.rawValue)
            XCTAssertEqual(completed.agentType, "general")
            let child = try XCTUnwrap(events.compactMap { event -> AgentMessageEvent? in
                guard case let .message(value) = event, value.text == "Fixture child complete." else { return nil }
                return value
            }.first)
            XCTAssertEqual(child.metadata["parent_tool_use_id"], .string(completed.id))
            XCTAssertTrue(events.assistantTexts.contains("Fixture task complete."))
            XCTAssertEqual(events.filter(\.isTerminalUsage).count, 1)
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    func testLiveImageAttachmentReachesTheSelectedVisionModel() async throws {
        let fixture = try await OpenCodeLiveFixture.start()
        do {
            let session = try await fixture.session()
            let image = fixture.root.appendingPathComponent("pixel.png")
            let png = try XCTUnwrap(Data(base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
            ))
            try png.write(to: image)
            try await session.send("FIXTURE_IMAGE", attachments: [.localImage(id: "fixture-image", fileURL: image)])
            let events = try await session.log.waitForCompletion()
            XCTAssertEqual(events.assistantTexts, ["Fixture image complete."])
            let imageRequests = try await fixture.imageRequestCount()
            XCTAssertGreaterThan(imageRequests, 0)
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    func testLiveContextOverflowCompactsAndCompletesTheOriginalPrompt() async throws {
        let fixture = try await OpenCodeLiveFixture.start()
        do {
            let session = try await fixture.session()
            try await session.send("FIXTURE_TEXT")
            _ = try await session.log.waitForCompletion()
            let overflowStart = await session.log.count
            try await session.send("FIXTURE_OVERFLOW")
            let events = try await session.log.waitForCompletion(after: overflowStart)
            let compactions = events.compactMap { event -> AgentContextCompactionEvent? in
                guard case let .contextCompaction(value) = event else { return nil }
                return value
            }
            XCTAssertEqual(compactions.map(\.phase), [.started, .completed])
            XCTAssertEqual(compactions.first?.trigger, "auto")
            XCTAssertEqual(compactions.first?.id, compactions.last?.id)
            XCTAssertEqual(events.assistantTexts, ["Fixture overflow complete."])
            let injectedOverflows = try await fixture.overflowCount()
            XCTAssertEqual(injectedOverflows, 1)
            XCTAssertEqual(events.filter(\.isTerminalUsage).count, 1)
            XCTAssertFalse(events.contains {
                switch $0 {
                case let .lifecycle(value): return value.state == .failed
                case let .diagnostic(value): return value.severity == .error
                case let .usage(value): return value.isError
                default: return false
                }
            })
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }
}

private extension Array where Element == AgentEvent {
    var assistantTexts: [String] {
        compactMap {
            guard case let .message(message) = $0, message.role == .assistant else { return nil }
            return message.text
        }
    }

    var hasTerminalUsage: Bool { contains(where: \.isTerminalUsage) }
}

private extension AgentEvent {
    var isTerminalUsage: Bool {
        guard case let .usage(usage) = self else { return false }
        return usage.isTerminal == true
    }
}
