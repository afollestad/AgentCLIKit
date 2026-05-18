import XCTest

@testable import AgentCLIKit

final class AgentHookTests: XCTestCase {
    func testTokenStoreValidatesInvalidatesAndExpiresTokens() async {
        let clock = TestClock(date: Date(timeIntervalSince1970: 10))
        let store = AgentHookTokenStore(now: { clock.date })

        let token = await store.issue(validFor: 5)
        let initiallyValid = await store.validate(token.value)
        XCTAssertTrue(initiallyValid)

        clock.date = Date(timeIntervalSince1970: 20)
        let expired = await store.validate(token.value)
        XCTAssertFalse(expired)

        let secondToken = await store.issue(validFor: 5)
        let secondInitiallyValid = await store.validate(secondToken.value)
        XCTAssertTrue(secondInitiallyValid)

        await store.invalidate(secondToken.value)
        let invalidated = await store.validate(secondToken.value)
        XCTAssertFalse(invalidated)
    }

    func testHookEventRoundTripsThroughJSON() throws {
        let event = AgentHookEvent(
            id: "hook",
            providerId: "provider",
            name: "PreToolUse",
            conversationId: "conversation",
            payload: .object(["tool": .string("Edit")]),
            receivedAt: Date(timeIntervalSince1970: 10)
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(AgentHookEvent.self, from: data)

        XCTAssertEqual(decoded, event)
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storedDate: Date

    var date: Date {
        get {
            lock.withLock { storedDate }
        }
        set {
            lock.withLock { storedDate = newValue }
        }
    }

    init(date: Date) {
        self.storedDate = date
    }
}
