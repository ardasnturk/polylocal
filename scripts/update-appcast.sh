#!/usr/bin/env bash
# Adds a release to appcast.xml, the Sparkle update feed the app reads from the main branch.
# Run after scripts/make-dmg.sh has built and notarized the DMG, then commit appcast.xml
# once the GitHub release with that DMG is published (the feed points at the release asset).
#
#   VERSION=0.2.0 scripts/update-appcast.sh
#
# The DMG is signed with the EdDSA key stored in the login keychain under the account "polylocal"
# (created once with: .build/artifacts/sparkle/Sparkle/bin/generate_keys --account polylocal).
# Its public half is SUPublicEDKey in scripts/build-app.sh; losing the private key means
# existing installs can no longer verify updates.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:?set VERSION, e.g. VERSION=0.2.0}"
DMG="$ROOT/build/Polylocal-$VERSION.dmg"
APP="$ROOT/build/Polylocal.app"
SIGN_UPDATE="$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update"

[ -f "$DMG" ] || { echo "error: $DMG missing; run scripts/make-dmg.sh" >&2; exit 1; }
[ -x "$SIGN_UPDATE" ] || { echo "error: Sparkle tools missing; run swift package resolve" >&2; exit 1; }

BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[ "$APP_VERSION" = "$VERSION" ] || { echo "error: build/Polylocal.app is $APP_VERSION, not $VERSION" >&2; exit 1; }

# Prints: sparkle:edSignature="…" length="…"
SIGNATURE="$("$SIGN_UPDATE" --account polylocal "$DMG")"

python3 -I - "$ROOT/appcast.xml" "$VERSION" "$BUILD_NUMBER" "$SIGNATURE" <<'PY'
import email.utils, re, sys
path, version, build, signature = sys.argv[1:]
url = f"https://github.com/ardasnturk/polylocal/releases/download/v{version}/Polylocal-{version}.dmg"
item = f"""    <item>
      <title>Polylocal {version}</title>
      <pubDate>{email.utils.formatdate(localtime=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/ardasnturk/polylocal/releases/tag/v{version}</sparkle:releaseNotesLink>
      <enclosure url="{url}" type="application/x-apple-diskimage" {signature}/>
    </item>
"""
try:
    feed = open(path).read()
except FileNotFoundError:
    feed = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Polylocal</title>
    <link>https://github.com/ardasnturk/polylocal</link>
    <!-- Newest first. Written by scripts/update-appcast.sh. -->
  </channel>
</rss>
"""
# Replace an existing entry for this version, then insert the new one first.
feed = re.sub(rf"    <item>\n      <title>Polylocal {re.escape(version)}</title>.*?</item>\n", "", feed, flags=re.S)
marker = "    <!-- Newest first. Written by scripts/update-appcast.sh. -->\n"
feed = feed.replace(marker, marker + item, 1)
open(path, "w").write(feed)
PY
echo "Updated $ROOT/appcast.xml for $VERSION (build $BUILD_NUMBER)"
