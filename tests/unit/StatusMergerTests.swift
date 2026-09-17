// StatusMergerTests — Tier F 收口: exercises the wire+sqlite → HermesStatus
// assembly logic that used to live in AppDelegate. Runs under `xcodebuild
// test` via the XcodeGen-generated xcodeproj; the app shell just calls these
// pure functions, so the state-shaping rules are now pinned by tests.

import XCTest
import HermesDomain
import Foundation

final class StatusMergerTests: XCTestCase {

    private func wire(_ json: String) -> HermesWireStatus {
        do {
            return try JSONDecoder().decode(
                HermesWireStatus.self,
                from: Data(json.utf8))
        } catch {
            fatalError("bad wire json in test: \(error)")
        }
    }

    /// Two sessions: `top` is most-recent (state working), `idle_a` is an
    /// older idle session (state ready). Mirrors the session-linkage scenario.
    private let twoSessionFrame = """
    {"v":1,"ts":1789440715.0,"gateway":{"running":true,"manager":"launchd","pids":[1]},
     "session":{"id":"top","source":"feishu","model":"MiniMax-M3","started_at":1.0,"last_active":2.0},
     "sessions":[
       {"id":"top","source":"feishu","model":"MiniMax-M3","started_at":1.0,"last_active":2.0,"state":"working"},
       {"id":"idle_a","source":"tui","model":"MiniMax-M3","started_at":1.0,"last_active":1.0,"state":"ready"}
     ],
     "session_count":2,"state":"working",
     "approval":{"pending":false,"prompt":null,"tool":null},
     "cron":{"last_fired_at":null,"recent_job_id":null},
     "skin":"slate","recent_messages":[]}
    """

    func testResolveDisplaySession() {
        let w = wire(twoSessionFrame)

        // No pin → most recent (sessions.first = top).
        let auto = HermesStatusMerger.resolveDisplaySession(w, pinnedSessionId: nil)
        XCTAssertEqual(auto?.id, "top", "no pin → top session")

        // Pin hits → the pinned session, even though top is more recent.
        let pinned = HermesStatusMerger.resolveDisplaySession(w, pinnedSessionId: "idle_a")
        XCTAssertEqual(pinned?.id, "idle_a", "pin hit → pinned session")

        // Pin misses (session gone from list) → fall back to top.
        let stalePin = HermesStatusMerger.resolveDisplaySession(w, pinnedSessionId: "vanished")
        XCTAssertEqual(stalePin?.id, "top", "stale pin → top session")

        // Empty sessions → legacy single-session field.
        let single = wire("""
        {"v":1,"ts":1.0,"gateway":{"running":true,"manager":"launchd","pids":[]},
         "session":{"id":"only","source":"tui","model":"M3","started_at":1.0,"last_active":1.0},
         "sessions":[],"session_count":0,"state":null,
         "approval":{"pending":false,"prompt":null,"tool":null},
         "cron":{"last_fired_at":null,"recent_job_id":null},"skin":null,"recent_messages":[]}
        """)
        XCTAssertEqual(HermesStatusMerger.resolveDisplaySession(single, pinnedSessionId: nil)?.id,
                       "only", "empty sessions → legacy session field")
        // Pin miss with empty sessions → falls back to the legacy field too.
        XCTAssertEqual(HermesStatusMerger.resolveDisplaySession(single, pinnedSessionId: "x")?.id,
                       "only", "pin miss + empty sessions → legacy session field")
    }

    func testMergeAuthoritativeStateFollowsDisplaySession() {
        let w = wire(twoSessionFrame)
        let now = Date(timeIntervalSince1970: 1789441000.0)

        // Pinned to the IDLE session while top is working → state must say
        // ready (the session-linkage fix), NOT the global working.
        let pinned = HermesStatusMerger.resolveDisplaySession(w, pinnedSessionId: "idle_a")
        let merged = HermesStatusMerger.merge(
            wire: w, sqlite: .empty, displaySession: pinned, now: now)
        XCTAssertEqual(merged.authoritativeState, .ready,
                       "pinned idle session → state pill shows ready")

        // No pin → displaySession = top → working.
        let auto = HermesStatusMerger.merge(
            wire: w, sqlite: .empty,
            displaySession: HermesStatusMerger.resolveDisplaySession(w, pinnedSessionId: nil),
            now: now)
        XCTAssertEqual(auto.authoritativeState, .working,
                       "auto-follow top → state pill shows working")

        // Display session with nil state → falls back to wire.state.
        let noState = wire("""
        {"v":1,"ts":1.0,"gateway":{"running":true,"manager":"launchd","pids":[]},
         "session":{"id":"top","source":"tui","model":"M3","started_at":1.0,"last_active":2.0},
         "sessions":[{"id":"top","source":"tui","model":"M3","started_at":1.0,"last_active":2.0}],
         "session_count":1,"state":"error",
         "approval":{"pending":false,"prompt":null,"tool":null},
         "cron":{"last_fired_at":null,"recent_job_id":null},"skin":null,"recent_messages":[]}
        """)
        let fallback = HermesStatusMerger.merge(
            wire: noState, sqlite: .empty,
            displaySession: noState.sessions.first, now: now)
        XCTAssertEqual(fallback.authoritativeState, .error,
                       "display session w/o per-session state → wire.state fallback")
    }

