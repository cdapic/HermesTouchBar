// AppDelegate.swift
// Boots the menu-bar item, owns the data pipeline (HermesPythonSource +
// StatusReader + StateMachine + SkinProvider), and on every wire frame
// repaints the system-modal Touch Bar via PersistentTouchBarAPI.

import AppKit
import HermesDomain

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Owned subsystems
    private let skinProvider = SkinProvider()
    private let statusReader: any HermesStatusSource = StatusReader()
    private let stateMachine = StateMachine()
    private let wireSource = HermesPythonSource()
    private let touchBarController: TouchBarController
    private var quickActions: QuickActions!

    private var statusItem: NSStatusItem!
    private var refreshTimer: Timer?
    private var wireTask: Task<Void, Never>?

    /// Most recent wire frame. Used by both the wire path and the
    /// backup timer so gateway state is always sourced from the same
    /// place. Without this, the timer would fall back to the old
    /// `StatusReader.checkGateway()` (kill -0 PID) and the two paths
    /// would fight — every 1.5s the Touch Bar would flip between
    /// `.ready` (wire says up) and `.gatewayDown` (sqlite says down).
    private var lastWire: HermesWireStatus?

    /// Tier B — most recent StatusReader snapshot, refreshed on a
    /// background queue ONLY while the wire is stale/dead. The wire path
    /// uses it as the sqlite fallback for fields Python doesn't emit.
    /// Previously StatusReader ran its own 1.5s timer doing SQLite I/O on
    /// the main runloop (could stall Touch Bar repaints).
    private var lastSqliteSnapshot: HermesStatus?

    /// Tier B — user-pinned session. When set, the Touch Bar follows
    /// this session's data instead of "most recently active". Cleared
    /// by the picker when the user picks "show all / most recent".
    private var pinnedSessionId: String?

    override init() {
        self.touchBarController = TouchBarController(skinProvider: skinProvider)
        super.init()
        // Touch Bar drilldown navigation (Apple NSTouchBarCatalog pattern).
        // Main bar session pill → swap to picker bar; picker bar session
        // tap → pin + swap back; picker bar back button → swap back.
        self.touchBarController.onSessionTap = { [weak self] in
            self?.touchBarController.presentSessionPicker()
        }
        self.touchBarController.onSessionPick = { [weak self] (id: String?) in
            self?.pinnedSessionId = id
            if let wire = self?.lastWire {
                self?.handleWire(wire)   // re-render main bar
            }
            self?.touchBarController.presentMain()  // back to main bar
        }
        self.touchBarController.onBackToMain = { [weak self] in
            self?.touchBarController.presentMain()
        }
    }

    // MARK: - NSApplicationDelegate
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1) Menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "⚕"
            button.toolTip = "Hermes TouchBar"
        }
        buildMenu()

        // 2) Global hotkeys
        quickActions = QuickActions()
        quickActions.register()

        // 2b) Cycle-skin notification (driven by ⌃⌥⌘S hotkey from QuickActions)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(nextSkin),
            name: .hermesTouchBarCycleSkin,
            object: nil
        )

        // 3) Skin watching -> repaint when skin changes
        skinProvider.startWatching { [weak self] in
            DispatchQueue.main.async { self?.touchBarController.reload() }
        }

        // 4) Tier A — start the long-running Python source. If it fails
        //    (no Python, no Hermes install, …) we fall through to the
        //    StatusReader-only path. The Swift side never blocks on Python.
        startWireSource()

        // 5) Tier B — StatusReader is a pure function with no own timer;
        //    the backup timer below refreshes it on a background queue only
        //    when the wire is stale/dead. The first timer tick seeds
        //    lastSqliteSnapshot. (Previously StatusReader ran SQLite queries
        //    on the main runloop every 1.5s and could stall repaints.)

        // 6) Install the system-modal Touch Bar.
        touchBarController.install()

        // 7) Push an immediate paint so the bar shows something before the
        //    first wire frame lands (≤0.5s).
        touchBarController.update(state: .idle, snapshot: .empty)

        // 8) Backup refresh loop — fires even if the wire is dead, so the
        //    Touch Bar still updates from StatusReader. When the wire is
        //    alive, this loop is mostly redundant but cheap.
        scheduleTimer()

        // 9) DEBUG-ONLY: HERMES_TB_TEST=xclose-remount auto-runs the
        //    "X-close → re-mount" reproduction + fix-variant matrix so the
        //    failure can be diagnosed from logs (bar renders? present ok?).
        //    Inert unless the env var is set.
        if ProcessInfo.processInfo.environment["HERMES_TB_TEST"] == "xclose-remount" {
            debugRunXCloseRemountTest()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        wireTask?.cancel()
        quickActions.unregister()
        Task { await wireSource.stop() }
        skinProvider.stopWatching()
        touchBarController.uninstall()
    }

    // MARK: - Menu
    private func buildMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "重新挂载 Touch Bar", action: #selector(reinstall), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())

        // Skin picker — submenu of every builtin + every user YAML. The
        // currently active one is marked with a checkmark. Setting a skin
        // here also propagates back to Hermes if the wire's `skin` field
        // diverges (see handleWire's `setActive` call).
        let skinMenu = NSMenu()
        let currentSkin = skinProvider.current.name
        for name in skinProvider.available {
            let item = NSMenuItem(
                title: name,
                action: #selector(setSkin(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = name
            item.state = (name == currentSkin) ? .on : .off
            skinMenu.addItem(item)
        }
        let skinHeader = NSMenuItem(title: "选择皮肤", action: nil, keyEquivalent: "")
        skinHeader.submenu = skinMenu
        menu.addItem(skinHeader)

        menu.addItem(NSMenuItem.separator())
        let state = stateMachine.current
        menu.addItem(withTitle: "状态：\(state.label) (\(state.rawValue))", action: nil, keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q")
        statusItem.menu = menu
    }

    /// "重新挂载 Touch Bar" — rebuild + re-present the main bar.
    /// Deliberately does NOT uninstall() (no tray remove/re-add): the
    /// synchronous tray churn + present in one runloop tick races with the
    /// DFR service and silently drops the present (reproduced 1/6 in the
    /// X-close matrix). Presenting again is the same reliable path as the
    /// tray-badge tap; `swapBar`'s dismiss-before-present still resets a
    /// stale modal. See memory/pending-bugs.md "Bug D".
    @objc private func reinstall() {
        touchBarController.presentMain()
        let snapshot = currentMergedSnapshot()
        let state = stateMachine.evaluate(snapshot: snapshot)
        touchBarController.update(state: state, snapshot: snapshot)
    }

    // MARK: - DEBUG: X-close → re-mount reproduction matrix
    // HERMES_TB_TEST=xclose-remount: reproduces "tap X, then 重新挂载
    // Touch Bar does nothing" and verifies the fix, logging present()
    // results + whether the bar re-renders (CenteredTextView draw logs
    // under HERMES_TB_DEBUG=1). Inert unless the env var is set.
    private func debugRunXCloseRemountTest() {
        let dbg: (String) -> Void = { msg in
            FileHandle.standardError.write(Data("[TEST \(String(format: "%.1f", Date().timeIntervalSince1970))] \(msg)\n".utf8))
        }
        let at: (TimeInterval, String, @escaping () -> Void) -> Void = { delay, label, block in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                dbg("--- \(label) ---")
                block()
            }
        }

        // 4 cycles of: X-close → reinstall() (the fixed remount path).
        for i in 0..<4 {
            let base = TimeInterval(i * 9)
            at(3 + base, "C\(i): simulate X") {
                self.touchBarController.debugSimulateXClose()
            }
            at(5 + base, "C\(i): reinstall() (fixed: presentMain only)") {
                self.reinstall()
            }
        }
        at(42, "done — leave app running for visual check") {}
    }

    @objc private func setSkin(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        skinProvider.setActive(name)
        touchBarController.reload()
        // Re-build the menu so the checkmark follows the new active skin.
        buildMenu()
    }

    /// ⌃⌥⌘S hotkey from QuickActions. The menu is now a picker, but
    /// keeping the cycle hotkey is cheap and gives power users a one-key
    /// toggle without going through the menu.
    @objc private func nextSkin() {
        skinProvider.cycleNext()
        touchBarController.reload()
        buildMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Wire source plumbing (Tier A)

    private func startWireSource() {
        wireTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.wireSource.start()
            } catch {
                // HermesPythonSource.start() failed (python not found,
                // script missing, etc.). The StatusReader + 1.5s timer
                // still drive the UI; we just lose real-time gateway +
                // session accuracy. Log to stderr for diagnosis.
                let msg = "wireSource start failed: \(error) — falling back to StatusReader\n"
                FileHandle.standardError.write(msg.data(using: .utf8) ?? Data())
                return
            }
            // Subscribe to the JSON-lines stream. Each frame triggers a
            // state-machine eval + repaint.
            for await wire in await self.wireSource.stream {
                await self.handleWire(wire)
            }
        }
    }

    private func handleWire(_ wire: HermesWireStatus) {
        lastWire = wire
        // Tier B: pick which session to display (pinned wins; else most
        // recent). Shared with the timer path so both always agree.
        let displaySession = HermesStatusMerger.resolveDisplaySession(
            wire, pinnedSessionId: pinnedSessionId)
        let merged = HermesStatusMerger.merge(
            wire: wire, sqlite: lastSqliteSnapshot ?? .empty,
            displaySession: displaySession)
        let state = stateMachine.evaluate(snapshot: merged)
        touchBarController.update(state: state, snapshot: merged)
        // Refresh the session popover's item list (sessions can come and go).
        touchBarController.updatePopoverSessions(wire.sessions)
        refreshMenuStateLabel(state: state)
        debugModelTrace("wire", merged)

        // Skin sync: if Python reports a different active skin than we
        // have locally, adopt it. Lets `hermes skin use X` propagate
        // without the user pressing ⌃⌥⌘S.
        if let remoteSkin = wire.skin, remoteSkin != skinProvider.current.name {
            skinProvider.setActive(remoteSkin)
            touchBarController.reload()
        }
    }

    /// HERMES_TB_DEBUG=1 — print which session/model each update path fed
    /// the UI, so "model pill flickers" can be traced to wire-vs-timer
    /// disagreement (or a genuinely changing source) from real logs.
    private func debugModelTrace(_ path: String, _ snapshot: HermesStatus) {
        guard ProcessInfo.processInfo.environment["HERMES_TB_DEBUG"] != nil else { return }
        let msg = "[modelTrace \(path)] session=\(snapshot.activeSessionId ?? "nil") "
            + "source=\(snapshot.activeSessionSource ?? "nil") "
            + "title=\(snapshot.activeSessionTitle ?? "nil") "
            + "model=\(snapshot.model) "
            + "ctx=\(snapshot.contextTokens)/\(snapshot.contextMax) "
            + "state=\(stateMachine.current.rawValue)\n"
        FileHandle.standardError.write(Data(msg.utf8))
    }

    // MARK: - Session picker (Tier B)
    //
    // The drilldown is handled by TouchBarController via NSTouchBar
    // re-presentation (Apple's NSTouchBarCatalog "Color Picker" pattern):
    //   main bar [S:xxx] tap → swap to picker bar
    //   picker bar session tap → pin + swap back to main
    //   picker bar < 返回 tap → swap back to main
    // No NSMenu / NSPopoverTouchBarItem involved — it's all Touch Bar.

    /// Build the `HermesStatus` the StateMachine sees. Tier F 收口: the
    /// shaping logic moved to `HermesStatusMerger` in the Domain package
    /// (unit-testable without the app); this delegate just calls it.
    private func currentMergedSnapshot() -> HermesStatus {
        // If the wire is alive, build a merged snapshot using the last
        // known wire values for gateway/session/approval (so the timer
        // path agrees with the wire path on whether the gateway is up).
        // displaySession comes from the same resolver as the wire path so
        // a pinned session can never make the two paths diverge.
        // If the wire has never delivered a frame (e.g. Python missing),
        // fall back to the most recent background StatusReader snapshot.
        if let wire = lastWire {
            let merged = HermesStatusMerger.merge(
                wire: wire, sqlite: lastSqliteSnapshot ?? .empty,
                displaySession: HermesStatusMerger.resolveDisplaySession(
                    wire, pinnedSessionId: pinnedSessionId))
            debugModelTrace("timer", merged)
            return merged
        }
        return lastSqliteSnapshot ?? .empty
    }

    private func refreshMenuStateLabel(state: HermesState) {
        guard let menu = statusItem.menu else { return }
        // The "状态：..." row is at a fixed position: separator, then row,
        // then separator, then quit. We re-build the menu cheaply so the
        // label stays in sync without fishing out the item.
        buildMenu()
    }

    // MARK: - Backup timer (fires regardless of wire health)
    //
    // Tier B single-driver rule: at any moment the UI is repainted by
    // exactly one source — the wire frames (0.5s cadence, main actor) while
    // the Python feed is alive, or this timer (1.5s) with a background
    // StatusReader.refresh() while it is stale/dead. The wire frames drive
    // `handleWire`; this timer does NOT repaint when the wire is fresh —
    // it only watches for staleness and becomes the driver on fallback.
    private func scheduleTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Wire fresh? frames already drive the UI; this timer is idle.
            let wireStale: Bool
            if let wire = self.lastWire {
                wireStale = Date().timeIntervalSince1970 - wire.ts > 3.0
            } else {
                wireStale = true
            }
            guard wireStale else { return }

            // Wire dead/stale → SQLite fallback, off the main thread so the
            // runloop never blocks on queries (Touch Bar repaint stays smooth).
            DispatchQueue.global().async { [weak self] in
                guard let self else { return }
                let sqlite = self.statusReader.refresh()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.lastSqliteSnapshot = sqlite
                    // Merge through lastWire when we ever had a frame (so
                    // gateway stays sourced from the wire, not kill-0), and
                    // only fall back to the pure sqlite snapshot when the
                    // wire never delivered anything.
                    let snapshot = self.currentMergedSnapshot()
                    let state = self.stateMachine.evaluate(snapshot: snapshot)
                    self.touchBarController.update(state: state, snapshot: snapshot)
                    self.refreshMenuStateLabel(state: state)
                }
            }
        }
        refreshTimer?.tolerance = 0.3
    }
}
