// Smoke check for Tier A wire decoding. Round-trips a real frame emitted by
// hermes_source.py and verifies HermesWireStatus + JSONDecoder agree on the
// schema.
//
// Build & run: scripts/test.sh

import Foundation
import AppKit

@main
enum WireDecodeSmoke {
    static var pass = 0
    static var fail = 0
    static func check(_ label: String, _ ok: Bool) {
        if ok { pass += 1; print("  ✓ \(label)") }
        else  { fail += 1; print("  ✗ \(label)") }
    }

    static func main() {
        print("== HermesWireStatus decode smoke check ==")

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
            check("decode minimal: v == 1", wire.v == 1)
            check("decode minimal: gateway.running == false", wire.gateway.running == false)
            check("decode minimal: gateway.manager preserved",
                  wire.gateway.manager == "launchd")
            check("decode minimal: pids empty", wire.gateway.pids.isEmpty)
            check("decode minimal: session nil", wire.session == nil)
            check("decode minimal: cron.lastFiredAt nil",
                  wire.cron.lastFiredAt == nil)
            check("decode minimal: approval.pending false",
                  wire.approval.pending == false)
            check("decode minimal: recent_messages empty",
                  wire.recentMessages.isEmpty)
        } catch {
            check("decode minimal: \(error)", false)
        }

        // 2) Full frame: gateway up, session present, with all Tier A.2 + B fields.
        let full = """
        {"v":1,"ts":1789440715.535,"gateway":{"running":true,"manager":"launchd","pids":[5965,5730]},"session":{"id":"20260710_093922_c6096a66","source":"feishu","model":"MiniMax-M3","started_at":1783647562.260,"last_active":1783647582.874},"sessions":[{"id":"20260710_093922_c6096a66","source":"feishu","model":"MiniMax-M3","started_at":1783647562.260,"last_active":1783647582.874,"state":"working"},{"id":"20260710_093922_deadbeef","source":"tui","model":"MiniMax-M3","started_at":1783647000.0,"last_active":1783647500.0,"state":"ready"}],"session_count":2,"state":null,"approval":{"pending":true,"prompt":"(Y/n)","tool":"shell_exec"},"cron":{"last_fired_at":1789440700.0,"recent_job_id":"morning"},"skin":"slate","recent_messages":[{"role":"assistant","timestamp":1783647576.45,"tool_name":null,"finish_reason":"tool_calls","is_reasoning":true},{"role":"tool","timestamp":1783647580.08,"tool_name":"terminal","finish_reason":null,"is_reasoning":false},{"role":"assistant","timestamp":1783647582.81,"tool_name":null,"finish_reason":"stop","is_reasoning":false}]}
        """
        do {
            let wire = try HermesPythonSource.decoder.decode(
                HermesWireStatus.self,
                from: full.data(using: .utf8)!
            )
            check("decode full: gateway.running", wire.gateway.running)
            check("decode full: 2 pids", wire.gateway.pids == [5965, 5730])
            check("decode full: session.id maps from snake_case",
                  wire.session?.id == "20260710_093922_c6096a66")
            check("decode full: session.lastActive camelCased",
                  wire.session?.lastActive == 1783647582.874)
            check("decode full: approval.pending true",
                  wire.approval.pending == true)
            check("decode full: approval.tool shell_exec",
                  wire.approval.tool == "shell_exec")
            check("decode full: skin == 'slate'", wire.skin == "slate")
            check("decode full: cron.recentJobId == 'morning'",
                  wire.cron.recentJobId == "morning")
            check("decode full: cron.lastFiredAt as TimeInterval",
                  wire.cron.lastFiredAt == 1789440700.0)
            check("decode full: 3 recentMessages",
                  wire.recentMessages.count == 3)
            check("decode full: first message isReasoning",
                  wire.recentMessages.first?.isReasoning == true)
            check("decode full: second message toolName == 'terminal'",
                  wire.recentMessages[1].toolName == "terminal")
            check("decode full: last message finishReason == 'stop'",
                  wire.recentMessages.last?.finishReason == "stop")
            check("decode full: sessions array has 2 entries",
                  wire.sessions.count == 2)
            check("decode full: session_count == 2",
                  wire.sessionCount == 2)
            check("decode full: first session is feishu",
                  wire.sessions.first?.source == "feishu")
            check("decode full: second session is tui",
                  wire.sessions[1].source == "tui")
            check("decode full: first session has per-session state working",
                  wire.sessions.first?.state == .working)
            check("decode full: second session has per-session state ready",
                  wire.sessions[1].state == .ready)
            check("decode full: legacy session.state nil (field absent)",
                  wire.session?.state == nil)
        } catch {
            check("decode full: \(error)", false)
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
            check("decode state: wire.state == .working", wire.state == .working)
            check("decode state: toHermesState() == .working",
                  wire.state?.toHermesState() == .working)
            check("decode state: HermesWireState.error maps to HermesState.error",
                  HermesWireState.error.toHermesState() == .error)
            check("decode state: HermesWireState.waitingApproval maps",
                  HermesWireState.waitingApproval.toHermesState() == .waitingApproval)
        } catch {
            check("decode state: \(error)", false)
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
            check("derived: lastAssistantAt == 120.0",
                  derived.lastAssistantAt?.timeIntervalSince1970 == 120.0)
            check("derived: lastUserAt == 100.0",
                  derived.lastUserAt?.timeIntervalSince1970 == 100.0)
            check("derived: lastToolAt == 115.0",
                  derived.lastToolAt?.timeIntervalSince1970 == 115.0)
            check("derived: lastReasoningAt == 110.0",
                  derived.lastReasoningAt?.timeIntervalSince1970 == 110.0)
            check("derived: lastFinishReason == 'error'",
                  derived.lastFinishReason == "error")
            check("derived: lastErrorAt == 120.0",
                  derived.lastErrorAt?.timeIntervalSince1970 == 120.0)
        } catch {
            check("derived: \(error)", false)
        }

