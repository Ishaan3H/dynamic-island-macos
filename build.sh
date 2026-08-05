#!/bin/bash
#
# Builds DynamicIsland.app. Works with Command Line Tools alone — no Xcode needed.
#
#   ./build.sh          release build
#   ./build.sh debug    debug build
#
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/DynamicIsland.app"

echo "==> Compiling ($CONFIG)"
swift build -c "$CONFIG" --package-path "$ROOT"

BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/DynamicIsland"
if [ ! -x "$BIN" ]; then
    echo "error: binary not found at $BIN" >&2
    exit 1
fi

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DynamicIsland"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature. TCC keys grants to the code signature, so an unsigned build
# would re-prompt for Automation on every rebuild and forget the grant each time.
echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - --identifier com.qwerty.dynamicisland "$APP"
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

# Let Launch Services notice the dynamicisland:// URL scheme.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP" 2>/dev/null || true

echo
echo "Built: $APP"
echo "Run:   open \"$APP\"     (or: \"$APP/Contents/MacOS/DynamicIsland\" for console output)"
