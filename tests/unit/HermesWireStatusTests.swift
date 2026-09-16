// XCTest port of tests/wire_decode_smoke.swift (47 assertions). Tier E —
// runs under `xcodebuild test` via the XcodeGen-generated xcodeproj.

import XCTest
import Foundation

final class HermesWireStatusTests: XCTestCase {

    func testAll() {
        // 1) Minimal frame: gateway down, no session. Mirrors what
        //    hermes_source.py emits when the Hermes install is unreachable.
        let minimal = """
        {"v":1,"ts":1789440714.987,"gateway":{"running":false,"manager":"launchd","pids":[]},"session":null,"sessions":[],"session_count":0,"state":null,"approval":{"pending":false,"prompt":null,"tool":null},"cron":{"last_fired_at":null,"recent_job_id":null},"skin":null,"recent_messages":[]}
        """
        do {
            let wire = try HermesPythonSource.decoder.decode(
                HermesWireStatus.self,
                from: minimal.data(using: .utf8)!
            )
            XCTAssertEqual(wire.v, 1, "decode minimal: v == 1")
            XCTAssertFalse(wire.gateway.running, "decode minimal: gateway.running == false")
            XCTAssertEqual(wire.gateway.manager, "launchd", "decode minimal: gateway.manager preserved")
            XCTAssertTrue(wire.gateway.pids.isEmpty, "decode minimal: pids empty")
            XCTAssertNil(wire.session, "decode minimal: session nil")
            XCTAssertNil(wire.cron.lastFiredAt, "decode minimal: cron.lastFiredAt nil")
            XCTAssertFalse(wire.approval.pending, "decode minimal: approval.pending false")
            XCTAssertTrue(wire.recentMessages.isEmpty, "decode minimal: recent_messages empty")
        } catch {
            XCTFail("decode minimal: \(error)")
        }

        // 2) Full frame: gateway up, session present, with all Tier A.2 + B fields.
        let full = """
        {"v":1,"ts":1789440715.535,"gateway":{"running":true,"manager":"launchd","pids":[5965,5730]},"session":{"id":"20260710_093922_c6096a66","source":"feishu","model":"MiniMax-M3","started_at":1783647562.260,"last_active":1783647582.874},"sessions":[{"id":"20260710_093922_c6096a66","source":"feishu","model":"MiniMax-M3","started_at":1783647562.260,"last_active":1783647582.874},{"id":"20260710_093922_deadbeef","source":"tui","model":"MiniMax-M3","started_at":1783647000.0,"last_active":1783647500.0}],"session_count":2,"state":null,"approval":{"pending":true,"prompt":"(Y/n)","tool":"shell_exec"},"cron":{"last_fired_at":1789440700.0,"recent_job_id":"morning"},"skin":"slate","recent_messages":[{"role":"assistant","timestamp":1783647576.45,"tool_name":null,"finish_reason":"tool_calls","is_reasoning":true},{"role":"tool","timestamp":1783647580.08,"tool_name":"terminal","finish_reason":null,"is_reasoning":false},{"role":"assistant","timestamp":1783647582.81,"tool_name":null,"finish_reason":"stop","is_reasoning":false}]}
        """
        do {
            let wire = try HermesPythonSource.decoder.decode(
                HermesWireStatus.self,
                from: full.data(using: .utf8)!
            )
            XCTAssertTrue(wire.gateway.running, "decode full: gateway.running")
            XCTAssertEqual(wire.gateway.pids, [5965, 5730], "decode full: 2 pids")
            XCTAssertEqual(wire.session?.id, "20260710_093922_c6096a66",
                "decode full: session.id maps from snake_case")
            XCTAssertEqual(wire.session?.lastActive, 1783647582.874,
                "decode full: session.lastActive camelCased")
            XCTAssertTrue(wire.approval.pending, "decode full: approval.pending true")
            XCTAssertEqual(wire.approval.tool, "shell_exec", "decode full: approval.tool shell_exec")
            XCTAssertEqual(wire.skin, "slate", "decode full: skin == 'slate'")
            XCTAssertEqual(wire.cron.recentJobId, "morning", "decode full: cron.recentJobId == 'morning'")
            XCTAssertEqual(wire.cron.lastFiredAt, 1789440700.0, "decode full: cron.lastFiredAt as TimeInterval")
            XCTAssertEqual(wire.recentMessages.count, 3, "decode full: 3 recentMessages")
            XCTAssertTrue(wire.recentMessages.first?.isReasoning == true,
                "decode full: first message isReasoning")
            XCTAssertEqual(wire.recentMessages[1].toolName, "terminal",
                "decode full: second message toolName == 'terminal'")
            XCTAssertEqual(wire.recentMessages.last?.finishReason, "stop",
                "decode full: last message finishReason == 'stop'")
            XCTAssertEqual(wire.sessions.count, 2, "decode full: sessions array has 2 entries")
            XCTAssertEqual(wire.sessionCount, 2, "decode full: session_count == 2")
            XCTAssertEqual(wire.sessions.first?.source, "feishu", "decode full: first session is feishu")
            XCTAssertEqual(wire.sessions[1].source, "tui", "decode full: second session is tui")
        } catch {
            XCTFail("decode full: \(error)")
        }

        // 2b) Tier A.3: wire `state` maps to HermesState via toHermesState().
        let stateFrame = """
        {"v":1,"ts":1.0,"gateway":{"running":true,"manager":"x","pids":[]},"session":{"id":"s1","source":"tui","model":"m","started_at":1.0,"last_active":1.0},"sessions":[{"id":"s1","source":"tui","model":"m","started_at":1.0,"last_active":1.0}],"session_count":1,"state":"working","approval":{"pending":false,"prompt":null,"tool":null},"cron":{"last_fired_at":null,"recent_job_id":null},"skin":null,"recent_messages":[]}
        """
        do {
            let wire = try HermesPythonSource.decoder.decode(
                HermesWireStatus.self,
                from: stateFrame.data(using: .utf8)!
            )
            XCTAssertEqual(wire.state, .working, "decode state: wire.state == .working")
            XCTAssertEqual(wire.state?.toHermesState(), .working, "decode state: toHermesState() == .working")
            XCTAssertEqual(HermesWireState.error.toHermesState(), .error,
                "decode state: HermesWireState.error maps to HermesState.error")
            XCTAssertEqual(HermesWireState.waitingApproval.toHermesState(), .waitingApproval,
                "decode state: HermesWireState.waitingApproval maps")
        } catch {
            XCTFail("decode state: \(error)")
        }

        // 2c) HermesWireActivityTimestamps derivation from a synthetic frame.
        let tsFrame = """
        {"v":1,"ts":1.0,"gateway":{"running":true,"manager":"x","pids":[]},"session":{"id":"s1","source":"tui","model":"m","started_at":1.0,"last_active":1.0},"sessions":[{"id":"s1","source":"tui","model":"m","started_at":1.0,"last_active":1.0}],"session_count":1,"state":null,"approval":{"pending":false,"prompt":null,"tool":null},"cron":{"last_fired_at":null,"recent_job_id":null},"skin":null,"recent_messages":[{"role":"user","timestamp":100.0,"tool_name":null,"finish_reason":null,"is_reasoning":false},{"role":"assistant","timestamp":110.0,"tool_name":null,"finish_reason":"tool_calls","is_reasoning":true},{"role":"tool","timestamp":115.0,"tool_name":"shell","finish_reason":null,"is_reasoning":false},{"role":"assistant","timestamp":120.0,"tool_name":null,"finish_reason":"error","is_reasoning":false}]}
        """
        do {
            let wire = try HermesPythonSource.decoder.decode(
                HermesWireStatus.self,
                from: tsFrame.data(using: .utf8)!
            )
            let derived = HermesWireActivityTimestamps(from: wire.recentMessages)
            XCTAssertEqual(derived.lastAssistantAt?.timeIntervalSince1970, 120.0,
                "derived: lastAssistantAt == 120.0")
            XCTAssertEqual(derived.lastUserAt?.timeIntervalSince1970, 100.0,
                "derived: lastUserAt == 100.0")
            XCTAssertEqual(derived.lastToolAt?.timeIntervalSince1970, 115.0,
                "derived: lastToolAt == 115.0")
            XCTAssertEqual(derived.lastReasoningAt?.timeIntervalSince1970, 110.0,
                "derived: lastReasoningAt == 110.0")
            XCTAssertEqual(derived.lastFinishReason, "error", "derived: lastFinishReason == 'error'")
            XCTAssertEqual(derived.lastErrorAt?.timeIntervalSince1970, 120.0,
                "derived: lastErrorAt == 120.0")
        } catch {
            XCTFail("derived: \(error)")
        }

        // 3) Unknown schema version decodes (filter is upstream).
        let v2 = """
        {"v":2,"ts":1.0,"gateway":{"running":false,"manager":"x","pids":[]},"session":null,"sessions":[],"session_count":0,"state":null,"approval":{"pending":false,"prompt":null,"tool":null},"cron":{"last_fired_at":null,"recent_job_id":null},"skin":null,"recent_messages":[],"new_field":"unknown"}
        """
        do {
            let wire = try HermesPythonSource.decoder.decode(
                HermesWireStatus.self,
                from: v2.data(using: .utf8)!
            )
            XCTAssertEqual(wire.v, 2, "decode v2: succeeds (filter is upstream)")
            XCTAssertEqual(HermesWireStatus.supportedVersion, 1, "decode v2: supportedVersion is 1")
        } catch {
            XCTFail("decode v2: should succeed: \(error)")
        }

        // 4) Malformed JSON: decoder throws (HermesPythonSource catches).
        let bad = "not json"
        do {
            _ = try HermesPythonSource.decoder.decode(
                HermesWireStatus.self,
                from: bad.data(using: .utf8)!
            )
            XCTFail("decode malformed: should throw")
        } catch {
            XCTAssertTrue(true, "decode malformed: throws as expected")
        }

        // 5) HermesWireState enum round-trip
        for raw in ["idle","ready","thinking","working","streaming",
                    "waiting_approval","ok","error"] {
            do {
                let s = try HermesPythonSource.decoder.decode(
                    HermesWireState.self,
                    from: "\"\(raw)\"".data(using: .utf8)!
                )
                _ = s
                XCTAssertTrue(true, "HermesWireState raw '\(raw)' decodes")
            } catch {
                XCTFail("HermesWireState raw '\(raw)': \(error)")
            }
        }

        // 6) HermesWireStatus requires `v` to be present (non-optional Int).
        let missingV = """
        {"ts":1.0,"gateway":{"running":false,"manager":"x","pids":[]},"session":null,"sessions":[],"session_count":0,"state":null,"approval":{"pending":false,"prompt":null,"tool":null},"cron":{"last_fired_at":null,"recent_job_id":null},"skin":null,"recent_messages":[]}
        """
        do {
            _ = try HermesPythonSource.decoder.decode(
                HermesWireStatus.self,
                from: missingV.data(using: .utf8)!
            )
            XCTFail("missing v: should throw")
        } catch {
            XCTAssertTrue(true, "missing v: throws as expected")
        }
    }
}
