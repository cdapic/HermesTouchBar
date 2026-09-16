// HermesWireActivity.swift
// Derives the activity timestamps the StateMachine needs from the wire's
// `recent_messages` (last 5 messages of the active session, as exposed by
// `SessionDB.get_messages`). Replaces the old filesystem poll's
// `timestamps()` function for the Tier A.2+ path.
//
// Convention: messages arrive in chronological (oldest-first) order from
// `get_messages`. The "last X" timestamps therefore reflect the *most
// recent* occurrence — we overwrite on each match, not on first-match.

import Foundation

struct HermesWireActivityTimestamps {
    let lastAssistantAt: Date?
    let lastUserAt: Date?
    let lastToolAt: Date?
    let lastReasoningAt: Date?
    let lastFinishReason: String?
    let lastErrorAt: Date?

    init(from messages: [HermesWireMessage]) {
        var assistant: Date?
        var user: Date?
        var tool: Date?
        var reasoning: Date?
        var finishReason: String?
        var errorAt: Date?

        for m in messages {
            guard let ts = m.timestamp else { continue }
            let date = Date(timeIntervalSince1970: ts)
            switch m.role {
            case "assistant":
                assistant = date
                if m.isReasoning { reasoning = date }
                if let fr = m.finishReason, !fr.isEmpty {
                    finishReason = fr
                    if fr == "error" { errorAt = date }
                }
            case "tool":
                tool = date
            case "user":
                user = date
            default:
                break
            }
        }

        self.lastAssistantAt  = assistant
        self.lastUserAt       = user
        self.lastToolAt       = tool
        self.lastReasoningAt  = reasoning
        self.lastFinishReason = finishReason
        self.lastErrorAt      = errorAt
    }
}
