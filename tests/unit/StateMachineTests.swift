// XCTest port of tests/state_machine_smoke.swift (19 assertions). Tier E —
// runs under `xcodebuild test` via the XcodeGen-generated xcodeproj.

import XCTest
import HermesDomain
import Foundation

final class StateMachineTests: XCTestCase {

    /// Build a HermesStatus with most fields defaulted so each test focuses
    /// on the lever it cares about. Parameter ORDER must match the call sites.
    private func snapshot(
        gatewayUp: Bool = true,
        activeSessionId: String? = nil,
        lastAssistantMessageAt: Date? = nil,
        lastToolCallAt: Date? = nil,
        lastReasoningAt: Date? = nil,
        lastFinishReason: String? = nil,
        authoritativeState: HermesState? = nil,
        waitingForApproval: Bool = false,
        lastErrorMessage: Date? = nil,
        cronRecentlyFired: Bool = false,
        contextTokens: Int = 0,
        contextMax: Int = 200_000
    ) -> HermesStatus {
        HermesStatus(
            now: Date(),
            lastAssistantMessageAt: lastAssistantMessageAt,
            lastUserMessageAt: nil,
            lastToolCallAt: lastToolCallAt,
            lastReasoningAt: lastReasoningAt,
            lastFinishReason: lastFinishReason,
            authoritativeState: authoritativeState,
            activeSessionId: activeSessionId,
            activeSessionSource: nil,
            activeSessionModel: nil,
            activeSessionTitle: nil,
            model: "—", provider: "auto",
            contextTokens: contextTokens, contextMax: contextMax,
            recentMessages: [], gatewayUp: gatewayUp,
            cronRecentlyFired: cronRecentlyFired,
            waitingForApproval: waitingForApproval,
            lastErrorMessage: lastErrorMessage
        )
    }

