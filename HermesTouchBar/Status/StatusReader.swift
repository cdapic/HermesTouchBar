// StatusReader.swift
// Pulls a HermesStatus snapshot from ~/.hermes/state.db, jobs.json, gateway.pid.
//
// Strategy:
//   1. open SQLite readonly (cheap; Hermes holds the write lock briefly).
//   2. read latest 10 messages of the most recent session, plus model/session info.
//   3. read ~/.hermes/cron/jobs.json mtime to detect "just fired" jobs.
//   4. read gateway.pid + check liveness via kill(pid, 0).
// Errors degrade to .empty; never crash the menu-bar app.

import Foundation
import SQLite3

final class StatusReader {

    private let hermesHome: URL
    private var db: OpaquePointer?
    private var lastDbMtime: Date = .distantPast
    private var timer: Timer?
    private(set) var snapshot: HermesStatus = .empty

    init(hermesHome: URL = StatusReader.defaultHome()) {
        self.hermesHome = hermesHome
        openDB()
    }

    deinit { sqlite3_close(db) }

    // MARK: - Lifecycle
    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = 0.3
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() { timer?.invalidate(); timer = nil }

    // MARK: - Default Hermes home
    static func defaultHome() -> URL {
        let env = ProcessInfo.processInfo.environment["HERMES_HOME"]
        if let env, !env.isEmpty { return URL(fileURLWithPath: env) }
        return URL(fileURLWithPath: NSString("~/.hermes").expandingTildeInPath)
    }

