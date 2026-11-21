#!/bin/bash
# Build Lan-Line.app (release), sign it, install to ~/Applications/Lan-Line.app.
# Signs with the "Lan-Line Dev" identity if it exists (keeps the firewall allow across rebuilds), else ad-hoc.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release -Xswiftc -warnings-as-errors 2>&1 | tail -3
BIN="$(swift build -c release --show-bin-path)/LanLine"
APP=".build/Lan-Line.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Lan-Line"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
FULL="$(cat ../VERSION)"                       # e.g. 0.9.0-beta.1
VERSION="${FULL%%-*}"                          # 0.9.0
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.avery.lan-line</string>
  <key>CFBundleName</key><string>Lan-Line</string>
  <key>CFBundleDisplayName</key><string>Lan-Line</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHumanReadableCopyright</key><string>Lan-Line ${FULL}. Drop here. Grab there. MIT License.</string>
  <key>CFBundleExecutable</key><string>Lan-Line</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>LanLineVersion</key><string>${FULL}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Lan-Line Dev"'; then
  ID="Lan-Line Dev"
else
  ID="-"
fi
codesign --force --sign "$ID" --identifier com.avery.lan-line "$APP"
codesign --verify "$APP"
[ "${1:-}" = "--no-install" ] && { echo "built $APP ($FULL)"; exit 0; }
mkdir -p "$HOME/Applications"
# ditto overwrites in place, so the existing install is replaced without deleting it first
ditto "$APP" "$HOME/Applications/Lan-Line.app"
echo "installed $HOME/Applications/Lan-Line.app ($FULL build $BUILD, signed: $ID)"
