// HermesWireStatus.swift
// Wire format for the long-running Python subprocess (`hermes_source.py`).
// Codable so JSONDecoder can parse line-delimited stdout directly.
//
// Schema version `v` must match `HermesWireStatus.supportedVersion` or the
// source layer drops the frame. Bump `supportedVersion` only on backwards-
// incompatible changes.
//
// Every nested struct uses explicit CodingKeys to map snake_case JSON keys
// (from the Python side) to camelCase Swift properties. Do NOT set
// `keyDecodingStrategy = .convertFromSnakeCase` on the decoder — mixing it
// with explicit mappings causes keyNotFound (see HermesPythonSource.swift).

import Foundation

struct HermesWireStatus: Codable {
    let v: Int
    let ts: TimeInterval
    let gateway: HermesWireGateway
    let session: HermesWireSession?
    let sessions: [HermesWireSession]
    let sessionCount: Int
    let state: HermesWireState?
    let approval: HermesWireApproval
    let cron: HermesWireCron
    /// Current-context usage as computed by Hermes' own estimator on the
    /// active session's live messages (NOT the cumulative sessions tokens —
    /// that misreported ~70% for a real 2% window). Nil when the Python side
    /// could not estimate; merge falls back to the sqlite-derived value.
    let contextTokens: Int?
    let contextMax: Int?
    let skin: String?
    let recentMessages: [HermesWireMessage]
    let error: String?

    enum CodingKeys: String, CodingKey {
        case v, ts, gateway, session, state, approval, cron, skin
        case sessions
        case sessionCount = "session_count"
        case contextTokens = "context_tokens"
        case contextMax = "context_max"
        case recentMessages = "recent_messages"
        case error = "_error"
    }

    /// Schema version this build knows how to decode. Anything else is
    /// logged and dropped (see `HermesPythonSource.decodeAndYield`).
    static let supportedVersion = 1
}

struct HermesWireGateway: Codable {
    let running: Bool
    let manager: String
    let pids: [Int]
}

struct HermesWireSession: Codable {
    let id: String?
    let source: String?
    let model: String?
    let startedAt: TimeInterval?
    let lastActive: TimeInterval?
    /// Human-readable session title (TUI/CLI sessions carry one, e.g.
    /// "评审Matrix看板widget方案"; gateway sessions may be empty). The picker
    /// falls back to `source (id)` when nil/empty.
    let title: String?

    enum CodingKeys: String, CodingKey {
        case id, source, model, title
        case startedAt = "started_at"
        case lastActive = "last_active"
    }
}

/// Hermes-supplied state. `nil` means "I don't know" — fall back to local
/// time-window heuristics in `StateMachine`.
enum HermesWireState: String, Codable {
    case idle, ready, thinking, working, streaming
    case waitingApproval = "waiting_approval"
    case ok, error
}

struct HermesWireApproval: Codable {
    let pending: Bool
    let prompt: String?
    let tool: String?
}

struct HermesWireCron: Codable {
    let lastFiredAt: TimeInterval?
    let recentJobId: String?

    enum CodingKeys: String, CodingKey {
        case lastFiredAt = "last_fired_at"
        case recentJobId = "recent_job_id"
    }
}

/// One message from the active session, as exposed by
/// `SessionDB.get_messages(session_id, limit=5)`. Only the fields the
/// StateMachine needs are kept; full transcripts are unnecessary for a
/// glanceable Touch Bar.
struct HermesWireMessage: Codable {
    let role: String?
    let timestamp: TimeInterval?
    let toolName: String?
    let finishReason: String?
    let isReasoning: Bool

    enum CodingKeys: String, CodingKey {
        case role, timestamp
        case toolName = "tool_name"
        case finishReason = "finish_reason"
        case isReasoning = "is_reasoning"
    }
}
