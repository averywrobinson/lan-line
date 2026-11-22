#!/bin/bash
# Build the Mac download: dist/Lan-Line-<version>-mac.dmg (Lan-Line.app + an Applications shortcut to drag onto),
# with a background and window layout (tools/dmg-settings.py) written by dmgbuild, so no Finder scripting.
# Universal (Apple Silicon + Intel), macOS 13+, ad-hoc signed (not notarized): first open needs
# System Settings > Privacy & Security > Open Anyway.
# One-time setup (pinned, hash-checked; needs Python 3.10+):
#   python3.12 -m venv .venv-dmg && .venv-dmg/bin/pip install --only-binary=:all: --require-hashes -r tools/dmg-requirements.txt
# OUT=/path/test.dmg ./package.sh builds somewhere else (e.g. a trial build that must not replace a released DMG).
set -euo pipefail
cd "$(dirname "$0")"
DMGBUILD=".venv-dmg/bin/dmgbuild"
[ -x "$DMGBUILD" ] || { echo "missing $DMGBUILD: see the setup line at the top of package.sh" >&2; exit 1; }
./build-app.sh --no-install
FULL="$(cat ../VERSION)"
OUT="${OUT:-../dist/Lan-Line-${FULL}-mac.dmg}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$(dirname "$OUT")"
swift tools/make-dmg-background.swift "$WORK" >/dev/null
tiffutil -cathidpicheck "$WORK/bg.png" "$WORK/bg@2x.png" -out "$WORK/bg.tiff" >/dev/null
rm -f "$OUT"
"$DMGBUILD" -s tools/dmg-settings.py -D app="$PWD/.build/Lan-Line.app" -D background="$WORK/bg.tiff" "Lan-Line" "$OUT" >/dev/null
hdiutil verify "$OUT" >/dev/null
echo "built $OUT ($(du -h "$OUT" | cut -f1)), sha256 $(shasum -a 256 "$OUT" | cut -d' ' -f1)"
