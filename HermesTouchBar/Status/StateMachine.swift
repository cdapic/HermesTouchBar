// StateMachine.swift
// Pure function: HermesStatus -> HermesState. No I/O, easy to unit-test.

import Foundation

final class StateMachine {

    private(set) var current: HermesState = .idle

    /// Thresholds tuned for 1.5s polling cadence.
    private let workingWindow: TimeInterval = 5
    private let streamingWindow: TimeInterval = 8
    private let okWindow: TimeInterval = 12
    private let errorWindow: TimeInterval = 30
    private let cronWindow: TimeInterval = 10

    @discardableResult
    func evaluate(snapshot: HermesStatus) -> HermesState {
        // 1. Gateway down always wins
        guard snapshot.gatewayUp else {
            current = .gatewayDown
            return current
        }

        // 2. Approval prompt (highest priority after gateway)
        if snapshot.waitingForApproval {
            current = .waitingApproval
            return current
        }

        let now = snapshot.now

        // 3. Error in the recent past
        // D-3: lastErrorMessage is now a Date? directly (was String? parsed
        // via ISO8601DateFormatter round-trip before Tier D).
        if let lastErr = snapshot.lastErrorMessage,
           now.timeIntervalSince(lastErr) < errorWindow {
            current = .error
            return current
        }

        // 4. Active session: work / think / stream
        if let last = snapshot.lastAssistantMessageAt {
            let age = now.timeIntervalSince(last)
            if age < workingWindow {
                if let toolAt = snapshot.lastToolCallAt,
                   now.timeIntervalSince(toolAt) < workingWindow {
                    current = .working
                    return current
                }
                if let reasonAt = snapshot.lastReasoningAt,
                   now.timeIntervalSince(reasonAt) < workingWindow {
                    current = .thinking
                    return current
                }
                if let finish = snapshot.lastFinishReason, finish.isEmpty {
                    current = .streaming
                    return current
                }
                current = .working
                return current
            }
            if age < streamingWindow, snapshot.lastFinishReason == nil {
                current = .streaming
                return current
            }
            if age < okWindow, snapshot.lastFinishReason == "stop" {
                current = .ok
                return current
            }
        }

        // 5. Cron fired in the last few seconds -> ready
        if snapshot.cronRecentlyFired {
            current = .ready
            return current
        }

        // 6. Default
        current = snapshot.activeSessionId == nil ? .idle : .ready
        return current
    }
}
