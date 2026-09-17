// QuickActions.swift
// Registers four global hotkeys via Carbon's RegisterEventHotKey.
// Falls back to NSAppleScript for the actual action dispatch (no need for
// the host app to be accessibility-trusted for the keypress itself, only
// for the synthesized keystroke used by approve/cancel).

import AppKit
import Carbon.HIToolbox.Events
import HermesDomain

final class QuickActions {

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    private var handlers: [UInt32: () -> Void] = [:]
    private var nextId: UInt32 = 1

    // Carbon's kVK_* are Int, but RegisterEventHotKey takes UInt32.
    private static let keyH = UInt32(kVK_ANSI_H)
    private static let keyN = UInt32(kVK_ANSI_N)
    private static let keyA = UInt32(kVK_ANSI_A)
    private static let keyX = UInt32(kVK_ANSI_X)
    private static let keyS = UInt32(kVK_ANSI_S)
    private static let signature: OSType = OSType(0x4845524D) // "HERM"

    func register() {
        installHandler()
        register(key: Self.keyH, action: openTUI)
        register(key: Self.keyN, action: newSession)
        register(key: Self.keyA, action: approve)
        register(key: Self.keyX, action: cancel)
        register(key: Self.keyS, action: cycleSkin)
    }

    func unregister() {
        for ref in hotKeyRefs { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
        if let h = handlerRef { RemoveEventHandler(h) }
        handlerRef = nil
    }

    func openTUI()    { run("osascript -e 'tell app \"Terminal\" to activate' -e 'tell app \"Terminal\" to do script \"hermes chat\"'") }
    func newSession() { run("osascript -e 'tell app \"Terminal\" to activate' -e 'tell app \"Terminal\" to do script \"hermes chat --new\"'") }

    /// Approve / cancel require explicit confirmation because the underlying
    /// osascript sends `y` or Ctrl-C to whichever app is currently focused.
    /// A stray ⌃⌥⌘A while you're typing in Terminal could irreversibly
    /// confirm a destructive command. The dialog puts a hard wall in front
    /// of the keystroke.
    func approve() { confirmThenRun(
        title: "Approve current Hermes action?",
        message: "Sends \"y\" to the focused app. Hermes is about to run a\nshell_exec, MCP call, or other side-effecting tool.\n\nOnly confirm if you expect this.",
        confirmLabel: "Approve (send y)",
        osascript: "osascript -e 'tell app \"System Events\" to keystroke \"y\"'"
    ) }

    func cancel() { confirmThenRun(
        title: "Cancel current Hermes action?",
        message: "Sends Ctrl-C to the focused app. This will abort\nwhatever Hermes is currently running.\n\nUse it to bail out of a runaway tool call or a misclick.",
        confirmLabel: "Cancel (send Ctrl-C)",
        osascript: "osascript -e 'tell app \"System Events\" to keystroke (ASCII character 3)'"
    ) }

    /// Show an NSAlert, then run the osascript only if the user clicks the
    /// confirm button. Modal at .alert level so it grabs focus even when
    /// the user is mid-keystroke in another app.
    private func confirmThenRun(title: String, message: String, confirmLabel: String, osascript: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: confirmLabel)
            alert.addButton(withTitle: "Don't")
            // Run modally on the key window; return value is the button index
            // the user clicked. 0 = confirm, 1 = cancel.
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                self.run(osascript)
            }
        }
    }

    /// Forwarded by the AppDelegate's "下一皮肤" menu item. The actual cycle
    /// logic lives in SkinProvider; we just signal via Notification so the
    /// delegate (which owns the SkinProvider) can act on it.
    func cycleSkin() {
        NotificationCenter.default.post(name: .hermesTouchBarCycleSkin, object: nil)
    }

    // MARK: - Carbon internals
    private func installHandler() {
        let cb: EventHandlerUPP = { _, eventRef, _ in
            guard let eventRef else { return noErr }
            var hkID = EventHotKeyID()
            let err = withUnsafeMutablePointer(to: &hkID) { hkPtr in
                GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    hkPtr
                )
            }
            // Guard: only dispatch hotkeys registered with OUR signature.
            // Without this, another process's hotkey event with id=1 (which
            // collides with our first registration) would trigger Hermes
            // actions. Tier D-8.
            if err == noErr && hkID.signature == QuickActions.signature {
                let id = hkID.id
                DispatchQueue.main.async {
                    QuickActions.cbHandlers[id]?()
                }
            }
            return noErr
        }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            cb,
            1,
            &spec,
            nil,
            &handlerRef
        )
        // store the cb dispatch map on a static so the C closure can see it
        QuickActions.cbHandlers = handlers
    }

    private func register(key: UInt32, action: @escaping () -> Void) {
        let id = nextId; nextId += 1
        handlers[id] = action
        QuickActions.cbHandlers = handlers
        var ref: EventHotKeyRef?
        let modifiers: UInt32 = UInt32(cmdKey | optionKey | controlKey)
        RegisterEventHotKey(
            key,
            modifiers,
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if let ref { hotKeyRefs.append(ref) }
    }

    private func run(_ shell: String) {
        let p = Process()
        p.launchPath = "/bin/bash"
        p.arguments = ["-lc", shell]
        try? p.run()
    }

    init() {
        QuickActions.sharedRef = self
    }
    deinit {
        if QuickActions.sharedRef === self { QuickActions.sharedRef = nil }
    }

    // Static bridge so the C closure can dispatch by id.
    fileprivate static var cbHandlers: [UInt32: () -> Void] = [:]

    // Shared instance for cross-module calls (TouchBar button targets).
    static var sharedRef: QuickActions?
}

extension Notification.Name {
    /// Posted by QuickActions.cycleSkin() when the user hits ⌃⌥⌘S.
    /// AppDelegate observes it and drives SkinProvider.cycleNext().
    static let hermesTouchBarCycleSkin = Notification.Name("hermesTouchBar.cycleSkin")
}
