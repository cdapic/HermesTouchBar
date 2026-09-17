// XCTest port of tests/skin_smoke.swift (76 assertions). Tier E — runs under
// `xcodebuild test` via the XcodeGen-generated HermesTouchBar.xcodeproj.
// The original smoke file stays for scripts/test.sh quick regression.

import XCTest
import HermesDomain
import AppKit

final class SkinProviderTests: XCTestCase {

    private func hex(_ c: NSColor) -> String {
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    func testAll() {
        // 1. builtinTable contains all 9 expected names
        let expected = ["default", "ares", "mono", "slate", "daylight",
                        "warm-lightmode", "poseidon", "sisyphus", "charizard"]
        for name in expected {
            XCTAssertNotNil(HermesSkin.builtinTable[name], "builtinTable has '\(name)'")
        }

        // 2. builtinOrder preserves cycle ordering
        XCTAssertEqual(HermesSkin.builtinOrder.count, 9, "builtinOrder length == 9")
        XCTAssertEqual(HermesSkin.builtinOrder.first, "default", "builtinOrder starts with default")

        // 3. Each builtin has the 6 keys the Touch Bar actually consumes
        let needed = ["ui_accent", "ui_ok", "ui_error", "ui_warn",
                      "ui_tool", "ui_thinking"]
        for name in expected {
            let skin = HermesSkin.builtinTable[name]!
            for key in needed {
                XCTAssertNotNil(skin.colors[key], "\(name).colors[\(key)] present")
            }
        }

        // 4. Builtins are visually distinct — ui_accent must differ
        var accents = Set<String>()
        for name in expected {
            accents.insert(hex(HermesSkin.builtinTable[name]!.color("ui_accent")))
        }
        XCTAssertGreaterThanOrEqual(accents.count, 7,
            "9 builtins have >= 7 distinct ui_accents (allowing some overlap)")

        // 5. setActive on a builtin must NOT fall through to default colors
        let provider = SkinProvider()
        provider.setActive("slate")
        XCTAssertEqual(provider.current.name, "slate", "setActive('slate') picks slate, not default")
        XCTAssertEqual(hex(provider.current.color("ui_accent")), "#7EB8F6",
            "slate.ui_accent == #7EB8F6 (not default's #FFBF00)")

        provider.setActive("charizard")
        XCTAssertEqual(provider.current.name, "charizard", "setActive('charizard') picks charizard")
        XCTAssertEqual(hex(provider.current.color("ui_accent")), "#F29C38",
            "charizard.ui_accent == #F29C38")

        // 6. setActive on unknown name falls back to default cleanly
        provider.setActive("does-not-exist-1234")
        XCTAssertEqual(provider.current.name, "default", "setActive(unknown) falls back to default")

        // 7. cycleNext walks the builtin list in order, wraps back to default
        provider.setActive("default")
        var observed: [String] = ["default"]
        for _ in 0..<8 {
            provider.cycleNext()
            observed.append(provider.current.name)
        }
        XCTAssertEqual(Set(observed).count, 9, "cycle produces 9 distinct names")
        XCTAssertEqual(observed, HermesSkin.builtinOrder, "cycle order matches builtinOrder")
        provider.cycleNext()
        XCTAssertEqual(provider.current.name, "default", "9th cycle wraps back to default")

        // 8. Color fallback chain — builtin's own key wins over default
        let sisyphus = HermesSkin.builtinTable["sisyphus"]!
        XCTAssertEqual(hex(sisyphus.color("ui_ok")), "#919191",
            "sisyphus.ui_ok uses sisyphus palette (#919191), not default")

        // 9. Cross-skin fallback: unknown key falls through to #888888 literal
        let ares = HermesSkin.builtinTable["ares"]!
        XCTAssertEqual(hex(ares.color("totally_made_up_key")), "#888888",
            "unknown key falls back to #888888 literal")
    }
}