    // MARK: - Refresh
    private func refresh() {
        let dbURL = hermesHome.appendingPathComponent("state.db")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: dbURL.path),
           let mtime = attrs[.modificationDate] as? Date,
           mtime > lastDbMtime {
            lastDbMtime = mtime
            // Reopen to pick up new schema / WAL checkpoints
            sqlite3_close(db); db = nil
            openDB()
        }
        snapshot = collect()
    }

    private func openDB() {
        let path = hermesHome.appendingPathComponent("state.db").path
        var handle: OpaquePointer?
        if sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            db = handle
        } else {
            db = nil
        }
    }

    // MARK: - Collect
    private func collect() -> HermesStatus {
        let now = Date()
        let model = readConfigModel()
        let provider = readConfigProvider()
        let gatewayUp = checkGateway()
        let cronRecently = checkCronFired()
        let (session, msgs, ctx, finish) = readSession()
        let (lastReasoning, lastTool, lastUser, lastAssistant) = timestamps(msgs)
        let lastError = lastErrorMessage(in: msgs)
        let waiting = checkApproval(in: msgs)
        return HermesStatus(
            now: now,
            lastAssistantMessageAt: lastAssistant,
            lastUserMessageAt: lastUser,
            lastToolCallAt: lastTool,
            lastReasoningAt: lastReasoning,
            lastFinishReason: finish,
            // Fallback path only — StatusReader has no Hermes-authoritative
            // state; that comes exclusively from the Python wire.
            authoritativeState: nil,
            activeSessionId: session?.id,
            activeSessionSource: session?.source,
            activeSessionModel: session?.model,
            activeSessionTitle: session?.title,
            model: model,
            provider: provider,
            contextTokens: ctx.used,
            contextMax: ctx.max,
            recentMessages: msgs,
            gatewayUp: gatewayUp,
            cronRecentlyFired: cronRecently,
            waitingForApproval: waiting,
            lastErrorMessage: lastError
        )
    }

    // MARK: - Read helpers
    private struct SessionInfo { let id: String; let source: String; let model: String?; let title: String? }

    private func readSession() -> (SessionInfo?, [RecentMessage], (used: Int, max: Int), String?) {
        guard let db else { return (nil, [], (0, 0), nil) }
        // Most recently active session
        var session: SessionInfo?
        var sql = """
        SELECT id, source, COALESCE(model, ''), COALESCE(input_tokens,0)+COALESCE(output_tokens,0),
               COALESCE(title, '')
        FROM sessions
        ORDER BY started_at DESC
        LIMIT 1;
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let source = String(cString: sqlite3_column_text(stmt, 1))
                let model = String(cString: sqlite3_column_text(stmt, 2))
                let used = Int(sqlite3_column_int64(stmt, 3))
                let title = String(cString: sqlite3_column_text(stmt, 4))
                session = SessionInfo(id: id, source: source, model: model,
                                      title: title.isEmpty ? nil : title)
                // Crude context max: 200k default for Anthropic, 128k for most others
                let max = model.lowercased().contains("opus") || model.lowercased().contains("gpt-4") ? 200_000 : 128_000
                sqlite3_finalize(stmt); stmt = nil
                let msgs = readRecentMessages(sessionId: id, limit: 10)
                let lastFinish = msgs.last(where: { $0.role == "assistant" })?.finishReason
                return (session, msgs, (used, max), lastFinish)
            }
            sqlite3_finalize(stmt)
        }
        return (nil, [], (0, 0), nil)
    }

    private func readRecentMessages(sessionId: String, limit: Int) -> [RecentMessage] {
        guard let db else { return [] }
        var out: [RecentMessage] = []
        let sql = """
        SELECT role, timestamp, COALESCE(tool_name,''), COALESCE(finish_reason,''),
               COALESCE(reasoning,''), COALESCE(reasoning_content,'')
        FROM messages
        WHERE session_id = ? AND active = 1 AND compacted = 0
        ORDER BY timestamp DESC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let role = String(cString: sqlite3_column_text(stmt, 0))
                let ts = sqlite3_column_double(stmt, 1)
                let tool = String(cString: sqlite3_column_text(stmt, 2))
                let finish = String(cString: sqlite3_column_text(stmt, 3))
                let reason1 = String(cString: sqlite3_column_text(stmt, 4))
                let reason2 = String(cString: sqlite3_column_text(stmt, 5))
                let isReasoning = (!reason1.isEmpty || !reason2.isEmpty) && role == "assistant"
                out.append(RecentMessage(
                    role: role,
                    timestamp: Date(timeIntervalSince1970: ts),
                    toolName: tool.isEmpty ? nil : tool,
                    finishReason: finish.isEmpty ? nil : finish,
                    isReasoning: isReasoning
                ))
            }
        }
        sqlite3_finalize(stmt)
        return out
    }

    private func timestamps(_ msgs: [RecentMessage]) -> (Date?, Date?, Date?, Date?) {
        var lastReasoning: Date?; var lastTool: Date?; var lastUser: Date?; var lastAssistant: Date?
        for m in msgs {
            switch m.role {
            case "assistant":
                if lastAssistant == nil { lastAssistant = m.timestamp }
                if m.isReasoning, lastReasoning == nil { lastReasoning = m.timestamp }
            case "tool":
                if lastTool == nil { lastTool = m.timestamp }
            case "user":
                if lastUser == nil { lastUser = m.timestamp }
            default: break
            }
        }
        return (lastReasoning, lastTool, lastUser, lastAssistant)
    }

    private func lastErrorMessage(in msgs: [RecentMessage]) -> Date? {
        // Return the most recent assistant message that finished with an
        // error — the StateMachine uses this to gate the `error` state.
        // D-3: previously this serialized to an ISO8601 string and the
        // StateMachine parsed it back; the round-trip was lossy when
        // upstream emitted fractional seconds.
        for m in msgs where m.role == "assistant" && m.finishReason == "error" {
            return m.timestamp
        }
        return nil
    }

    private func checkApproval(in msgs: [RecentMessage]) -> Bool {
        // Hermes prompts "(y/N)" via shell_dollar blocks; flag if last assistant
        // message has an open question mark + recent tool call.
        guard let last = msgs.first(where: { $0.role == "assistant" }) else { return false }
        let age = Date().timeIntervalSince(last.timestamp)
        return age < 5 && last.finishReason == nil
    }

    private func checkGateway() -> Bool {
        let pidPath = hermesHome.appendingPathComponent("gateway.pid").path
        guard let content = try? String(contentsOfFile: pidPath, encoding: .utf8) else { return false }
        let lines = content.split(separator: "\n").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        for pid in lines where pid > 0 {
            if kill(pid_t(pid), 0) == 0 { return true }
        }
        return false
    }

    private func checkCronFired() -> Bool {
        let jobsPath = hermesHome.appendingPathComponent("cron/jobs.json").path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: jobsPath),
              let mtime = attrs[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(mtime) < 10
    }

    private func readConfigModel() -> String {
        let p = hermesHome.appendingPathComponent("config.yaml").path
        guard let raw = try? String(contentsOfFile: p, encoding: .utf8) else { return "—" }
        // Regex: model: foo  OR  model: { default: foo, ... }
        for line in raw.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("model:") {
                let v = trimmed.dropFirst("model:".count).trimmingCharacters(in: .whitespaces)
                if v.hasPrefix("{") { continue }        // nested; skip
                return String(v)
            }
        }
        if let r = raw.range(of: "default:\\s*([A-Za-z0-9._\\-]+)", options: .regularExpression) {
            let m = raw[r].split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) }
            if let m, !m.isEmpty { return m }
        }
        return "—"
    }

    private func readConfigProvider() -> String {
        // Hermes stores provider under `model:` alias in config.yaml; the
        // simplest stable read is to inspect env HERMES_PROVIDER. Fall back
        // to "auto".
        if let p = ProcessInfo.processInfo.environment["HERMES_PROVIDER"], !p.isEmpty { return p }
        return "auto"
    }
}
