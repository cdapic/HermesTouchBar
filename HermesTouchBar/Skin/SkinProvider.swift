// SkinProvider.swift
// Loads ~/.hermes/skins/<name>.yaml into a [String: String] of color tokens.
// Falls back to the built-in palette (the one matching the requested name, or
// `default` if nothing matches). Watches the directory via DispatchSource for
// FSEvents-free, lightweight change detection.
//
// Hand-rolled YAML parser: only the `colors:` and `top-level: value` shapes
// the Hermes skin schema uses. Avoids a Yams dependency for this first cut.
//
// Tier C (v0.2.0): all 9 upstream builtin palettes are now compiled in as
// `HermesSkin.<name>` constants. `setActive(_:)` looks them up first, then
// falls back to ~/.hermes/skins/<name>.yaml, then to `default`. Previously
// selecting a builtin silently fell through to default because the synthesized
// record had an empty `colors` dict.
//
// Palette source: /Users/dingan/.hermes/hermes-agent/hermes_cli/skin_engine.py
// Keep this file in sync when upstream adds/renames builtins.

import Foundation
import AppKit

struct HermesSkin {
    let name: String
    let description: String
    let colors: [String: String]   // key -> "#RRGGBB"
    let toolPrefix: String
    let promptSymbol: String

    /// Resolve a token. Lookup order:
    ///   1. this skin's `colors`
    ///   2. the built-in `default` skin's `colors` (cross-skin fallback for
    ///      keys a particular skin doesn't define, e.g. `ui_thinking` in
    ///      skins that lean on the upstream "fall back to banner_dim" rule)
    ///   3. literal "#888888" (so we never return transparent/black on a
    ///      missing key in a way that hides UI state)
    func color(_ key: String) -> NSColor {
        let hex = colors[key]
            ?? HermesSkin.default.colors[key]
            ?? "#888888"
        return NSColor(hex: hex) ?? .systemGray
    }

    // MARK: Built-in palette catalogue
    //
    // Order matters — `cycleNext()` walks this list verbatim and `available`
    // is built by prepending it to the user-YAML list.
    static let builtinOrder: [String] = [
        "default", "ares", "mono", "slate", "daylight",
        "warm-lightmode", "poseidon", "sisyphus", "charizard"
    ]

    /// Built-in palette table for O(1) lookup. `default` is always present;
    /// the other eight mirror upstream `skin_engine.py` `_BUILTIN_SKINS`.
    /// Touch Bar consumes only ~10 of these keys (see DESIGN.md §5.4); the
    /// extras are kept so TUI/desktop consumers can share this dict later.
    static let builtinTable: [String: HermesSkin] = [
        "default":         .default,
        "ares":            .ares,
        "mono":            .mono,
        "slate":           .slate,
        "daylight":        .daylight,
        "warm-lightmode":  .warmLightmode,
        "poseidon":        .poseidon,
        "sisyphus":        .sisyphus,
        "charizard":       .charizard,
    ]

    /// Fallback palette. Mirrors upstream `default` in `skin_engine.py`.
    /// Used both as a real builtin AND as the cross-skin fallback inside
    /// `color(_:)`.
    static let `default` = HermesSkin(
        name: "default",
        description: "Classic Hermes — gold and kawaii",
        colors: [
            "banner_border": "#CD7F32", "banner_title": "#FFD700",
            "banner_accent": "#FFBF00", "banner_dim": "#B8860B",
            "banner_text": "#FFF8DC",
            "ui_accent": "#FFBF00", "ui_label": "#DAA520",
            "ui_ok": "#4caf50", "ui_error": "#ef5350", "ui_warn": "#ffa726",
            "ui_tool": "#FFBF00", "ui_thinking": "#CC9B1F",
            "prompt": "#FFF8DC", "input_rule": "#CD7F32",
            "response_border": "#FFD700",
            "status_bar_bg": "#1a1a2e", "status_bar_text": "#C0C0C0",
            "status_bar_strong": "#FFD700", "status_bar_dim": "#8A7A4A",
            "status_bar_good": "#8FBC8F", "status_bar_warn": "#FFD700",
            "status_bar_bad": "#FF8C00", "status_bar_critical": "#FF6B6B",
            "session_label": "#DAA520", "session_border": "#8B8682",
            "completion_menu_bg": "#1a1a2e", "completion_menu_current_bg": "#333355",
            "selection_bg": "#3a3a55", "shell_dollar": "#4dabf7",
            "voice_status_bg": "#1a1a2e"
        ],
        toolPrefix: "┊",
        promptSymbol: "❯"
    )

