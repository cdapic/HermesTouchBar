// State.swift
// Models that flow through the app: HermesStatus snapshot + the 9-state enum.
// HermesDomain — pure logic, no AppKit/UI dependency.

import Foundation

/// A snapshot of what Hermes is doing right now. The StatusReader rebuilds this
/// every 1.5s by querying state.db, jobs.json, and gateway.pid.
public struct HermesStatus {
    public let now: Date
    public let lastAssistantMessageAt: Date?
    public let lastUserMessageAt: Date?
    public let lastToolCallAt: Date?
    public let lastReasoningAt: Date?
    public let lastFinishReason: String?
    /// Tier A.3 — Hermes-authoritative state from the Python wire
    /// (`_derive_state` in hermes_source.py: session tail + live heartbeat).
    /// When present, StateMachine trusts it over local time-window
    /// heuristics (only gatewayDown / waitingApproval override it). nil
    /// means "I don't know" → local fallback.
    public let authoritativeState: HermesState?
    public let activeSessionId: String?
    public let activeSessionSource: String?
    public let activeSessionModel: String?
    /// Human-readable title of the active session (TUI/CLI sessions carry
    /// one, e.g. "评审Matrix看板widget方案"). The session pill shows this
    /// instead of the bare source when present.
    public let activeSessionTitle: String?
    public let model: String
    public let provider: String
    public let contextTokens: Int
    public let contextMax: Int
    public let recentMessages: [RecentMessage]
    public let gatewayUp: Bool
    public let cronRecentlyFired: Bool
    public let waitingForApproval: Bool
    public let lastErrorMessage: Date?

    public init(
        now: Date, lastAssistantMessageAt: Date?, lastUserMessageAt: Date?,
        lastToolCallAt: Date?, lastReasoningAt: Date?, lastFinishReason: String?,
        authoritativeState: HermesState?,
        activeSessionId: String?, activeSessionSource: String?,
        activeSessionModel: String?, activeSessionTitle: String?,
        model: String, provider: String, contextTokens: Int, contextMax: Int,
        recentMessages: [RecentMessage], gatewayUp: Bool,
        cronRecentlyFired: Bool, waitingForApproval: Bool,
        lastErrorMessage: Date?
    ) {
        self.now = now
        self.lastAssistantMessageAt = lastAssistantMessageAt
        self.lastUserMessageAt = lastUserMessageAt
        self.lastToolCallAt = lastToolCallAt
        self.lastReasoningAt = lastReasoningAt
        self.lastFinishReason = lastFinishReason
        self.authoritativeState = authoritativeState
        self.activeSessionId = activeSessionId
        self.activeSessionSource = activeSessionSource
        self.activeSessionModel = activeSessionModel
        self.activeSessionTitle = activeSessionTitle
        self.model = model
        self.provider = provider
        self.contextTokens = contextTokens
        self.contextMax = contextMax
        self.recentMessages = recentMessages
        self.gatewayUp = gatewayUp
        self.cronRecentlyFired = cronRecentlyFired
        self.waitingForApproval = waitingForApproval
        self.lastErrorMessage = lastErrorMessage
    }

    public static let empty = HermesStatus(
        now: Date(), lastAssistantMessageAt: nil, lastUserMessageAt: nil,
        lastToolCallAt: nil, lastReasoningAt: nil, lastFinishReason: nil,
        authoritativeState: nil,
        activeSessionId: nil, activeSessionSource: nil, activeSessionModel: nil,
        activeSessionTitle: nil,
        model: "—", provider: "—", contextTokens: 0, contextMax: 0,
        recentMessages: [], gatewayUp: false, cronRecentlyFired: false,
        waitingForApproval: false, lastErrorMessage: nil
    )
}

public struct RecentMessage {
    public let role: String          // "user" | "assistant" | "tool"
    public let timestamp: Date
    public let toolName: String?
    public let finishReason: String?
    public let isReasoning: Bool

    public init(role: String, timestamp: Date, toolName: String?,
                finishReason: String?, isReasoning: Bool) {
        self.role = role
        self.timestamp = timestamp
        self.toolName = toolName
        self.finishReason = finishReason
        self.isReasoning = isReasoning
    }
}

/// The 9-state enumeration Hermes actually exhibits. See docs/DESIGN.md.
public enum HermesState: String, CaseIterable {
    case idle, ready, thinking, working, streaming
    case waitingApproval, ok, error, gatewayDown

    public var label: String {
        switch self {
        case .idle:            return "空闲"
        case .ready:           return "准备中"
        case .thinking:        return "思考中"
        case .working:         return "工作中"
        case .streaming:       return "输出中"
        case .waitingApproval: return "待审批"
        case .ok:              return "完成"
        case .error:           return "失败"
        case .gatewayDown:     return "网关断"
        }
    }

    public var emoji: String {
        switch self {
        case .idle:            return "◌"
        case .ready:           return "◉"
        case .thinking:        return "∿"
        case .working:         return "⚙"
        case .streaming:       return "▸"
        case .waitingApproval: return "⏸"
        case .ok:              return "✓"
        case .error:           return "✗"
        case .gatewayDown:     return "⚠"
        }
    }

    /// Skin color key that this state should be tinted with.
    public var colorKey: String {
        switch self {
        case .idle:            return "status_bar_dim"
        case .ready:           return "status_bar_text"
        case .thinking:        return "ui_thinking"
        case .working:         return "ui_tool"
        case .streaming:       return "ui_accent"
        case .waitingApproval: return "status_bar_warn"
        case .ok:              return "status_bar_good"
        case .error:           return "ui_error"
        case .gatewayDown:     return "ui_error"
        }
    }
}
