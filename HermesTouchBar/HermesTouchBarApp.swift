// HermesTouchBarApp.swift
// Entry point. Boots NSApplication with .accessory activation policy so the
// app lives in the menu bar without a Dock icon.

import AppKit

@main
enum HermesTouchBarApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