    /// War-god theme — crimson and bronze.
    static let ares = HermesSkin(
        name: "ares",
        description: "War-god theme — crimson and bronze",
        colors: [
            "banner_border": "#A93333", "banner_title": "#C7A96B",
            "banner_accent": "#DD4A3A", "banner_dim": "#905151",
            "banner_text": "#F1E6CF",
            "ui_accent": "#DD4A3A", "ui_label": "#C7A96B",
            "ui_ok": "#4caf50", "ui_error": "#ef5350", "ui_warn": "#ffa726",
            "ui_tool": "#DD4A3A", "ui_thinking": "#C7A96B",
            "prompt": "#F1E6CF", "input_rule": "#A93333",
            "response_border": "#C7A96B",
            "status_bar_bg": "#2A1212", "status_bar_text": "#F1E6CF",
            "status_bar_strong": "#C7A96B", "status_bar_dim": "#756054",
            "status_bar_good": "#7BC96F", "status_bar_warn": "#C7A96B",
            "status_bar_bad": "#DD4A3A", "status_bar_critical": "#EF5350",
            "session_label": "#C7A96B", "session_border": "#6E584B",
            "completion_menu_bg": "#2A1212", "completion_menu_current_bg": "#5C221D",
            "selection_bg": "#692620", "shell_dollar": "#DD4A3A",
            "voice_status_bg": "#2A1212"
        ],
        toolPrefix: "┊",
        promptSymbol: "⚔"
    )

    /// Monochrome — clean grayscale.
    static let mono = HermesSkin(
        name: "mono",
        description: "Monochrome — clean grayscale",
        colors: [
            "banner_border": "#5E5E5E", "banner_title": "#e6edf3",
            "banner_accent": "#aaaaaa", "banner_dim": "#606060",
            "banner_text": "#c9d1d9",
            "ui_accent": "#aaaaaa", "ui_label": "#888888",
            "ui_ok": "#888888", "ui_error": "#cccccc", "ui_warn": "#999999",
            "ui_tool": "#aaaaaa", "ui_thinking": "#606060",
            "prompt": "#c9d1d9", "input_rule": "#606060",
            "response_border": "#aaaaaa",
            "status_bar_bg": "#1F1F1F", "status_bar_text": "#C9D1D9",
            "status_bar_strong": "#E6EDF3", "status_bar_dim": "#777777",
            "status_bar_good": "#B5B5B5", "status_bar_warn": "#AAAAAA",
            "status_bar_bad": "#D0D0D0", "status_bar_critical": "#F0F0F0",
            "session_label": "#888888", "session_border": "#5E5E5E",
            "completion_menu_bg": "#1F1F1F", "completion_menu_current_bg": "#464646",
            "selection_bg": "#505050", "shell_dollar": "#aaaaaa",
            "voice_status_bg": "#1F1F1F"
        ],
        toolPrefix: "┊",
        promptSymbol: "❯"
    )

    /// Cool blue — developer-focused.
    static let slate = HermesSkin(
        name: "slate",
        description: "Cool blue — developer-focused",
        colors: [
            "banner_border": "#4169e1", "banner_title": "#7eb8f6",
            "banner_accent": "#8EA8FF", "banner_dim": "#545E6B",
            "banner_text": "#c9d1d9",
            "ui_accent": "#7eb8f6", "ui_label": "#8EA8FF",
            "ui_ok": "#63D0A6", "ui_error": "#F7A072", "ui_warn": "#e6a855",
            "ui_tool": "#7eb8f6", "ui_thinking": "#8EA8FF",
            "prompt": "#c9d1d9", "input_rule": "#4169e1",
            "response_border": "#7eb8f6",
            "status_bar_bg": "#151C2F", "status_bar_text": "#C9D1D9",
            "status_bar_strong": "#7EB8F6", "status_bar_dim": "#5D6672",
            "status_bar_good": "#63D0A6", "status_bar_warn": "#E6A855",
            "status_bar_bad": "#F7A072", "status_bar_critical": "#FF7A7A",
            "session_label": "#7eb8f6", "session_border": "#545E6B",
            "completion_menu_bg": "#151C2F", "completion_menu_current_bg": "#324867",
            "selection_bg": "#3A5375", "shell_dollar": "#7eb8f6",
            "voice_status_bg": "#151C2F"
        ],
        toolPrefix: "┊",
        promptSymbol: "❯"
    )

