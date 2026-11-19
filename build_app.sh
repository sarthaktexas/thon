#!/bin/bash
# Build Thon.app (release) next to this script.
#   ./build_app.sh             build
#   ./build_app.sh --install   build, then copy to /Applications
# Environment:
#   THON_VERSION   marketing version to stamp (e.g. 1.1.0). Build number = git commit count.
#                  Unset = keep what Resources/Info.plist says.
#   CODESIGN_IDENTITY   signing identity (default "-" = ad hoc). A Developer ID identity also
#                  turns on the hardened runtime, which notarization needs.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="$BIN_DIR/Thon"
APP="Thon.app"
ID="${CODESIGN_IDENTITY:--}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Thon"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
mkdir -p "$APP/Contents/Resources/pickers" && cp Resources/pickers/*.py "$APP/Contents/Resources/pickers/"

# Sparkle (self-update). SwiftPM leaves the framework next to the binary or in .build/artifacts.
SPARKLE="$BIN_DIR/Sparkle.framework"
if [[ ! -d "$SPARKLE" ]]; then
  SPARKLE="$(find .build/artifacts -type d -name Sparkle.framework -path '*macos*' | head -1)"
fi
[[ -d "$SPARKLE" ]] || { echo "Sparkle.framework not found; run: swift package resolve" >&2; exit 1; }
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
# Thon is not sandboxed, so Sparkle's XPC services are not needed.
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
       "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
# The binary looks for frameworks beside itself; SwiftPM only sets a build-folder rpath.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Thon"

# Version stamp
if [[ -n "${THON_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $THON_VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD)" "$APP/Contents/Info.plist"
fi

# Sign inside out (no --deep): Sparkle's helpers, the framework, then the app.
OPTS=(--force --sign "$ID")
[[ "$ID" != "-" ]] && OPTS+=(--options runtime --timestamp)
FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign "${OPTS[@]}" "$FW/Autoupdate"
codesign "${OPTS[@]}" "$FW/Updater.app"
codesign "${OPTS[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
codesign "${OPTS[@]}" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $PWD/$APP ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist") build $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist"))"
if [[ "${1:-}" == "--install" ]]; then
  rm -rf "/Applications/$APP" && cp -R "$APP" /Applications/ && echo "Installed to /Applications/$APP"
fi
