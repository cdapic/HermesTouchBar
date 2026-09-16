// TouchBarController.swift
// Assembles the 4 items of the NSTouchBar and installs it as a
// *system-modal* Touch Bar via PersistentTouchBarAPI. That is what makes the
// bar visible across every foreground app on macOS 13–15 — public NSTouchBar
// only renders while the owning app has key focus.
//
// Touch Bar items:
//   1. State icon + state text (single bordered pill)
//   2. Context %
//   3. Model name
//   4. Session — NSButtonTouchBarItem that drills into a second
//      NSTouchBar (Apple's NSTouchBarCatalog "Color Picker" navigation
//      pattern) listing every active session. Tap to switch bars
//      in-Touch Bar (not at the cursor). Pick a session → pin it.
//
// Each item has a 1pt skin-colored border + 3pt corner radius. The
// state pill uses a custom CenteredTextView because NSTextField
// can't vertically center text on macOS (NSCell.verticalAlignment is
// not exposed in Swift).

import AppKit

@MainActor
final class TouchBarController: NSObject, NSTouchBarDelegate {

    static let trayItemIdentifier = NSTouchBarItem.Identifier("local.hermes.touchbar.tray")

    private let idState       = NSTouchBarItem.Identifier("hermes.state")
    private let idContext     = NSTouchBarItem.Identifier("hermes.ctx.progress")
    private let idModel       = NSTouchBarItem.Identifier("hermes.model")
    private let idSession     = NSTouchBarItem.Identifier("hermes.session")

    // Session picker drilldown — the canonical Apple Touch Bar
    // navigation pattern: tap a button on the main bar → re-present
    // the system-modal Touch Bar with a *different* NSTouchBar
    // (the picker bar). The picker bar has a back button + one
    // button per active session. See NSTouchBarCatalog "Color" sample.
    private let idPickerBack     = NSTouchBarItem.Identifier("hermes.picker.back")
    private let pickerSessionPrefix = "hermes.picker.session."
    private let pickerMaxItems = 8
    private func pickerSessionID(_ sessionID: String) -> NSTouchBarItem.Identifier {
        NSTouchBarItem.Identifier("\(pickerSessionPrefix)\(sessionID)")
    }

    private let skinProvider: SkinProvider
    private var lastState: HermesState = .idle
    private var lastSnapshot: HermesStatus = .empty

    /// Approval attention blink: while the StateMachine reports
    /// `.waitingApproval`, the state-pill TEXT ("⏸ 待审批") itself pulses
    /// once per second — a 4-step triangle wave (α 1.0 → 0.25 → 1.0) for
    /// the gradient feel. The blink owns `stateField.textColor`;
    /// `update()` skips retinting the state text while active. Pill
    /// borders stay on the normal accent tint (user: 闪烁是"待审批"
    /// 文字本身闪烁，并非所有 pill 边框闪烁).
    private var approvalBlinkTimer: Timer?
    private var blinkPhase = 0
    private let blinkAlphas: [CGFloat] = [1.0, 0.55, 0.25, 0.55]

    // Navigation state. We don't keep persistent NSTouchBar instances
    // — we recreate on every present() call so the system can never
    // show a stale bar (which is what was happening before: the user
    // tapped "X" and got the picker bar back because the cached instance
    // was reused). Apple's NSTouchBarCatalog "Color" sample creates a
    // fresh NSTouchBar for each navigation; we do the same.
    private var mainBar: NSTouchBar?
    private var pickerBar: NSTouchBar?

    /// Bar most recently handed to PersistentTouchBarAPI.present(...).
    /// Used by `swapBar(to:)` to dismiss the previous bar before showing
    /// a new one — without this the system holds onto the last-presented
    /// bar per tray identifier and "X" + re-present yields the wrong bar.
    private var lastPresentedBar: NSTouchBar?

    // Cached item references
    private var stateItem: NSCustomTouchBarItem?
    private var ctxItem: NSCustomTouchBarItem?
    private var modelItem: NSCustomTouchBarItem?

