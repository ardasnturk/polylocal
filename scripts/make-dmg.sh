#!/usr/bin/env bash
# Release build: Developer ID–signed Polylocal.app in a DMG, optionally notarized.
#
#   scripts/build-llama-server.sh                       # once per llama.cpp version
#   VERSION=0.1.0 scripts/make-dmg.sh                   # signed DMG
#   VERSION=0.1.0 NOTARY_PROFILE=polylocal scripts/make-dmg.sh   # signed + notarized + stapled
#
# NOTARY_PROFILE is a notarytool keychain profile, created once with:
#   xcrun notarytool store-credentials polylocal --apple-id <apple-id> --team-id <team-id>
# SIGN_IDENTITY defaults to the first "Developer ID Application" identity in the keychain.
# The styled window (background, icon layout) needs dmgbuild: `uv tool install dmgbuild` or `pipx install dmgbuild`.
# Regenerate the background with scripts/make-dmg-background.swift.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-0.1.0}"
APP="$ROOT/build/Polylocal.app"
DMG="$ROOT/build/Polylocal-$VERSION.dmg"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application[^"]*\)".*/\1/p' | head -1)}"
if [[ "$IDENTITY" != "Developer ID Application"* ]]; then
    echo "error: no Developer ID Application identity found (set SIGN_IDENTITY)" >&2
    exit 1
fi

if ! command -v dmgbuild >/dev/null; then
    echo "error: dmgbuild not found (uv tool install dmgbuild)" >&2
    exit 1
fi

# A release must run without Homebrew.
if [ ! -x "$ROOT/build/llama-server/llama-server" ] && [ "${ALLOW_NO_LLAMA:-0}" != 1 ]; then
    echo "error: build/llama-server/llama-server missing; run scripts/build-llama-server.sh first" >&2
    exit 1
fi
if [ ! -x "$ROOT/build/whisper-server/whisper-server" ] && [ "${ALLOW_NO_WHISPER:-0}" != 1 ]; then
    echo "error: build/whisper-server/whisper-server missing; run scripts/build-whisper-server.sh first" >&2
    exit 1
fi
if [ ! -d "$ROOT/build/mic-driver/PolylocalMicrophone.driver" ] && [ "${ALLOW_NO_MIC_DRIVER:-0}" != 1 ]; then
    echo "error: build/mic-driver/PolylocalMicrophone.driver missing; run scripts/build-mic-driver.sh first" >&2
    exit 1
fi

VERSION="$VERSION" SIGN_IDENTITY="$IDENTITY" "$ROOT/scripts/build-app.sh" release
codesign --verify --strict --verbose=2 "$APP"

rm -f "$DMG"
dmgbuild -s "$ROOT/scripts/dmg-settings.py" -D app="$APP" -D root="$ROOT" "Polylocal" "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
else
    echo "note: not notarized (set NOTARY_PROFILE); Gatekeeper will block it on other Macs"
fi
echo "Built $DMG"
