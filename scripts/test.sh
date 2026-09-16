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

run_smoke() {
    local smoke_file="$1"
    local out_bin="/tmp/$(basename "$smoke_file" .swift)"
    echo "==> $smoke_file"
    swiftc -parse-as-library \
        -sdk "$SDK" \
        -target x86_64-apple-macos13.0 \
        -framework AppKit -lsqlite3 \
        HermesTouchBar/Skin/SkinProvider.swift \
        HermesTouchBar/Status/StatusReader.swift \
        HermesTouchBar/Status/StateMachine.swift \
        HermesTouchBar/Models/State.swift \
        HermesTouchBar/Models/HermesWireStatus.swift \
        HermesTouchBar/Models/HermesWireActivity.swift \
        HermesTouchBar/Data/HermesPythonSource.swift \
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