    /// Cached inner text fields (children of the bordered containers).
    /// `applyBorder` walks these to retint the parent layer on every update.
    private var stateField: CenteredTextView?
    private var ctxField: CenteredTextView?
    private var modelField: CenteredTextView?

    /// Session pill — an `NSButtonTouchBarItem`. It must be a native
    /// button item (not a custom NSView) because the system-modal Touch
    /// Bar only delivers taps through AppKit's control event path:
    /// NSClickGestureRecognizer and NSView.mouseDown overrides on
    /// NSCustomTouchBarItem views are silently dropped on macOS 15
    /// (see memory/pending-bugs.md "Bug A" for the failed attempts).
    /// The border is drawn via the button's layer.borderColor because
    /// NSButtonTouchBarItem.bezelColor updates don't reliably repaint.
    private var sessionButtonItem: NSButtonTouchBarItem?

    /// Set by AppDelegate. Called when the user taps the [S:xxx] pill
    /// on the main Touch Bar. AppDelegate should call
    /// `presentSessionPicker()` in response.
    var onSessionTap: (() -> Void)?

    /// Set by AppDelegate. Called when the user taps a session in the
    /// picker drilldown. Argument is the picked session id (or nil to
    /// mean "auto / most recent"). After the closure returns, AppDelegate
    /// should call `presentMain()` to swap back to the main bar.
    var onSessionPick: ((String?) -> Void)?

    /// Set by AppDelegate. Called when the user taps "< 返回" in the
    /// picker drilldown. AppDelegate should call `presentMain()` to swap
    /// back to the main bar.
    var onBackToMain: (() -> Void)?

    /// Sessions shown in the picker drilldown. Refreshed by
    /// `updatePopoverSessions(_:)` on every wire frame.
    private var popoverSessions: [HermesWireSession] = []

    // Tray icon view — a small badge that shows up in the Touch Bar control
    // strip so the user can click to re-present the modal if it auto-hides.
    private let trayBadge = TrayBadgeView()

    init(skinProvider: SkinProvider) {
        self.skinProvider = skinProvider
        super.init()
        trayBadge.onTap = { [weak self] in self?.presentMain() }
    }

    /// HERMES_TB_DEBUG=1 → write install/present/factory trace + the
    /// CenteredTextView layout math to stderr (unbuffered), so a "bar not
    /// showing" or "text not centered" report can be diagnosed from real
    /// logs instead of eyeballing the physical bar.
    private static let debugLogging =
        ProcessInfo.processInfo.environment["HERMES_TB_DEBUG"] != nil
    private func dbg(_ message: String) {
        guard Self.debugLogging else { return }
        let stamp = String(format: "%.1f", Date().timeIntervalSince1970)
        FileHandle.standardError.write(Data("[TouchBar \(stamp)] \(message)\n".utf8))
    }

    /// Debug hook: simulate the user tapping the modal's close box (X).
    /// The real X makes the system dismiss the modal; we call the same
    /// private dismiss path. The tray item stays (matching reality), and
    /// our `lastPresentedBar` stays stale (we get no dismissal callback).
    func debugSimulateXClose() {
        guard let bar = lastPresentedBar else {
            dbg("xclose: no lastPresentedBar")
            return
        }
        let ok = PersistentTouchBarAPI.dismiss(touchBar: bar)
        dbg("xclose: dismiss(\(bar === pickerBar ? "picker" : "main")) ok=\(ok)")
    }

    // MARK: - Lifecycle
    func install() {
        dbg("install() tray=\(PersistentTouchBarAPI.installTrayIcon(view: trayBadge, identifier: Self.trayItemIdentifier))")
        presentMain()
    }

    /// Tear down the modal + tray item. We dismiss the last-presented bar
    /// explicitly so the system fully forgets the old modal state — without
    /// this, a subsequent `install()` can leave the previous modal in a
    /// stale state (the "remount sometimes fails" symptom).
    func uninstall() {
        if let bar = lastPresentedBar {
            PersistentTouchBarAPI.dismiss(touchBar: bar)
        }
        PersistentTouchBarAPI.remove(identifier: Self.trayItemIdentifier)
        lastPresentedBar = nil
    }

