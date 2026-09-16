#!/usr/bin/env bash
# Build HermesTouchBar.app via swiftc + clang.
# Compiles TouchBarPrivate.m (ObjC) for the dlopen/DFRFoundation bridge,
# then links everything together with the Swift sources.
#
# Output: build/HermesTouchBar.app

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

OUT="$PROJECT_DIR/build/HermesTouchBar.app"
MACOS_DIR="$OUT/Contents/MacOS"
RESOURCES_DIR="$OUT/Contents/Resources"
BUILD_DIR="$PROJECT_DIR/build/obj"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

rm -rf "$OUT" "$BUILD_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$BUILD_DIR"

# 1) Resources
cp HermesTouchBar/Info.plist "$OUT/Contents/Info.plist"
cp -R HermesTouchBar/Resources/Assets.xcassets "$RESOURCES_DIR/" 2>/dev/null || true
# Tier A — long-running Hermes state emitter. Swift's HermesPythonSource
# looks this up via Bundle.main.url(forResource:withExtension:).
cp HermesTouchBar/Data/hermes_source.py "$RESOURCES_DIR/"

# 2) Compile the private-API bridge
echo "==> clang TouchBarPrivate.m"
clang -fobjc-arc -isysroot "$SDK" \
    -I "$PROJECT_DIR/HermesTouchBar/TouchBarPrivate/include" \
    -c "$PROJECT_DIR/HermesTouchBar/TouchBarPrivate/TouchBarPrivate.m" \
    -o "$BUILD_DIR/TouchBarPrivate.o"

# 3) Compile and link Swift
echo "==> swiftc HermesTouchBar"
SRCS=$(find HermesTouchBar -name "*.swift" -not -path "*/build/*" -not -path "*/TouchBarPrivate/include/*")
echo "    sources:"
echo "$SRCS" | sed 's/^/      /'

env CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/hermes-touchbar-clang-cache}" \
    swiftc \
    -sdk "$SDK" \
    -target x86_64-apple-macos13.0 \
    -framework AppKit -framework Carbon -lsqlite3 \
    -I "$PROJECT_DIR/HermesTouchBar/TouchBarPrivate/include" \
    -Xcc -fmodule-map-file="$PROJECT_DIR/HermesTouchBar/TouchBarPrivate/include/module.modulemap" \
    "$BUILD_DIR/TouchBarPrivate.o" \
    $SRCS \
    -o "$MACOS_DIR/HermesTouchBar"

# 4) Ad-hoc sign so the app will launch
codesign --force --sign - "$OUT" 2>/dev/null || true

echo
echo "✅ Built: $OUT"
echo "   open \"$OUT\""
