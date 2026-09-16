// Smoke check for Tier C: instantiate SkinProvider, walk the new builtin
// table, and verify cycleNext no longer falls through to default colors.
//
// Build & run:
//   swiftc -target x86_64-apple-macos13.0 -framework AppKit \
//          HermesTouchBar/Skin/SkinProvider.swift /tmp/skin_smoke.swift \
//          -o /tmp/skin_smoke && /tmp/skin_smoke

import Foundation
import AppKit

@main
enum SkinSmoke {
    static func hex(_ c: NSColor) -> String {
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    static var pass = 0
    static var fail = 0
    static func check(_ label: String, _ ok: Bool) {
        if ok { pass += 1; print("  ✓ \(label)") }
        else  { fail += 1; print("  ✗ \(label)") }
    }

    static func main() {
        print("== SkinProvider Tier C smoke check ==")

        // 1. builtinTable contains all 9 expected names
        let expected = ["default", "ares", "mono", "slate", "daylight",
                        "warm-lightmode", "poseidon", "sisyphus", "charizard"]
        for name in expected {
            check("builtinTable has '\(name)'", HermesSkin.builtinTable[name] != nil)
        }

        // 2. builtinOrder preserves cycle ordering
        check("builtinOrder length == 9", HermesSkin.builtinOrder.count == 9)
        check("builtinOrder starts with default",
              HermesSkin.builtinOrder.first == "default")

        // 3. Each builtin has the 6 keys the Touch Bar actually consumes
        let needed = ["ui_accent", "ui_ok", "ui_error", "ui_warn",
                      "ui_tool", "ui_thinking"]
        for name in expected {
            let skin = HermesSkin.builtinTable[name]!
            for key in needed {
                check("\(name).colors[\(key)] present",
                      skin.colors[key] != nil)
            }
        }

        // 4. Builtins are visually distinct — ui_accent must differ
        var accents = Set<String>()
        for name in expected {
            accents.insert(hex(HermesSkin.builtinTable[name]!.color("ui_accent")))
        }
        check("9 builtins have >= 7 distinct ui_accents (allowing some overlap)",
              accents.count >= 7)

        // 5. setActive on a builtin must NOT fall through to default colors
        let provider = SkinProvider()
        provider.setActive("slate")
        check("setActive('slate') picks slate, not default",
              provider.current.name == "slate")
        check("slate.ui_accent == #7EB8F6 (not default's #FFBF00)",
              hex(provider.current.color("ui_accent")) == "#7EB8F6")

        provider.setActive("charizard")
        check("setActive('charizard') picks charizard",
              provider.current.name == "charizard")
        check("charizard.ui_accent == #F29C38",
              hex(provider.current.color("ui_accent")) == "#F29C38")

        // 6. setActive on unknown name falls back to default cleanly
        provider.setActive("does-not-exist-1234")
        check("setActive(unknown) falls back to default",
              provider.current.name == "default")

        // 7. cycleNext walks the builtin list in order, wraps back to default
        provider.setActive("default")
        var observed: [String] = ["default"]
        for _ in 0..<8 {
            provider.cycleNext()
            observed.append(provider.current.name)
        }
        check("cycle produces 9 distinct names",
              Set(observed).count == 9)
        check("cycle order matches builtinOrder",
              observed == HermesSkin.builtinOrder)
        provider.cycleNext()
        check("9th cycle wraps back to default",
              provider.current.name == "default")

        // 8. Color fallback chain — builtin's own key wins over default
        let sisyphus = HermesSkin.builtinTable["sisyphus"]!
        check("sisyphus.ui_ok uses sisyphus palette (#919191), not default",
              hex(sisyphus.color("ui_ok")) == "#919191")

        // 9. Cross-skin fallback: a key missing from ares falls through to default
        // (none of the 6 critical keys are missing in our builtins, so verify
        // via an unknown key explicitly)
        let ares = HermesSkin.builtinTable["ares"]!
        check("unknown key falls back to #888888 literal",
              hex(ares.color("totally_made_up_key")) == "#888888")

        print()
        print("== \(pass) passed, \(fail) failed ==")
        exit(fail == 0 ? 0 : 1)
    }
}
