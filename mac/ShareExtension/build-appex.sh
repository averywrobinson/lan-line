#!/bin/bash
# Build LanLineShare.appex (universal, sandboxed; signed with $SIGN_ID, ad-hoc if unset) into "$1/Contents/PlugIns/". Called by build-app.sh.
set -euo pipefail
cd "$(dirname "$0")"
APP="$1"; VERSION="$2"; BUILD="$3"
X="$APP/Contents/PlugIns/LanLineShare.appex"
rm -rf "$X"; mkdir -p "$X/Contents/MacOS"
T=$(mktemp -d)
for a in arm64 x86_64; do
  swiftc -O -target $a-apple-macos13.0 -application-extension -module-name LanLineShare ShareViewController.swift \
    -Xlinker -e -Xlinker _NSExtensionMain -o "$T/$a" 2>&1 | grep -v "^$" || true
done
lipo -create "$T/arm64" "$T/x86_64" -output "$X/Contents/MacOS/LanLineShare"
rm -rf "$T"
strip -S -x "$X/Contents/MacOS/LanLineShare"
cat > "$X/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.avery.lan-line.share</string>
  <key>CFBundleName</key><string>Lan-Line</string>
  <key>CFBundleDisplayName</key><string>Lan-Line</string>
  <key>CFBundleExecutable</key><string>LanLineShare</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSExtension</key><dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.share-services</string>
    <key>NSExtensionPrincipalClass</key><string>ShareViewController</string>
    <key>NSExtensionAttributes</key><dict>
      <key>NSExtensionActivationRule</key>
      <string>SUBQUERY(extensionItems, \$e, SUBQUERY(\$e.attachments, \$a, ANY \$a.registeredTypeIdentifiers UTI-CONFORMS-TO "public.item").@count >= 1).@count >= 1</string>
    </dict>
  </dict>
</dict></plist>
PLIST
ID="${SIGN_ID:--}"; OPTS=()
case "$ID" in "Developer ID Application:"*) OPTS=(--options runtime --timestamp) ;; esac
codesign --force --sign "$ID" "${OPTS[@]+"${OPTS[@]}"}" --entitlements Entitlements.plist --identifier com.avery.lan-line.share "$X"