    // MARK: - Bar navigation

    /// Present (or re-present) the main 4-item Touch Bar. We always
    /// rebuild the bar — Apple's NSTouchBarCatalog "Color" sample
    /// creates a fresh NSTouchBar per navigation, and re-using a
    /// cached instance caused the system to show stale state (the
    /// "X returns to picker" bug).
    func presentMain() {
        let bar = makeMainBar()
        mainBar = bar
        swapBar(to: bar)
    }

    /// Swap to the session picker drilldown bar. Always rebuild so the
    /// latest wire's session list is current.
    func presentSessionPicker() {
        let bar = makePickerBar()
        let sessions = popoverSessions
        var ids: [NSTouchBarItem.Identifier] = [idPickerBack]
        for s in sessions.prefix(pickerMaxItems) {
            if let sid = s.id {
                ids.append(pickerSessionID(sid))
            }
        }
        bar.defaultItemIdentifiers = ids
        pickerBar = bar
        swapBar(to: bar)
    }

    /// Dismiss whatever bar was last shown, then present the new one.
    /// The explicit dismiss is what fixes the "X returns to picker" bug:
    /// the system otherwise remembers the last-presented bar per tray
    /// identifier, and a fresh NSTouchBar instance doesn't clear that
    /// memory on its own.
    private func swapBar(to bar: NSTouchBar) {
        if let prev = lastPresentedBar, prev !== bar {
            PersistentTouchBarAPI.dismiss(touchBar: prev)
        }
        let ok = PersistentTouchBarAPI.present(touchBar: bar,
                                               identifier: Self.trayItemIdentifier)
        dbg("present(\(bar === pickerBar ? "picker" : "main")) ok=\(ok)")
        lastPresentedBar = bar
    }

    // MARK: - Public repaint API
    func update(state: HermesState, snapshot: HermesStatus) {
        lastState = state
        lastSnapshot = snapshot
        let skin = skinProvider.current
        let tint = skin.color(state.colorKey)
        let borderColor = skin.color("ui_accent")

        if let field = stateField {
            field.text = "\(state.emoji) \(state.label)"
            // The approval blink owns the text color while pending, so the
            // "待审批" label itself pulses instead of the pill borders.
            if state != .waitingApproval {
                field.textColor = tint
            }
        }
        if let field = modelField {
            field.text = "M: \(snapshot.model)"
            field.textColor = skin.color("status_bar_strong")
        }
        if let field = ctxField {
            let max = max(snapshot.contextMax, 1)
            let pct = Int((Double(min(snapshot.contextTokens, max)) / Double(max)) * 100)
            field.text = "\(pct)% ctx"
            field.textColor = (pct > 85)
                ? skin.color("ui_warn")
                : skin.color("status_bar_dim")
        }
        // Session button shows the active session — prefer its title
        // (TUI/CLI sessions carry one, e.g. "S: 介绍自己"); fall back to
        // the source name, then the short id.
        if let item = sessionButtonItem {
            let surface: String
            if let title = snapshot.activeSessionTitle, !title.isEmpty {
                surface = title.count > 16 ? String(title.prefix(16)) + "…" : title
            } else if snapshot.activeSessionSource?.isEmpty == false {
                surface = snapshot.activeSessionSource!
            } else {
                surface = shortSessionId(snapshot.activeSessionId)
            }
            item.title = "S: \(surface)"
            // Debug: 4-pill width audit — the 3 custom containers vs the
            // session button, post-layout, so "widths differ" can be checked
            // against real numbers (see memory/pending-bugs.md 新问题 1).
            dbg("pillWidths state=\(stateItem?.view.frame.width ?? -1) ctx=\(ctxItem?.view.frame.width ?? -1) model=\(modelItem?.view.frame.width ?? -1) session=\(item.view?.frame.width ?? -1)")
        }

        // Border retint stays normal in every state — the approval blink
        // pulses the state-pill TEXT, not the borders.
        if state == .waitingApproval {
            startApprovalBlink()
        } else {
            stopApprovalBlink()
        }
        applyBorder(color: borderColor)
        trayBadge.tint = tint
        trayBadge.glyph = state.emoji
    }

