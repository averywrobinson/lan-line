#!/bin/bash
# Build the Mac download: dist/Lan-Line-<version>-mac.dmg (Lan-Line.app + an Applications shortcut to drag onto).
# Apple Silicon only, ad-hoc signed (not notarized): first open needs right-click > Open, or
# System Settings > Privacy & Security > Open Anyway.
set -euo pipefail
cd "$(dirname "$0")"
./build-app.sh --no-install
FULL="$(cat ../VERSION)"
OUT="../dist/Lan-Line-${FULL}-mac.dmg"
STAGE="$(mktemp -d)/Lan-Line"
mkdir -p "$STAGE" ../dist
ditto .build/Lan-Line.app "$STAGE/Lan-Line.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT"
hdiutil create -volname "Lan-Line" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$OUT" >/dev/null
hdiutil verify "$OUT" >/dev/null
echo "built $OUT ($(du -h "$OUT" | cut -f1)), sha256 $(shasum -a 256 "$OUT" | cut -d' ' -f1)"