    /// Light theme for bright terminals with dark text and cool blue accents.
    static let daylight = HermesSkin(
        name: "daylight",
        description: "Light theme for bright terminals with dark text and cool blue accents",
        colors: [
            "banner_border": "#2563EB", "banner_title": "#0F172A",
            "banner_accent": "#1D4ED8", "banner_dim": "#475569",
            "banner_text": "#111827",
            "ui_accent": "#2563EB", "ui_label": "#0F766E",
            "ui_ok": "#15803D", "ui_error": "#B91C1C", "ui_warn": "#B45309",
            "ui_tool": "#2563EB", "ui_thinking": "#475569",
            "prompt": "#111827", "input_rule": "#6E94BE",
            "response_border": "#2563EB",
            "status_bar_bg": "#E5EDF8", "status_bar_text": "#111827",
            "status_bar_strong": "#2563EB", "status_bar_dim": "#838890",
            "status_bar_good": "#15803D", "status_bar_warn": "#B45309",
            "status_bar_bad": "#B45309", "status_bar_critical": "#B91C1C",
            "session_label": "#1D4ED8", "session_border": "#64748B",
            "completion_menu_bg": "#F8FAFC", "completion_menu_current_bg": "#DBEAFE",
            "completion_menu_meta_bg": "#EEF2FF",
            "completion_menu_meta_current_bg": "#BFDBFE",
            "selection_bg": "#D3E0FB", "shell_dollar": "#2563EB",
            "voice_status_bg": "#E5EDF8"
        ],
        toolPrefix: "┊",
        promptSymbol: "❯"
    )

    /// Warm light mode — dark brown/gold text for light terminal backgrounds.
    static let warmLightmode = HermesSkin(
        name: "warm-lightmode",
        description: "Warm light mode — dark brown/gold text for light terminal backgrounds",
        colors: [
            "banner_border": "#8B6914", "banner_title": "#5C3D11",
            "banner_accent": "#8B4513", "banner_dim": "#8B7355",
            "banner_text": "#2C1810",
            "ui_accent": "#8B4513", "ui_label": "#5C3D11",
            "ui_ok": "#2E7D32", "ui_error": "#C62828", "ui_warn": "#E65100",
            "ui_tool": "#8B4513", "ui_thinking": "#8B7355",
            "prompt": "#2C1810", "input_rule": "#8B6914",
            "response_border": "#8B6914",
            "status_bar_bg": "#F5F0E8", "status_bar_text": "#2C1810",
            "status_bar_strong": "#8B4513", "status_bar_dim": "#8A8F98",
            "status_bar_good": "#2E7D32", "status_bar_warn": "#E65100",
            "status_bar_bad": "#DA4D00", "status_bar_critical": "#C62828",
            "session_label": "#5C3D11", "session_border": "#A0845C",
            "completion_menu_bg": "#F5EFE0", "completion_menu_current_bg": "#E8DCC8",
            "completion_menu_meta_bg": "#F0E8D8",
            "completion_menu_meta_current_bg": "#DFCFB0",
            "selection_bg": "#E8DAD0", "shell_dollar": "#8B4513",
            "voice_status_bg": "#F5F0E8"
        ],
        toolPrefix: "┊",
        promptSymbol: "❯"
    )

    /// Ocean-god theme — deep blue and seafoam.
    static let poseidon = HermesSkin(
        name: "poseidon",
        description: "Ocean-god theme — deep blue and seafoam",
        colors: [
            "banner_border": "#2A6FB9", "banner_title": "#A9DFFF",
            "banner_accent": "#5DB8F5", "banner_dim": "#44638F",
            "banner_text": "#EAF7FF",
            "ui_accent": "#5DB8F5", "ui_label": "#A9DFFF",
            "ui_ok": "#4caf50", "ui_error": "#ef5350", "ui_warn": "#ffa726",
            "ui_tool": "#5DB8F5", "ui_thinking": "#44638F",
            "prompt": "#EAF7FF", "input_rule": "#2A6FB9",
            "response_border": "#5DB8F5",
            "status_bar_bg": "#0F2440", "status_bar_text": "#EAF7FF",
            "status_bar_strong": "#A9DFFF", "status_bar_dim": "#52708A",
            "status_bar_good": "#6ED7B0", "status_bar_warn": "#5DB8F5",
            "status_bar_bad": "#3576BC", "status_bar_critical": "#D94F4F",
            "session_label": "#A9DFFF", "session_border": "#496884",
            "completion_menu_bg": "#0F2440", "completion_menu_current_bg": "#254D73",
            "selection_bg": "#2A587F", "shell_dollar": "#5DB8F5",
            "voice_status_bg": "#0F2440"
        ],
        toolPrefix: "┊",
        promptSymbol: "Ψ"
    )