    // MARK: - Approval attention blink

    private func startApprovalBlink() {
        guard approvalBlinkTimer == nil else { return }
        blinkPhase = 0
        dbg("[blink] start (waitingApproval)")
        approvalBlinkTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.approvalBlinkTick()
        }
        approvalBlinkTimer?.tolerance = 0.05
        // First step immediately so the pulse is visible without waiting
        // a quarter second after the approval appears.
        approvalBlinkTick()
    }

    private func stopApprovalBlink() {
        guard approvalBlinkTimer != nil else { return }
        dbg("[blink] stop")
        approvalBlinkTimer?.invalidate()
        approvalBlinkTimer = nil
        // Restore full-brightness state text (update() will keep it in
        // sync on the next repaint anyway).
        if let field = stateField {
            field.textColor = skinProvider.current.color("status_bar_warn")
        }
    }

    /// One step of the 1s triangle wave: α 1.0 → 0.55 → 0.25 → 0.55 → …
    /// Four 0.25s steps per second = one full bright→dim→bright cycle per
    /// second (用户: 渐变、每秒闪烁一次).
    private func approvalBlinkTick() {
        blinkPhase = (blinkPhase + 1) % blinkAlphas.count
        let warn = skinProvider.current.color("status_bar_warn")
        stateField?.textColor = warn.withAlphaComponent(blinkAlphas[blinkPhase])
    }

    /// Rebuild the session picker drilldown's data set. Called from
    /// AppDelegate every wire frame so opening the picker always shows
    /// fresh sessions (and the user can pick a brand-new one).
    func updatePopoverSessions(_ sessions: [HermesWireSession]) {
        popoverSessions = Array(sessions.prefix(pickerMaxItems))
    }

    /// Retint all 4 main-bar container borders with the current skin's accent.
    /// Picker items are recreated on every presentSessionPicker() with the
    /// current skin color baked in, so they don't need retinting here.
    private func applyBorder(color: NSColor) {
        for item in [stateItem, ctxItem, modelItem] {
            guard let view = item?.view else { continue }
            view.layer?.borderColor = color.cgColor
        }
        sessionButtonItem?.view?.layer?.borderColor = color.cgColor
    }

    func reload() {
        update(state: lastState, snapshot: lastSnapshot)
        // Re-present so the color changes are picked up.
        presentMain()
    }

    // MARK: - NSTouchBarDelegate
    private func makeMainBar() -> NSTouchBar {
        let tb = NSTouchBar()
        tb.delegate = self
        tb.defaultItemIdentifiers = [
            idState, idContext, idModel, idSession
        ]
        return tb
    }

    private func makePickerBar() -> NSTouchBar {
        let tb = NSTouchBar()
        tb.delegate = self
        // defaultItemIdentifiers is set in presentSessionPicker() each time
        // so the bar always reflects the latest sessions.
        return tb
    }

    nonisolated func touchBar(_ touchBar: NSTouchBar,
                              makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        MainActor.assumeIsolated {
            // Picker-bar items take precedence (different bar, same delegate).
            if touchBar === pickerBar {
                if identifier == idPickerBack { return makePickerBack() }
                if identifier.rawValue.hasPrefix(pickerSessionPrefix) {
                    let sid = String(identifier.rawValue.dropFirst(pickerSessionPrefix.count))
                    return makePickerSessionButton(sessionID: sid)
                }
                return nil
            }
            // Main bar.
            switch identifier {
            case idState:       return makeState()
            case idContext:     return makeContext()
            case idModel:       return makeModel()
            case idSession:     return makeSession()
            default: return nil
            }
        }
    }

    // MARK: - Picker factories
    //
    // All interactive items (main-bar session pill + picker back/session
    // buttons) are NSButtonTouchBarItem — the only configuration proven to
    // receive taps in a system-modal Touch Bar on macOS 15. Custom views
    // (NSCustomTouchBarItem + NSView with mouseDown/gesture) render fine
    // but silently drop taps. The bezel is themed through
    // `styleButtonItem(_:)` (bezelColor at creation + layer border for
    // reliable retinting).

    private func makePickerBack() -> NSTouchBarItem {
        let item = NSButtonTouchBarItem(
            identifier: idPickerBack,
            title: "< 返回",
            target: self,
            action: #selector(pickerBackTapped)
        )
        styleButtonItem(item)
        return item
    }

    private func makePickerSessionButton(sessionID: String) -> NSTouchBarItem? {
        guard let session = popoverSessions.first(where: { $0.id == sessionID }) else {
            return nil
        }
        let item = NSButtonTouchBarItem(
            identifier: pickerSessionID(sessionID),
            title: popoverTitle(session),
            target: self,
            action: #selector(pickerSessionTapped(_:))
        )
        styleButtonItem(item)
        return item
    }

    /// Give an NSButtonTouchBarItem the same "1pt accent border, 3pt
    /// radius" look as the read-only pills: transparent bezel (so the
    /// button doesn't render as a filled capsule) + a layer border that
    /// `applyBorder` can retint reliably. bezelColor updates on a live
    /// item do not repaint on macOS 15, so the layer is the source of
    /// truth for the border color.
    private func styleButtonItem(_ item: NSButtonTouchBarItem) {
        let accent = skinProvider.current.color("ui_accent")
        item.bezelColor = .clear
        if let button = item.view as? NSButton {
            button.wantsLayer = true
            button.layer?.borderWidth = 1
            button.layer?.cornerRadius = 3
            button.layer?.borderColor = accent.cgColor
        }
    }

    // MARK: - Button actions (NSButtonTouchBarItem targets)

    @objc private func sessionTapped() {
        onSessionTap?()
    }

    @objc private func pickerBackTapped() {
        onBackToMain?()
    }

    @objc private func pickerSessionTapped(_ sender: NSButtonTouchBarItem) {
        let raw = sender.identifier.rawValue
        guard raw.hasPrefix(pickerSessionPrefix) else { return }
        let sessionID = String(raw.dropFirst(pickerSessionPrefix.count))
        onSessionPick?(sessionID)
    }

    private func popoverTitle(_ s: HermesWireSession) -> String {
        let age = s.lastActive.map { " · \(secondsAgo($0))" } ?? ""
        // TUI/CLI sessions carry a human-readable title; prefer it over the
        // bare "source (id)" fallback. Keep the button short enough to fit.
        if let title = s.title, !title.isEmpty {
            let clipped = title.count > 18
                ? String(title.prefix(18)) + "…"
                : title
            return "\(clipped)\(age)"
        }
        let surface = s.source ?? "?"
        let idSuffix = s.id.map { String($0.suffix(6)) } ?? "—"
        return "\(surface) (\(idSuffix))\(age)"
    }

    private func secondsAgo(_ epoch: TimeInterval) -> String {
        let s = Date().timeIntervalSince1970 - epoch
        if s < 60    { return "刚刚" }
        if s < 3600  { return "\(Int(s/60))m" }
        if s < 86400 { return "\(Int(s/3600))h" }
        return "\(Int(s/86400))d"
    }

    // MARK: - Item factories
    //
    // Each factory builds a `BorderedContainer` (NSView) that fills the full
    // Touch Bar height with a 1pt skin-colored border, and places a small
    // CenteredTextView inside. We use CenteredTextView instead of
    // NSTextField because NSCell.verticalAlignment is not exposed in
    // Swift and NSTextField draws text at the top of its bounds.

    private static let itemHeight: CGFloat = 30

    /// 目标等宽值（pt）——见 `makeSession` 注释。基线日志（HERMES_TB_DEBUG=1）
    /// 测得系统把 3 个自定义 item 拉伸到 175pt、session 按标题自适应 ≈70pt，
    /// 则 bar 有效宽 W ≈ 3×175+70 = 595，session 固定 W/4 ≈ 149 即可 4 个等宽。
    /// 首次构建后用日志反推精确值（见 memory/pending-bugs.md 新问题 1）。
    private static let sessionPillWidth: CGFloat = 149

    /// Combined `[icon state-text]` item. Replaces the old separate
    /// `idStateIcon` + `idStateText` pair so the visual reads as a single
    /// pill (and we don't get a redundant double border between them).
    private func makeState() -> NSTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: idState)
        let container = NSView(frame: NSRect(
            x: 0, y: 0, width: 80, height: Self.itemHeight
        ))
        container.wantsLayer = true
        container.layer?.borderWidth = 1
        container.layer?.cornerRadius = 3
        container.layer?.borderColor = NSColor.systemBlue.cgColor

        // One centered field for "emoji + label". Keeps the pill visually
        // balanced with ctx/model/session, all of which center their text.
        // Loses the old separate-icon-at-15pt-semibold look — the emoji
        // is still distinct at 13pt medium because it's an emoji glyph.
        let field = CenteredTextView(frame: NSRect(
            x: 0, y: 0, width: 80, height: Self.itemHeight
        ))
        field.autoresizingMask = [.width, .height]
        field.text = "\(lastState.emoji) \(lastState.label)"
        field.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        field.alignment = .center
        container.addSubview(field)

        item.view = container
        stateItem = item
        stateField = field
        return item
    }

    private func makeContext() -> NSTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: idContext)
        // 64pt fills "100% ctx" comfortably; center the text to match
        // state/model/session.
        let container = NSView(frame: NSRect(
            x: 0, y: 0, width: 64, height: Self.itemHeight
        ))
        container.wantsLayer = true
        container.layer?.borderWidth = 1
        container.layer?.cornerRadius = 3
        container.layer?.borderColor = NSColor.systemBlue.cgColor

        let field = CenteredTextView(frame: NSRect(
            x: 0, y: 0, width: 64, height: Self.itemHeight
        ))
        field.autoresizingMask = [.width, .height]
        field.text = "—"
        field.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        field.alignment = .center
        container.addSubview(field)

        item.view = container
        ctxItem = item
        ctxField = field
        return item
    }

    private func makeModel() -> NSTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: idModel)
        // 115pt fits "M: MiniMax-M3" (~98pt); center the text.
        let container = NSView(frame: NSRect(
            x: 0, y: 0, width: 115, height: Self.itemHeight
        ))
        container.wantsLayer = true
        container.layer?.borderWidth = 1
        container.layer?.cornerRadius = 3
        container.layer?.borderColor = NSColor.systemBlue.cgColor

        let field = CenteredTextView(frame: NSRect(
            x: 0, y: 0, width: 115, height: Self.itemHeight
        ))
        field.autoresizingMask = [.width, .height]
        field.text = "M: —"
        field.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        field.alignment = .center
        container.addSubview(field)

        item.view = container
        modelItem = item
        modelField = field
        return item
    }

    /// Session pill — shows the current surface (feishu/tui/cli/...) and
    /// acts as a tap target that drills into the session-picker Touch Bar.
    /// Must be an NSButtonTouchBarItem for the tap to register (custom
    /// NSView-based taps are dropped by the system-modal bar — see the
    /// class comment on `sessionButtonItem`). Title auto-sizes; the accent
    /// border is applied by `styleButtonItem`.
    private func makeSession() -> NSTouchBarItem {
        let item = NSButtonTouchBarItem(
            identifier: idSession,
            title: "S: —",
            target: self,
            action: #selector(sessionTapped)
        )
        styleButtonItem(item)
        // Pill 等宽：系统模态布局把 3 个自定义 item（state/ctx/model）拉伸到
        // ~175pt（均分剩余宽度），而 NSButtonTouchBarItem 按标题自适应
        // （"S: feishu" ≈ 70pt）→ session pill 明显窄。这里把按钮宽度钳到
        // 目标值：widthAnchor(>=) + frame 双保险，让 4 个 pill 视觉等宽。
        // 注：不能放进共享的 styleButtonItem——picker 的返回/会话按钮
        // 标题长短不一，固定宽度会破坏 picker 布局。
        if let button = item.view as? NSButton {
            button.autoresizingMask = [.width, .height]
            let w = button.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.sessionPillWidth)
            w.priority = .defaultHigh
            w.isActive = true
            button.frame.size.width = Self.sessionPillWidth
        }
        sessionButtonItem = item   // update() re-titles, applyBorder() retints
        dbg("makeSession: \(item.view.map { String(describing: type(of: $0)) } ?? "nil") bezel=\(item.bezelColor?.description ?? "nil")")
        return item
    }

    private func shortSessionId(_ id: String?) -> String {
        guard let id, id.count >= 6 else { return "—" }
        return String(id.suffix(6))
    }
}

