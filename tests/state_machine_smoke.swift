// Smoke check for StateMachine — covers Tier D-3 (lastErrorMessage: Date?)
// plus the full 9-state priority and window logic.
//
// Build & run: see scripts/test.sh
// Args in `snapshot(...)` must match the helper's declared order.

import Foundation
import AppKit

@main
enum StateMachineSmoke {
    static var pass = 0
    static var fail = 0
    static func check(_ label: String, _ ok: Bool) {
        if ok { pass += 1; print("  ✓ \(label)") }
        else  { fail += 1; print("  ✗ \(label)") }
    }

    /// Build a HermesStatus with most fields defaulted so each test focuses
    /// on the lever it cares about. Parameter ORDER must match the call sites.
    static func snapshot(
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

    static func main() {
        print("== StateMachine smoke check ==")
        let sm = StateMachine()

        // 1. gatewayDown always wins, regardless of other signals.
        sm.evaluate(snapshot: snapshot(
            gatewayUp: false,
            activeSessionId: "s1",
            lastAssistantMessageAt: Date(),
            waitingForApproval: true,
            lastErrorMessage: Date()
        ))
        check("gatewayDown overrides all signals", sm.current == .gatewayDown)

        // 2. waitingApproval wins after gateway, before error.
        sm.evaluate(snapshot: snapshot(
            lastAssistantMessageAt: Date(),
            waitingForApproval: true,
            lastErrorMessage: Date()
        ))
        check("waitingApproval overrides error", sm.current == .waitingApproval)

        let now = Date()

        // 3. error within errorWindow (30s).
        sm.evaluate(snapshot: snapshot(
            lastAssistantMessageAt: now,
            lastErrorMessage: now.addingTimeInterval(-5)
        ))
        check("error within 30s window → .error", sm.current == .error)

        // 4. D-3 regression: error 5 minutes ago should NOT be .error.
        sm.evaluate(snapshot: snapshot(
            lastErrorMessage: now.addingTimeInterval(-300)
        ))
        check("error outside 30s window falls through", sm.current != .error)

        // 5. working: assistant within 5s and tool call within 5s.
        sm.evaluate(snapshot: snapshot(
            activeSessionId: "s1",
            lastAssistantMessageAt: now.addingTimeInterval(-2),
            lastToolCallAt: now.addingTimeInterval(-1)
        ))
        check("assistant + tool within 5s → .working", sm.current == .working)

        // 6. thinking: assistant within 5s and reasoning within 5s, no tool.
        sm.evaluate(snapshot: snapshot(
            activeSessionId: "s1",
            lastAssistantMessageAt: now.addingTimeInterval(-2),
            lastReasoningAt: now.addingTimeInterval(-1)
        ))
        check("assistant + reasoning within 5s → .thinking", sm.current == .thinking)

        // 7. Tier A.3 FIXED GAP: assistant within the 5s workingWindow with
        //    finishReason=nil and no tool/reasoning activity → DESIGN §2
        //    says .streaming (the model is still emitting). Pre-A.3 this
        //    fell through to .working.
        sm.evaluate(snapshot: snapshot(
            activeSessionId: "s1",
            lastAssistantMessageAt: now.addingTimeInterval(-3),
            lastFinishReason: nil
        ))
        check("assistant 3s ago, finishReason=nil, no tool/reasoning → .streaming",
              sm.current == .streaming)

        // 8. Tier A.3 FIXED GAP: finishReason=stop within workingWindow →
        //    .ok (completed), not .working.
        sm.evaluate(snapshot: snapshot(
            activeSessionId: "s1",
            lastAssistantMessageAt: now.addingTimeInterval(-3),
            lastFinishReason: "stop"
        ))
        check("assistant 3s ago, finishReason=stop → .ok",
              sm.current == .ok)

        // 8b. The outer branch DOES catch finishReason=stop once past streamingWindow.
        sm.evaluate(snapshot: snapshot(
            activeSessionId: "s1",
            lastAssistantMessageAt: now.addingTimeInterval(-10),
            lastFinishReason: "stop"
        ))
        check("assistant 10s ago, finishReason=stop → .ok (streamingWindow passed)",
              sm.current == .ok)

        // 8c. Tier A.3: authoritative state is trusted over conflicting
        //     local heuristics (e.g. Hermes says "working" while the local
        //     window would say ok/ready).
        sm.evaluate(snapshot: snapshot(
            activeSessionId: "s1",
            lastAssistantMessageAt: now.addingTimeInterval(-30),
            lastFinishReason: "stop",
            authoritativeState: .working
        ))
        check("authoritative .working overrides stale stop window",
              sm.current == .working)

        // 8d. Authoritative .error also wins over a silent local window.
        sm.evaluate(snapshot: snapshot(
            activeSessionId: "s1",
            authoritativeState: .error
        ))
        check("authoritative .error wins", sm.current == .error)

        // 8e. gatewayDown outranks authoritative state (hard priority).
        sm.evaluate(snapshot: snapshot(
            gatewayUp: false,
            activeSessionId: "s1",
            authoritativeState: .working
        ))
        check("gatewayDown overrides authoritative state",
              sm.current == .gatewayDown)

        // 8f. waitingApproval outranks authoritative state.
        sm.evaluate(snapshot: snapshot(
            activeSessionId: "s1",
            authoritativeState: .working,
            waitingForApproval: true
        ))
        check("waitingApproval overrides authoritative state",
              sm.current == .waitingApproval)

        // 8g. Authoritative .idle with a present session → .idle (Hermes'
        //     verdict beats the "session exists → ready" default).
        sm.evaluate(snapshot: snapshot(
            activeSessionId: "s1",
            authoritativeState: .idle
        ))
        check("authoritative .idle beats session→ready default",
              sm.current == .idle)

        // 9. idle: no session at all, no signals.
        sm.evaluate(snapshot: snapshot(activeSessionId: nil))
        check("no session, no signals → .idle", sm.current == .idle)

        // 10. ready: session present but no recent activity.
        sm.evaluate(snapshot: snapshot(activeSessionId: "s1"))
        check("session, no recent activity → .ready", sm.current == .ready)

        // 11. D-3 sanity: HermesStatus with `lastErrorMessage: Date` (not String)
        //     participates in the window check. (Test would not have compiled
        //     before D-3.)
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
        check("D-3: lastErrorMessage: Date? reaches the error branch",
              sm.current == .error)

        // 12. State enum exposes stable rawValues (used in menu display).
        check("HermesState.idle.rawValue == \"idle\"",
              HermesState.idle.rawValue == "idle")
        check("HermesState.gatewayDown.rawValue == \"gatewayDown\"",
              HermesState.gatewayDown.rawValue == "gatewayDown")

        print()
        print("== \(pass) passed, \(fail) failed ==")
        exit(fail == 0 ? 0 : 1)
    }
}
