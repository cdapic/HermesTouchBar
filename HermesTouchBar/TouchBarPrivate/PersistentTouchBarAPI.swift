// PersistentTouchBarAPI.swift
// Swift wrapper around TouchBarPrivate.m. Lets the rest of the app call
// `PersistentTouchBarAPI.present(touchBar:identifier:)` without touching the
// dlopen/dlsym dance directly.
//
// Same shape as TouchBar-Pet's wrapper; we keep the same names so the
// private API contract is the only thing this layer has to expose.

import AppKit
import TouchBarPrivate

@MainActor
enum PersistentTouchBarAPI {
    /// Install a small icon in the system Touch Bar control strip. Required
    /// before the system will accept a system-modal Touch Bar from a menu-bar
    /// app.
    @discardableResult
    static func installTrayIcon(view: NSView, identifier: NSTouchBarItem.Identifier) -> Bool {
        TBPInstallPersistentTouchBarView(view, identifier.rawValue)
    }

    /// Present a full-width Touch Bar that floats over the system control
    /// strip and stays visible across all foreground apps until dismissed.
    @discardableResult
    static func present(touchBar: NSTouchBar, identifier: NSTouchBarItem.Identifier) -> Bool {
        TBPPresentPersistentTouchBar(touchBar, identifier.rawValue)
    }

    /// Dismiss the system-modal Touch Bar we most recently presented via
    /// `present(touchBar:identifier:)`. Safe to call with any NSTouchBar —
    /// returns false when no dismiss selector is available or when the
    /// given bar isn't currently the modal. Callers should fall through to
    /// `present(...)` regardless of the return value.
    @discardableResult
    static func dismiss(touchBar: NSTouchBar) -> Bool {
        TBPDismissPersistentTouchBar(touchBar)
    }

    /// Remove both the modal Touch Bar and the tray icon.
    @discardableResult
    static func remove(identifier: NSTouchBarItem.Identifier) -> Bool {
        TBPRemovePersistentTouchBar(identifier.rawValue)
    }
}