    func testMergeFields() {
        let w = wire(twoSessionFrame)
        let now = Date(timeIntervalSince1970: 1789441000.0)
        let sqlite = HermesStatus(
            now: now, lastAssistantMessageAt: nil, lastUserMessageAt: nil,
            lastToolCallAt: nil, lastReasoningAt: nil, lastFinishReason: nil,
            authoritativeState: nil,
            activeSessionId: "sqlite_sid", activeSessionSource: "sqlite_src",
            activeSessionModel: "sqlite_model", activeSessionTitle: nil,
            model: "sqlite_model", provider: "sqlite_provider",
            contextTokens: 42, contextMax: 100,
            recentMessages: [], gatewayUp: false, cronRecentlyFired: true,
            waitingForApproval: false, lastErrorMessage: nil)

        let merged = HermesStatusMerger.merge(
            wire: w, sqlite: sqlite,
            displaySession: HermesStatusMerger.resolveDisplaySession(w, pinnedSessionId: nil),
            now: now)

        // Session identity comes from the picked session, not sqlite.
        XCTAssertEqual(merged.activeSessionId, "top", "session id from picked")
        XCTAssertEqual(merged.activeSessionSource, "feishu", "source from picked")
        XCTAssertEqual(merged.activeSessionModel, "MiniMax-M3", "model from picked")
        XCTAssertEqual(merged.model, "MiniMax-M3", "model pill from picked")

        // Wire ctx wins; when the wire has none, sqlite fills in.
        XCTAssertEqual(merged.contextTokens, 42, "wire ctx nil → sqlite fallback")
        XCTAssertEqual(merged.provider, "sqlite_provider", "provider from sqlite")

        // Gateway from wire overrides sqlite.
        XCTAssertTrue(merged.gatewayUp, "wire gateway.running wins")

        // Approval ORs both.
        XCTAssertFalse(merged.waitingForApproval, "approval false")
    }

    func testMergeCronAndError() {
        let now = Date(timeIntervalSince1970: 1789441000.0)

        // cron fired 9s ago → recently fired (within 10s window).
        let recentCron = wire("""
        {"v":1,"ts":1789440991.0,"gateway":{"running":true,"manager":"launchd","pids":[]},
         "session":null,"sessions":[],"session_count":0,"state":null,
         "approval":{"pending":false,"prompt":null,"tool":null},
         "cron":{"last_fired_at":1789440991.0,"recent_job_id":"morning"},
         "skin":null,"recent_messages":[]}
        """)
        let m1 = HermesStatusMerger.merge(wire: recentCron, sqlite: .empty, now: now)
        XCTAssertTrue(m1.cronRecentlyFired, "cron 9s ago → recently fired")

        // cron fired 11s ago → not recently fired by wire, but sqlite can still mark it.
        let oldCron = wire("""
        {"v":1,"ts":1789440989.0,"gateway":{"running":true,"manager":"launchd","pids":[]},
         "session":null,"sessions":[],"session_count":0,"state":null,
         "approval":{"pending":false,"prompt":null,"tool":null},
         "cron":{"last_fired_at":1789440989.0,"recent_job_id":"morning"},
         "skin":null,"recent_messages":[]}
        """)
        let m2 = HermesStatusMerger.merge(wire: oldCron, sqlite: .empty, now: now)
        XCTAssertFalse(m2.cronRecentlyFired, "cron 11s ago → not recently fired")

        // Error finish_reason in recent messages → lastErrorMessage set.
        let errWire = wire("""
        {"v":1,"ts":1789440999.0,"gateway":{"running":true,"manager":"launchd","pids":[]},
         "session":null,"sessions":[],"session_count":0,"state":"error",
         "approval":{"pending":false,"prompt":null,"tool":null},
         "cron":{"last_fired_at":null,"recent_job_id":null},
         "skin":null,
         "recent_messages":[{"role":"assistant","timestamp":1789440999.0,"tool_name":null,"finish_reason":"error","is_reasoning":false}]}
        """)
        let m3 = HermesStatusMerger.merge(wire: errWire, sqlite: .empty, now: now)
        XCTAssertNotNil(m3.lastErrorMessage, "error finish_reason → lastErrorMessage")
        XCTAssertEqual(m3.lastErrorMessage?.timeIntervalSince1970, 1789440999.0,
                       "lastErrorMessage timestamp preserved")
    }
}
