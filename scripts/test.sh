#!/usr/bin/env bash
# Run the standalone smoke checks under tests/.
#
# These are NOT a real test target — the project has no .xcodeproj / Package.swift
# yet, so XCTest / Swift Testing aren't wired up. The smoke checks compile the
# production source files directly with swiftc and exercise the public API.
#
# When the project gets an xcodeproj (XcodeGen from project.yml) or a
# Package.swift, these should migrate into a proper HermesTouchBarTests target
# with XCTest assertions instead of print-and-exit.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

SDK="$(xcrun --sdk macosx --show-sdk-path)"

# Tier F — the smoke checks now exercise the HermesDomain package (built via
# SwiftPM) instead of compiling production sources inline. This proves the
# public API of the package, not a copy of it.
(cd "$PROJECT_DIR/Domain" && swift build --configuration release >/dev/null)
DOMAIN_BIN="$(cd "$PROJECT_DIR/Domain" && swift build --configuration release --show-bin-path)"

run_smoke() {
    local smoke_file="$1"
    local out_bin="/tmp/$(basename "$smoke_file" .swift)"
    echo "==> $smoke_file"
    swiftc -parse-as-library \
        -sdk "$SDK" \
        -target x86_64-apple-macos13.0 \
        -framework AppKit -lsqlite3 \
        -I "$DOMAIN_BIN/Modules" \
        "$DOMAIN_BIN"/HermesDomain.build/*.o \
        "$smoke_file" \
        -o "$out_bin"
    "$out_bin"
}

# Discover tests/*.swift and run each.
shopt -s nullglob
for t in tests/*.swift; do
    run_smoke "$t"
    echo
done
shopt -u nullglob

# Python smoke: hermes_source state derivation + mid-turn detection.
# _derive_state itself is stdlib-only (Hermes imports are best-effort), so
# this runs with the Hermes venv python when available, else system python3.
HERMES_PY="${HERMES_PYTHON:-$HOME/.hermes/hermes-agent/venv/bin/python3}"
if [ ! -x "$HERMES_PY" ]; then
    HERMES_PY="$(command -v python3 || true)"
fi
if [ -n "$HERMES_PY" ] && [ -x "$HERMES_PY" ]; then
    echo "==> tests/derive_state_smoke.py"
    "$HERMES_PY" tests/derive_state_smoke.py
    echo
fi

# Tier E — formal XCTest target via the XcodeGen-generated project.
# Requires: brew install xcodegen && xcodegen generate (once, or after any
# project.yml change). Keeps the swiftc smokes above as the fast loop; this
# is the authoritative test run.
echo "==> xcodebuild test (HermesTouchBarTests)"
if [ -d HermesTouchBar.xcodeproj ]; then
    xcodebuild test -project HermesTouchBar.xcodeproj -scheme HermesTouchBarTests \
        -destination 'platform=macOS' -quiet 2>&1 | tail -6
else
    echo "    HermesTouchBar.xcodeproj missing — run: xcodegen generate"
    exit 1
fi