    /// Sisyphean theme — austere grayscale with persistence.
    static let sisyphus = HermesSkin(
        name: "sisyphus",
        description: "Sisyphean theme — austere grayscale with persistence",
        colors: [
            "banner_border": "#B7B7B7", "banner_title": "#F5F5F5",
            "banner_accent": "#E7E7E7", "banner_dim": "#5C5C5C",
            "banner_text": "#D3D3D3",
            "ui_accent": "#E7E7E7", "ui_label": "#D3D3D3",
            "ui_ok": "#919191", "ui_error": "#E7E7E7", "ui_warn": "#B7B7B7",
            "ui_tool": "#E7E7E7", "ui_thinking": "#5C5C5C",
            "prompt": "#F5F5F5", "input_rule": "#656565",
            "response_border": "#B7B7B7",
            "status_bar_bg": "#202020", "status_bar_text": "#D3D3D3",
            "status_bar_strong": "#F5F5F5", "status_bar_dim": "#6D6D6D",
            "status_bar_good": "#B7B7B7", "status_bar_warn": "#D3D3D3",
            "status_bar_bad": "#E7E7E7", "status_bar_critical": "#F5F5F5",
            "session_label": "#919191", "session_border": "#656565",
            "completion_menu_bg": "#202020", "completion_menu_current_bg": "#585858",
            "selection_bg": "#666666", "shell_dollar": "#E7E7E7",
            "voice_status_bg": "#202020"
        ],
        toolPrefix: "┊",
        promptSymbol: "◉"
    )

    /// Volcanic theme — burnt orange and ember.
    static let charizard = HermesSkin(
        name: "charizard",
        description: "Volcanic theme — burnt orange and ember",
        colors: [
            "banner_border": "#C75B1D", "banner_title": "#FFD39A",
            "banner_accent": "#F29C38", "banner_dim": "#C58A45",
            "banner_text": "#FFF0D4",
            "ui_accent": "#F29C38", "ui_label": "#FFD39A",
            "ui_ok": "#4caf50", "ui_error": "#ef5350", "ui_warn": "#ffa726",
            "ui_tool": "#F29C38", "ui_thinking": "#C58A45",
            "prompt": "#FFF0D4", "input_rule": "#C75B1D",
            "response_border": "#F29C38",
            "status_bar_bg": "#2B160E", "status_bar_text": "#FFF0D4",
            "status_bar_strong": "#FFD39A", "status_bar_dim": "#826144",
            "status_bar_good": "#6BCB77", "status_bar_warn": "#F29C38",
            "status_bar_bad": "#E2832B", "status_bar_critical": "#EF5350",
            "session_label": "#FFD39A", "session_border": "#7B593A",
            "completion_menu_bg": "#0B0503", "completion_menu_current_bg": "#4A1B07",
            "completion_menu_meta_bg": "#120806",
            "completion_menu_meta_current_bg": "#5A260D",
            "selection_bg": "#5A260D", "shell_dollar": "#F29C38",
            "voice_status_bg": "#2B160E"
        ],
        toolPrefix: "┊",
        promptSymbol: "✦"
    )

    /// Legacy alias preserved for callers that referenced the old static list.
    static let builtinNames: [String] = builtinOrder
}

final class SkinProvider {