// MARK: - Tray badge view
// A small ~30×30 view shown in the Touch Bar control strip. It carries the
// current state glyph (single emoji) tinted with the active skin's state
// color. Tapping it re-presents the modal Touch Bar if the system hid it.
@MainActor
final class TrayBadgeView: NSView {
    var onTap: (() -> Void)?
    var glyph: String = "⚕" { didSet { needsDisplay = true } }
    var tint: NSColor = .systemBlue { didSet { needsDisplay = true } }

    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { self }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .bold),
            .foregroundColor: tint
        ]
        let s = NSAttributedString(string: glyph, attributes: attrs)
        let size = s.size()
        let origin = NSPoint(x: (bounds.width - size.width) / 2,
                             y: (bounds.height - size.height) / 2)
        s.draw(at: origin)
    }

    override func mouseDown(with event: NSEvent) {
        onTap?()
    }
}

// MARK: - CenteredTextView
// NSTextField can't vertically center text on macOS — NSCell.verticalAlignment
// is not exposed in Swift. This is a minimal NSView subclass that draws a
// single line of text manually, vertically centered in its bounds. Used by
// the read-only Touch Bar items where vertical centering matters for the
// "everything is one pill" look.
@MainActor
final class CenteredTextView: NSView {
    var text: String = "" { didSet { needsDisplay = true } }
    var textColor: NSColor = .labelColor { didSet { needsDisplay = true } }
    var font: NSFont = .monospacedSystemFont(ofSize: 11, weight: .regular) {
        didSet { needsDisplay = true }
    }
    var alignment: NSTextAlignment = .left { didSet { needsDisplay = true } }

