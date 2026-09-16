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

        // 7. KNOWN GAP: when assistant message is within the 5s workingWindow
        //    and there is no tool/reasoning activity, the current StateMachine
        //    falls through to `.working` regardless of finishReason — DESIGN §2
        //    says nil finishReason should be `.streaming`. Tier A will replace
        //    this whole fallback with "trust Hermes' state" so the gap closes
        //    upstream. Locking current behavior for now.
        sm.evaluate(snapshot: snapshot(
            activeSessionId: "s1",
            lastAssistantMessageAt: now.addingTimeInterval(-3),
            lastFinishReason: nil
        ))
        check("assistant 3s ago, finishReason=nil, no tool/reasoning → .working (gap, see comment)",
              sm.current == .working)

        // 8. KNOWN GAP: `.ok` only triggers when age is past streamingWindow
        //    (8s) and finishReason == "stop". Within workingWindow the code
        //    defaults to `.working`. Same Tier-A-closes-this logic.
        sm.evaluate(snapshot: snapshot(
            activeSessionId: "s1",
            lastAssistantMessageAt: now.addingTimeInterval(-3),
            lastFinishReason: "stop"
        ))
        check("assistant 3s ago, finishReason=stop → .working (gap, see comment)",
              sm.current == .working)

        // 8b. The outer branch DOES catch finishReason=stop once past streamingWindow.
        sm.evaluate(snapshot: snapshot(
            activeSessionId: "s1",
            lastAssistantMessageAt: now.addingTimeInterval(-10),
            lastFinishReason: "stop"
        ))
        check("assistant 10s ago, finishReason=stop → .ok (streamingWindow passed)",
              sm.current == .ok)

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
