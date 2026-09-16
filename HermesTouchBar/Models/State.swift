// State.swift
// Models that flow through the app: HermesStatus snapshot + the 9-state enum.

import Foundation

/// A snapshot of what Hermes is doing right now. The StatusReader rebuilds this
/// every 1.5s by querying state.db, jobs.json, and gateway.pid.
struct HermesStatus {
    let now: Date
    let lastAssistantMessageAt: Date?
    let lastUserMessageAt: Date?
    let lastToolCallAt: Date?
    let lastReasoningAt: Date?
    let lastFinishReason: String?
    let activeSessionId: String?
    let activeSessionSource: String?
    let activeSessionModel: String?
    /// Human-readable title of the active session (TUI/CLI sessions carry
    /// one, e.g. "评审Matrix看板widget方案"). The session pill shows this
    /// instead of the bare source when present.
    let activeSessionTitle: String?
    let model: String
    let provider: String
    let contextTokens: Int
    let contextMax: Int
    let recentMessages: [RecentMessage]
    let gatewayUp: Bool
    let cronRecentlyFired: Bool
    let waitingForApproval: Bool
    let lastErrorMessage: Date?

    static let empty = HermesStatus(
        now: Date(), lastAssistantMessageAt: nil, lastUserMessageAt: nil,
        lastToolCallAt: nil, lastReasoningAt: nil, lastFinishReason: nil,
        activeSessionId: nil, activeSessionSource: nil, activeSessionModel: nil,
        activeSessionTitle: nil,
        model: "—", provider: "—", contextTokens: 0, contextMax: 0,
        recentMessages: [], gatewayUp: false, cronRecentlyFired: false,
        waitingForApproval: false, lastErrorMessage: nil
    )
}

struct RecentMessage {
    let role: String          // "user" | "assistant" | "tool"
    let timestamp: Date
    let toolName: String?
    let finishReason: String?
    let isReasoning: Bool
}

/// The 9-state enumeration Hermes actually exhibits. See docs/DESIGN.md.
enum HermesState: String, CaseIterable {
    case idle, ready, thinking, working, streaming
    case waitingApproval, ok, error, gatewayDown

    var label: String {
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

    var emoji: String {
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
    var colorKey: String {
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