    override var acceptsFirstResponder: Bool { false }
    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    /// Set HERMES_TB_DEBUG=1 to print the layout math of the first few
    /// draws to stderr (bounds / measured size / computed offsets), so a
    /// "text not centered" report can be verified against real numbers
    /// instead of eyeballing a 30pt-tall pill.
    private static let debugLogging =
        ProcessInfo.processInfo.environment["HERMES_TB_DEBUG"] != nil
    private static var drawLogCount = 0

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !text.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        let attr = NSAttributedString(string: text, attributes: attrs)
        let size = attr.size()
        let w = bounds.width
        let yOffset = (bounds.height - size.height) / 2
        let xOffset: CGFloat
        switch alignment {
        case .center: xOffset = (w - size.width) / 2
        case .right:  xOffset = w - size.width
        default:      xOffset = 0
        }
        if Self.debugLogging && Self.drawLogCount < 300 {
            Self.drawLogCount += 1
            let msg = "[CenteredTextView] \"\(text)\" bounds=\(NSStringFromRect(bounds)) "
                + "alignment=\(alignment.rawValue) size=\(String(format: "%.1f", size.width))x"
                + "\(String(format: "%.1f", size.height)) xOffset=\(String(format: "%.1f", xOffset))\n"
            FileHandle.standardError.write(Data(msg.utf8))  // stderr: unbuffered
        }
        attr.draw(at: NSPoint(x: xOffset, y: yOffset))
    }
}