    private(set) var current: HermesSkin = .default
    private(set) var available: [String] = HermesSkin.builtinOrder
    private var dirWatcher: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "HermesTouchBar.skin")
    private var onChange: (() -> Void)?

    func startWatching(onChange: @escaping () -> Void) {
        self.onChange = onChange
        refresh()
        watch()
    }

    func stopWatching() {
        dirWatcher?.cancel(); dirWatcher = nil
        if fd >= 0 { close(fd); fd = -1 }
    }

    /// Advance to the next skin in `available` order. Wraps; never returns the
    /// same skin twice in a row.
    func cycleNext() {
        guard !available.isEmpty else { return }
        let idx = available.firstIndex(of: current.name) ?? -1
        let next = available[(idx + 1) % available.count]
        setActive(next)
    }

    /// Activate a skin by name.
    ///
    /// Lookup order:
    ///   1. Built-in palette table (`HermesSkin.builtinTable[name]`)
    ///   2. User YAML at `~/.hermes/skins/<name>.yaml` if present
    ///   3. Built-in `default` palette (last-resort; never crashes)
    ///
    /// Before Tier C this function synthesized an empty `HermesSkin` for
    /// builtin names, which then color-fell-through to `default` — so
    /// `cycleNext` produced no visible change. Now builtins resolve to their
    /// real palette.
    func setActive(_ name: String) {
        if let builtin = HermesSkin.builtinTable[name] {
            current = builtin
            onChange?()
            return
        }

        let path = skinFile(name)
        if FileManager.default.fileExists(atPath: path.path),
           let loaded = try? loadYAML(at: path) {
            current = loaded
            onChange?()
            return
        }

        // Unknown name and no matching YAML: silently fall back to default
        // rather than synthesizing an empty record (which would render as
        // "skin name says X but colors are default" — the very confusion
        // Tier C fixes).
        current = .default
        onChange?()
    }

    // MARK: - File watching
    private func watch() {
        let dir = skinsDir()
        fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend], queue: queue)
        src.setEventHandler { [weak self] in
            DispatchQueue.main.async {
                self?.refresh()
                self?.onChange?()
            }
        }
        src.resume()
        dirWatcher = src
    }

    private func refresh() {
        available = HermesSkin.builtinOrder
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(atPath: skinsDir().path) {
            for f in files where f.hasSuffix(".yaml") {
                let name = (f as NSString).deletingPathExtension
                if !available.contains(name) { available.append(name) }
            }
        }
        // Try to honor the active skin from config.yaml's display.skin
        if let active = readActiveSkinFromConfig(), available.contains(active) {
            setActive(active)
        }
    }

    // MARK: - IO helpers
    private func skinsDir() -> URL {
        let home = StatusReader.defaultHome()
        return home.appendingPathComponent("skins")
    }
    private func skinFile(_ name: String) -> URL {
        skinsDir().appendingPathComponent("\(name).yaml")
    }
    private func readActiveSkinFromConfig() -> String? {
        let path = StatusReader.defaultHome().appendingPathComponent("config.yaml").path
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in raw.split(separator: "\n") {
            // Explicit CharacterSet so the file also compiles standalone
            // (e.g. when pulled into a smoke test).
            let t = line.trimmingCharacters(in: CharacterSet.whitespaces)
            if t.hasPrefix("display.skin:") || t.hasPrefix("display:") {
                // Explicit CharacterSet to side-step Swift inference quirks
                // when this file is compiled in isolation (smoke tests etc.).
                if let v = t.split(separator: ":")
                        .last
                        .map({ $0.trimmingCharacters(in: CharacterSet.whitespaces) }),
                   !v.isEmpty { return v }
            }
        }
        return nil
    }

    // MARK: - Tiny YAML loader
    /// Loads only the `name:`, `description:`, `tool_prefix:`, and `colors:`
    /// blocks we care about. Sufficient for all 9 builtin + 99% of user skins.
    func loadYAML(at url: URL) throws -> HermesSkin {
        let raw = try String(contentsOf: url, encoding: .utf8)
        var name = url.deletingPathExtension().lastPathComponent
        var desc = ""
        var prefix = "┊"
        var colors: [String: String] = [:]
        var inColors = false
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineStr = String(line)
            let trimmed = lineStr.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if !inColors {
                if trimmed.hasPrefix("colors:") { inColors = true; continue }
                if let colon = trimmed.firstIndex(of: ":") {
                    let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
                    let val = String(trimmed[trimmed.index(after: colon)...])
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    switch key {
                    case "name":        name = val
                    case "description": desc = val
                    case "tool_prefix": prefix = val
                    default: break
                    }
                }
            } else {
                // inside colors:
                if !lineStr.hasPrefix(" ") && !lineStr.hasPrefix("\t") {
                    inColors = false; continue
                }
                if let colon = trimmed.firstIndex(of: ":") {
                    let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
                    let val = String(trimmed[trimmed.index(after: colon)...])
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    if val.hasPrefix("#") { colors[key] = val }
                }
            }
        }
        return HermesSkin(name: name, description: desc, colors: colors,
                          toolPrefix: prefix, promptSymbol: "❯")
    }
}

// MARK: - NSColor hex extension
extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        let r = CGFloat((v >> 16) & 0xFF) / 255
        let g = CGFloat((v >> 8)  & 0xFF) / 255
        let b = CGFloat( v        & 0xFF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
