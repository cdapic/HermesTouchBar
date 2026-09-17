// swift-tools-version: 5.9
// HermesDomain — Tier F: the pure-logic layer of HermesTouchBar, extracted
// into its own Swift Package so the UI shell (AppDelegate / TouchBarController)
// cannot accidentally couple with state derivation, skin resolution or the
// wire schema, and so the logic has its own build/test loop.
//
// Contents (all AppKit-free except SkinProvider's NSColor hex helper):
//   - State.swift            HermesStatus / HermesState (the UI's snapshot)
//   - HermesWireStatus.swift wire schema decoded from hermes_source.py
//   - HermesWireActivity.swift activity-timestamp heuristics
//   - StateMachine.swift     state machine evaluating a HermesStatus
//   - SkinProvider.swift     builtin + user skins, token lookup, watching
//
// DataSource (StatusReader SQLite, HermesPythonSource subprocess) stays in
// the app shell so this package has no sqlite3/Python/IO coupling and can be
// unit-tested in isolation.

import PackageDescription

let package = Package(
    name: "HermesDomain",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "HermesDomain", targets: ["HermesDomain"])
    ],
    targets: [
        .target(name: "HermesDomain")
    ]
)
