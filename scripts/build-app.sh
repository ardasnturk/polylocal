#!/usr/bin/env bash
# Builds build/Polylocal.app from the SwiftPM package.
# If scripts/build-llama-server.sh has been run, its llama-server is bundled in Contents/Helpers;
# otherwise the app falls back to a Homebrew llama-server (development only).
#
#   scripts/build-app.sh              # release build
#   scripts/build-app.sh debug        # debug build
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
#
# Signing: uses $SIGN_IDENTITY, else the first "Apple Development" identity, else ad-hoc.
# A stable identity matters during development: macOS ties the Accessibility grant to the
# signature, so ad-hoc builds lose the permission on every rebuild.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Polylocal.app"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"

cd "$ROOT"
swift build -c "$CONFIG" --product Polylocal
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Polylocal"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Polylocal"
cp "$ROOT/models/catalog.json" "$APP/Contents/Resources/catalog.json"
cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/"
# UI translations: English strings are the keys in code; other languages live in Resources/<lang>.lproj.
cp -R "$ROOT"/Resources/*.lproj "$APP/Contents/Resources/"

LLAMA="$ROOT/build/llama-server/llama-server"
if [ -x "$LLAMA" ]; then
    mkdir -p "$APP/Contents/Helpers"
    cp "$LLAMA" "$APP/Contents/Helpers/llama-server"
    cp "$ROOT/build/llama-server/LICENSE" "$APP/Contents/Resources/llama.cpp-LICENSE"
    echo "Bundled llama-server $(cat "$ROOT/build/llama-server/VERSION" 2>/dev/null)"
else
    echo "note: no bundled llama-server (run scripts/build-llama-server.sh); using Homebrew's at runtime"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.polylocal.app</string>
    <key>CFBundleName</key><string>Polylocal</string>
    <key>CFBundleDisplayName</key><string>Polylocal</string>
    <key>CFBundleExecutable</key><string>Polylocal</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>tr</string></array>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Arda Senturk. MIT License.</string>
</dict>
</plist>
PLIST

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)}"
IDENTITY="${IDENTITY:--}"
# Release signing (Developer ID) needs a secure timestamp for notarization; dev builds skip the network call.
TIMESTAMP="--timestamp=none"
[[ "$IDENTITY" == "Developer ID"* ]] && TIMESTAMP="--timestamp"
# Sign inside-out: the helper first, then the app (no --deep).
if [ -f "$APP/Contents/Helpers/llama-server" ]; then
    codesign --force --options runtime $TIMESTAMP --sign "$IDENTITY" "$APP/Contents/Helpers/llama-server" >/dev/null
fi
codesign --force --options runtime $TIMESTAMP --sign "$IDENTITY" "$APP" >/dev/null
echo "Built $APP ($CONFIG, signed: $IDENTITY)"
