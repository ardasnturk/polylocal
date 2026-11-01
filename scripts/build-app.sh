#!/usr/bin/env bash
# Builds build/Translater.app from the SwiftPM package.
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
APP="$ROOT/build/Translater.app"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"

cd "$ROOT"
swift build -c "$CONFIG" --product Translater
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Translater"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Translater"
cp "$ROOT/models/catalog.json" "$APP/Contents/Resources/catalog.json"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.translater.app</string>
    <key>CFBundleName</key><string>Translater</string>
    <key>CFBundleDisplayName</key><string>Translater</string>
    <key>CFBundleExecutable</key><string>Translater</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleDevelopmentRegion</key><string>tr</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHumanReadableCopyright</key><string>Açık kaynak yazılım</string>
</dict>
</plist>
PLIST

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)}"
IDENTITY="${IDENTITY:--}"
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP" >/dev/null
echo "Built $APP ($CONFIG, signed: $IDENTITY)"
