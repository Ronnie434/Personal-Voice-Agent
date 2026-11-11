#!/bin/bash
# Build Friday.app for this Mac: release build, bundle, local signature.
#   app/build-app.sh            -> build/Friday.app
#   app/build-app.sh --install  -> also copies it to /Applications
# The app runs the engine from this checkout (Settings > Advanced can change that).
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd .. && pwd)
APP="$ROOT/build/Friday.app"
VERSION=$(sed -n 's/^__version__ = "\(.*\)"/\1/p' "$ROOT/engine/friday_engine/__init__.py")

swift build -c release 2>&1 | grep -E "error|warning: unre|Compiling|Build complete" || true
BIN=$(swift build -c release --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Friday" "$APP/Contents/MacOS/Friday"
cp Sources/FridayUI/Resources/*.ttf Sources/FridayUI/Resources/OFL.txt "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.ronnie434.Friday</string>
  <key>CFBundleName</key><string>Friday</string>
  <key>CFBundleDisplayName</key><string>Friday</string>
  <key>CFBundleExecutable</key><string>Friday</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Friday listens for its name so you can talk to it hands-free.</string>
  <key>NSAppleEventsUsageDescription</key><string>Friday controls apps on your Mac when you ask it to.</string>
  <key>FridayEngineDirectory</key><string>${ROOT}</string>
</dict></plist>
PLIST

# A stable signature, so macOS remembers the microphone permission across rebuilds.
IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)
codesign --force --sign "${IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP ($VERSION), signed with ${IDENTITY:-an ad-hoc signature}"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/Friday.app
  cp -R "$APP" /Applications/Friday.app
  echo "Installed /Applications/Friday.app"
fi
