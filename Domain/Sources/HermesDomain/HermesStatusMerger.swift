// HermesStatusMerger.swift
// Tier F 收口: the wire+sqlite → HermesStatus assembly logic used to live as
// private methods on AppDelegate, where it could not be unit-tested (NSApplication
// lifecycle) and silently coupled UI to data-shaping. Moved into the Domain
// package as pure functions:
//
//   - resolveDisplaySession: which session the UI shows (pinned wins)
//   - merge: build the snapshot the StateMachine evaluates
//
// `now` is injectable so the cron/error windows are testable.
// The UI shell only calls these; it no longer shapes data.

import Foundation

public enum HermesStatusMerger {

    /// Which session to display: the user's pinned one if it is still in
    /// the wire's session list, otherwise the most recently active.
    /// Deliberately shared by the wire path and the 1.5s timer fallback —
    /// previously the timer path called merge() without a displaySession,
    /// so a pinned session (chosen in the picker) made the two paths pick
    /// different sessions and the model pill flipped between them every
    /// 1.5s (the "model pill flickers after switching model" report).
    public static func resolveDisplaySession(
        _ wire: HermesWireStatus, pinnedSessionId: String?
    ) -> HermesWireSession? {
        if let pin = pinnedSessionId,
           let found = wire.sessions.first(where: { $0.id == pin }) {
            return found
        }
        return wire.sessions.first ?? wire.session
    }

    /// Build the `HermesStatus` the StateMachine sees. The Python feed is
    /// the primary source for every field the StateMachine cares about;
    /// the sqlite snapshot only fills gaps when the wire has died.
    ///
    /// `displaySession` overrides the wire's "most recent" — it's either the
    /// user-pinned session or the top of `wire.sessions`.
    public static func merge(
        wire: HermesWireStatus,
        sqlite: HermesStatus,
        displaySession: HermesWireSession? = nil,
        now: Date = Date()
    ) -> HermesStatus {
        let picked = displaySession ?? wire.session
        let sessionId = picked?.id ?? sqlite.activeSessionId
        let source    = picked?.source ?? sqlite.activeSessionSource
        let model     = picked?.model ?? sqlite.model
        let title     = picked?.title ?? sqlite.activeSessionTitle

        // Derive activity timestamps from the wire's recent messages.
        let derived = HermesWireActivityTimestamps(from: wire.recentMessages)

        // cron: "recently fired" = lastFiredAt within the StateMachine's
        // cronWindow (10s). Wire timestamps are epoch seconds.
        let cronRecently: Bool = {
            guard let last = wire.cron.lastFiredAt else { return false }
            return now.timeIntervalSince1970 - last < 10
        }()

        // lastErrorMessage: from the wire's recent messages (most recent
        // assistant message with finish_reason="error").
        let lastError: Date? = derived.lastErrorAt

        return HermesStatus(
            now:                    now,
            lastAssistantMessageAt: derived.lastAssistantAt ?? sqlite.lastAssistantMessageAt,
            lastUserMessageAt:      derived.lastUserAt      ?? sqlite.lastUserMessageAt,
            lastToolCallAt:         derived.lastToolAt      ?? sqlite.lastToolCallAt,
            lastReasoningAt:        derived.lastReasoningAt ?? sqlite.lastReasoningAt,
            lastFinishReason:       derived.lastFinishReason ?? sqlite.lastFinishReason,
            // Tier A.3 — Hermes-authoritative state. Python derives a state
            // for EVERY active session; we use the DISPLAY session's own
            // state (pinned or most-recent) so the state pill follows what
            // the user is looking at. Falls back to the legacy top-session
            // wire.state when the display session has none. When absent the
            // StateMachine uses its own time-window heuristics.
            authoritativeState:     (displaySession?.state ?? wire.state)?.toHermesState(),
            activeSessionId:        sessionId,
            activeSessionSource:    source,
            activeSessionModel:     model,
            activeSessionTitle:     title,
            model:                  model,
            provider:               sqlite.provider,
            contextTokens:          wire.contextTokens ?? sqlite.contextTokens,
            contextMax:             wire.contextMax ?? sqlite.contextMax,
            recentMessages:         [],
            gatewayUp:              wire.gateway.running,
            cronRecentlyFired:      cronRecently || sqlite.cronRecentlyFired,
            waitingForApproval:     wire.approval.pending || sqlite.waitingForApproval,
            lastErrorMessage:       lastError ?? sqlite.lastErrorMessage
        )
    }
}
