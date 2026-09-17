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

public struct HermesWireStatus: Codable {
    public let v: Int
    public let ts: TimeInterval
    public let gateway: HermesWireGateway
    public let session: HermesWireSession?
    public let sessions: [HermesWireSession]
    public let sessionCount: Int
    public let state: HermesWireState?
    public let approval: HermesWireApproval
    public let cron: HermesWireCron
    /// Current-context usage as computed by Hermes' own estimator on the
    /// active session's live messages (NOT the cumulative sessions tokens —
    /// that misreported ~70% for a real 2% window). Nil when the Python side
    /// could not estimate; merge falls back to the sqlite-derived value.
    public let contextTokens: Int?
    public let contextMax: Int?
    public let skin: String?
    public let recentMessages: [HermesWireMessage]
    public let error: String?

    public enum CodingKeys: String, CodingKey {
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
    public static let supportedVersion = 1
}

public struct HermesWireGateway: Codable {
    public let running: Bool
    public let manager: String
    public let pids: [Int]
}

public struct HermesWireSession: Codable {
    public let id: String?
    public let source: String?
    public let model: String?
    public let startedAt: TimeInterval?
    public let lastActive: TimeInterval?
    /// Human-readable session title (TUI/CLI sessions carry one, e.g.
    /// "评审Matrix看板widget方案"; gateway sessions may be empty). The picker
    /// falls back to `source (id)` when nil/empty.
    public let title: String?
    /// Per-session authoritative state (session linkage). Python derives a
    /// state for EVERY active session; when the user pins one, Swift uses
    /// THIS session's state so the state pill follows what the user is
    /// looking at. Nil when the frame predates the field or the session has
    /// no derivable state.
    public let state: HermesWireState?

    public enum CodingKeys: String, CodingKey {
        case id, source, model, title, state
        case startedAt = "started_at"
        case lastActive = "last_active"
    }
}

/// Hermes-supplied state. `nil` means "I don't know" — fall back to local
/// time-window heuristics in `StateMachine`.
public enum HermesWireState: String, Codable {
    case idle, ready, thinking, working, streaming
    case waitingApproval = "waiting_approval"
    case ok, error

    /// Wire state → the UI's HermesState. The wire has no `gatewayDown`
    /// (that's a local inference from `gateway.running`), so the mapping is
    /// total — every wire value has a UI counterpart.
    public func toHermesState() -> HermesState {
        switch self {
        case .idle:            return .idle
        case .ready:           return .ready
        case .thinking:        return .thinking
        case .working:         return .working
        case .streaming:       return .streaming
        case .waitingApproval: return .waitingApproval
        case .ok:              return .ok
        case .error:           return .error
        }
    }
}

public struct HermesWireApproval: Codable {
    public let pending: Bool
    public let prompt: String?
    public let tool: String?
}

public struct HermesWireCron: Codable {
    public let lastFiredAt: TimeInterval?
    public let recentJobId: String?

    public enum CodingKeys: String, CodingKey {
        case lastFiredAt = "last_fired_at"
        case recentJobId = "recent_job_id"
    }
}

/// One message from the active session, as exposed by
/// `SessionDB.get_messages(session_id, limit=5)`. Only the fields the
/// StateMachine needs are kept; full transcripts are unnecessary for a
/// glanceable Touch Bar.
public struct HermesWireMessage: Codable {
    public let role: String?
    public let timestamp: TimeInterval?
    public let toolName: String?
    public let finishReason: String?
    public let isReasoning: Bool

    public enum CodingKeys: String, CodingKey {
        case role, timestamp
        case toolName = "tool_name"
        case finishReason = "finish_reason"
        case isReasoning = "is_reasoning"
    }
}
