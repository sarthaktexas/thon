#!/bin/bash
# Build Thon.app (release) next to this script.
#   ./build_app.sh             build
#   ./build_app.sh --install   build, then copy to /Applications
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Thon"
APP="Thon.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Thon"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP"
echo "Built $PWD/$APP"
if [[ "${1:-}" == "--install" ]]; then
  rm -rf "/Applications/$APP" && cp -R "$APP" /Applications/ && echo "Installed to /Applications/$APP"
fi
