// HermesStatusSource.swift
// Tier F 收口: the contract the UI shell needs from a status provider. The
// concrete implementations (StatusReader for sqlite, a future mock for UI
// tests) live in the app shell; the Domain package only defines the shape,
// so AppDelegate can be handed any source without coupling to SQLite.

import Foundation

/// Something that can produce a fresh HermesStatus snapshot on demand.
/// The backup refresh path in AppDelegate calls this on a background queue;
/// implementations must be thread-safe and degrade to `.empty` rather than
/// throw (the Touch Bar must never go dark because one query failed).
public protocol HermesStatusSource {
    func refresh() -> HermesStatus
}