        // 3) Unknown schema version: HermesPythonSource filters before yielding,
        //    but at the decoder level we still accept it. Verified manually
        //    in production by the v-check; here just confirm decode works.
        let v2 = """
        {"v":2,"ts":1.0,"gateway":{"running":false,"manager":"x","pids":[]},"session":null,"sessions":[],"session_count":0,"state":null,"approval":{"pending":false,"prompt":null,"tool":null},"cron":{"last_fired_at":null,"recent_job_id":null},"skin":null,"recent_messages":[],"new_field":"unknown"}
        """
        do {
            let wire = try HermesPythonSource.decoder.decode(
                HermesWireStatus.self,
                from: v2.data(using: .utf8)!
            )
            check("decode v2: succeeds (filter is upstream)",
                  wire.v == 2)
            check("decode v2: supportedVersion is 1",
                  HermesWireStatus.supportedVersion == 1)
        } catch {
            check("decode v2: should succeed: \(error)", false)
        }

        // 4) Malformed JSON: decoder throws (HermesPythonSource catches).
        let bad = "not json"
        do {
            _ = try HermesPythonSource.decoder.decode(
                HermesWireStatus.self,
                from: bad.data(using: .utf8)!
            )
            check("decode malformed: should throw", false)
        } catch {
            check("decode malformed: throws as expected", true)
        }

        // 5) HermesWireState enum round-trip
        for raw in ["idle","ready","thinking","working","streaming",
                    "waiting_approval","ok","error"] {
            do {
                let s = try HermesPythonSource.decoder.decode(
                    HermesWireState.self,
                    from: "\"\(raw)\"".data(using: .utf8)!
                )
                check("HermesWireState raw '\(raw)' decodes", true)
                _ = s
            } catch {
                check("HermesWireState raw '\(raw)': \(error)", false)
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
            check("missing v: should throw", false)
        } catch {
            check("missing v: throws as expected", true)
        }

        print()
        print("== \(pass) passed, \(fail) failed ==")
        exit(fail == 0 ? 0 : 1)
    }
}