    func testAll() {
        let sm = StateMachine()

        // 1. gatewayDown always wins, regardless of other signals.
        sm.evaluate(snapshot: snapshot(
            gatewayUp: false,
            activeSessionId: "s1",
            lastAssistantMessageAt: Date(),
            waitingForApproval: true,
            lastErrorMessage: Date()
        ))
        XCTAssertEqual(sm.current, .gatewayDown, "gatewayDown overrides all signals")

        // 2. waitingApproval wins after gateway, before error.
        sm.evaluate(snapshot: snapshot(
            lastAssistantMessageAt: Date(),
            waitingForApproval: true,
            lastErrorMessage: Date()
        ))
        XCTAssertEqual(sm.current, .waitingApproval, "waitingApproval overrides error")

        let now = Date()

        // 3. error within errorWindow (30s).
        sm.evaluate(snapshot: snapshot(
            lastAssistantMessageAt: now,
            lastErrorMessage: now.addingTimeInterval(-5)
        ))
        XCTAssertEqual(sm.current, .error, "error within 30s window → .error")

        // 4. D-3 regression: error 5 minutes ago should NOT be .error.
        sm.evaluate(snapshot: snapshot(
            lastErrorMessage: now.addingTimeInterval(-300)
        ))
        XCTAssertNotEqual(sm.current, .error, "error outside 30s window falls through")

        // 5. working: assistant within 5s and tool call within 5s.
        sm.evaluate(snapshot: snapshot(
            activeSessionId: "s1",
            lastAssistantMessageAt: now.addingTimeInterval(-2),
            lastToolCallAt: now.addingTimeInterval(-1)
        ))
        XCTAssertEqual(sm.current, .working, "assistant + tool within 5s → .working")

        // 6. thinking: assistant within 5s and reasoning within 5s, no tool.
        sm.evaluate(snapshot: snapshot(
            activeSessionId: "s1",
            lastAssistantMessageAt: now.addingTimeInterval(-2),
            lastReasoningAt: now.addingTimeInterval(-1)
        ))
        XCTAssertEqual(sm.current, .thinking, "assistant + reasoning within 5s → .thinking")

        // 7. Tier A.3 FIXED GAP: assistant within the 5s workingWindow with
        //    finishReason=nil and no tool/reasoning activity → DESIGN §2
        //    says .streaming (the model is still emitting).
        sm.evaluate(snapshot: snapshot(
            activeSessionId: "s1",
            lastAssistantMessageAt: now.addingTimeInterval(-3),
            lastFinishReason: nil
        ))
        XCTAssertEqual(sm.current, .streaming,
            "assistant 3s ago, finishReason=nil, no tool/reasoning → .streaming")

        // 8. Tier A.3 FIXED GAP: finishReason=stop within workingWindow →
        //    .ok (completed), not .working.
        sm.evaluate(snapshot: snapshot(
            activeSessionId: "s1",
            lastAssistantMessageAt: now.addingTimeInterval(-3),
            lastFinishReason: "stop"
        ))
        XCTAssertEqual(sm.current, .ok, "assistant 3s ago, finishReason=stop → .ok")

        // 8b. The outer branch DOES catch finishReason=stop once past streamingWindow.
        sm.evaluate(snapshot: snapshot(
            activeSessionId: "s1",
            lastAssistantMessageAt: now.addingTimeInterval(-10),
            lastFinishReason: "stop"
        ))
        XCTAssertEqual(sm.current, .ok, "assistant 10s ago, finishReason=stop → .ok (streamingWindow passed)")

        // 8c. Tier A.3: authoritative state is trusted over conflicting
        //     local heuristics.
        sm.evaluate(snapshot: snapshot(
            activeSessionId: "s1",
            lastAssistantMessageAt: now.addingTimeInterval(-30),
            lastFinishReason: "stop",
            authoritativeState: .working
        ))
        XCTAssertEqual(sm.current, .working, "authoritative .working overrides stale stop window")

        // 8d. Authoritative .error also wins over a silent local window.
        sm.evaluate(snapshot: snapshot(
            activeSessionId: "s1",
            authoritativeState: .error
        ))
        XCTAssertEqual(sm.current, .error, "authoritative .error wins")

        // 8e. gatewayDown outranks authoritative state (hard priority).
        sm.evaluate(snapshot: snapshot(
            gatewayUp: false,
            activeSessionId: "s1",
            authoritativeState: .working
        ))
        XCTAssertEqual(sm.current, .gatewayDown, "gatewayDown overrides authoritative state")

        // 8f. waitingApproval outranks authoritative state.
        sm.evaluate(snapshot: snapshot(
            activeSessionId: "s1",
            authoritativeState: .working,
            waitingForApproval: true
        ))
        XCTAssertEqual(sm.current, .waitingApproval, "waitingApproval overrides authoritative state")

        // 8g. Authoritative .idle with a present session → .idle.
        sm.evaluate(snapshot: snapshot(
            activeSessionId: "s1",
            authoritativeState: .idle
        ))
        XCTAssertEqual(sm.current, .idle, "authoritative .idle beats session→ready default")

        // 9. idle: no session at all, no signals.
        sm.evaluate(snapshot: snapshot(activeSessionId: nil))
        XCTAssertEqual(sm.current, .idle, "no session, no signals → .idle")

        // 10. ready: session present but no recent activity.
        sm.evaluate(snapshot: snapshot(activeSessionId: "s1"))
        XCTAssertEqual(sm.current, .ready, "session, no recent activity → .ready")

        // 11. D-3 sanity: lastErrorMessage: Date participates in the window check.
        let direct: HermesStatus = HermesStatus(
            now: Date(), lastAssistantMessageAt: nil, lastUserMessageAt: nil,
            lastToolCallAt: nil, lastReasoningAt: nil, lastFinishReason: nil,
            authoritativeState: nil,
            activeSessionId: nil, activeSessionSource: nil, activeSessionModel: nil,
            activeSessionTitle: nil,
            model: "—", provider: "auto",
            contextTokens: 0, contextMax: 0,
            recentMessages: [], gatewayUp: true,
            cronRecentlyFired: false, waitingForApproval: false,
            lastErrorMessage: Date().addingTimeInterval(-2)
        )
        sm.evaluate(snapshot: direct)
        XCTAssertEqual(sm.current, .error, "D-3: lastErrorMessage: Date? reaches the error branch")

        // 12. State enum exposes stable rawValues (used in menu display).
        XCTAssertEqual(HermesState.idle.rawValue, "idle", "HermesState.idle.rawValue == \"idle\"")
        XCTAssertEqual(HermesState.gatewayDown.rawValue, "gatewayDown",
            "HermesState.gatewayDown.rawValue == \"gatewayDown\"")
    }
}
