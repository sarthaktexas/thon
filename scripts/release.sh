#!/bin/bash
# Package a release: Thon-<version>.dmg + appcast.xml (the Sparkle feed), ready for GitHub Releases.
#   scripts/release.sh 1.1.0            build the DMG and appcast.xml into dist/
#   scripts/release.sh 1.1.0 --publish  also tag, push the tag and create the GitHub release (needs gh)
# One-time setup: scripts/sparkle_keys.sh
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: scripts/release.sh <version> [--publish]}"
TAG="v$VERSION"
REPO="sarthaktexas/thon"
DIST="dist"

KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Resources/Info.plist)"
[[ -n "$KEY" ]] || { echo "Resources/Info.plist has an empty SUPublicEDKey. Run scripts/sparkle_keys.sh first." >&2; exit 1; }

THON_VERSION="$VERSION" ./build_app.sh
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Thon.app/Contents/Info.plist)"

SIGN="$(find .build/artifacts -type f -name sign_update | head -1)"
[[ -x "$SIGN" ]] || { echo "sign_update not found under .build/artifacts" >&2; exit 1; }

mkdir -p "$DIST" && rm -rf "$DIST/dmg" && mkdir -p "$DIST/dmg"
DMG="$DIST/Thon-$VERSION.dmg"
ditto Thon.app "$DIST/dmg/Thon.app"
ln -s /Applications "$DIST/dmg/Applications"
rm -f "$DMG"
hdiutil create -volname "Thon" -srcfolder "$DIST/dmg" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$DIST/dmg"

# sign_update prints:  sparkle:edSignature="..." length="..."   (private key is read from the login Keychain)
SIGLINE="$("$SIGN" "$DMG")"
URL="https://github.com/$REPO/releases/download/$TAG/Thon-$VERSION.dmg"
cat > "$DIST/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Thon</title>
    <item>
      <title>Thon $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/$REPO/releases/tag/$TAG</sparkle:releaseNotesLink>
      <enclosure url="$URL" type="application/octet-stream" $SIGLINE />
    </item>
  </channel>
</rss>
XML
echo "Wrote $DMG and $DIST/appcast.xml (version $VERSION, build $BUILD)"

if [[ "${2:-}" == "--publish" ]]; then
  command -v gh >/dev/null || { echo "gh not installed; upload $DMG and $DIST/appcast.xml to release $TAG by hand." >&2; exit 1; }
  git tag "$TAG" && git push origin "$TAG"
  gh release create "$TAG" "$DMG" "$DIST/appcast.xml" --title "Thon $VERSION" --generate-notes
else
  echo "Next: create GitHub release $TAG and attach both files, or rerun with --publish."
fi
