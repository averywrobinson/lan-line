#!/bin/bash
# Build the Mac download: dist/Lan-Line-<version>-mac.dmg (Lan-Line.app + an Applications shortcut to drag onto),
# with a background and window layout (tools/dmg-settings.py) written by dmgbuild, so no Finder scripting.
# Universal (Apple Silicon + Intel), macOS 13+. Signed with the Developer ID Application certificate in the
# login Keychain (found by name, so no personal details live here), then notarized by Apple and stapled: the app
# first (so a copy dragged out of the DMG, or installed by Homebrew, carries its own ticket), then the DMG.
# Notarization reads the notarytool profile "lan-line-notary" (NOTARY=… for another):
#   xcrun notarytool store-credentials lan-line-notary --apple-id <Apple ID> --team-id <Team ID>
# NOTARIZE=0 signs without notarizing (trial builds only: Gatekeeper still blocks it).
# UNSIGNED=1 builds ad-hoc, as before beta.11 (first open needs Privacy & Security > Open Anyway).
# One-time setup (pinned, hash-checked; needs Python 3.10+):
#   python3.12 -m venv .venv-dmg && .venv-dmg/bin/pip install --only-binary=:all: --require-hashes -r tools/dmg-requirements.txt
# OUT=/path/test.dmg ./package.sh builds somewhere else (e.g. a trial build that must not replace a released DMG).
set -euo pipefail
cd "$(dirname "$0")"
DMGBUILD=".venv-dmg/bin/dmgbuild"
[ -x "$DMGBUILD" ] || { echo "missing $DMGBUILD: see the setup line at the top of package.sh" >&2; exit 1; }
FULL="$(cat ../VERSION)"
NOTARY="${NOTARY:-lan-line-notary}"
if [ "${UNSIGNED:-0}" = 1 ]; then
  DEV_ID=""
else
  DEV_ID="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
  [ -n "$DEV_ID" ] || { echo "no Developer ID Application identity in the Keychain (UNSIGNED=1 for an ad-hoc build)" >&2; exit 1; }
  if [ "${NOTARIZE:-1}" = 1 ] && ! xcrun notarytool history --keychain-profile "$NOTARY" >/dev/null 2>&1; then
    echo "notarytool profile \"$NOTARY\" missing or not working: see the store-credentials line at the top of package.sh" >&2; exit 1
  fi
fi
# Send one file to Apple, wait, and stop with Apple's log unless it was accepted.
notarize() {
  local f="$1" json
  json="$(xcrun notarytool submit "$f" --keychain-profile "$NOTARY" --wait --output-format json)" || true
  local id status
  id="$(printf '%s' "$json" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"
  status="$(printf '%s' "$json" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' 2>/dev/null || true)"
  if [ "$status" != "Accepted" ]; then
    echo "notarization of $(basename "$f"): ${status:-no answer}" >&2
    [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$NOTARY" >&2 || true
    exit 1
  fi
  echo "notarized $(basename "$f") ($id)"
}
SIGN_ID="$DEV_ID" ./build-app.sh --no-install
APP_BUILT="$PWD/.build/Lan-Line.app"
OUT="${OUT:-../dist/Lan-Line-${FULL}-mac.dmg}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$(dirname "$OUT")"
if [ -n "$DEV_ID" ] && [ "${NOTARIZE:-1}" = 1 ]; then
  ditto -c -k --keepParent "$APP_BUILT" "$WORK/Lan-Line.zip"
  notarize "$WORK/Lan-Line.zip"
  xcrun stapler staple -q "$APP_BUILT"
  spctl --assess --type execute "$APP_BUILT" || { echo "Gatekeeper rejects the notarized app" >&2; exit 1; }
fi
swift tools/make-dmg-background.swift "$WORK" >/dev/null
tiffutil -cathidpicheck "$WORK/bg.png" "$WORK/bg@2x.png" -out "$WORK/bg.tiff" >/dev/null
rm -f "$OUT"
"$DMGBUILD" -s tools/dmg-settings.py -D app="$PWD/.build/Lan-Line.app" -D background="$WORK/bg.tiff" "Lan-Line" "$OUT" >/dev/null
hdiutil verify "$OUT" >/dev/null
if [ -n "$DEV_ID" ]; then
  codesign --force --sign "$DEV_ID" --timestamp "$OUT"
  if [ "${NOTARIZE:-1}" = 1 ]; then
    notarize "$OUT"
    xcrun stapler staple -q "$OUT"
    spctl --assess --type open --context context:primary-signature "$OUT" || { echo "Gatekeeper rejects the notarized DMG" >&2; exit 1; }
  fi
fi
echo "built $OUT ($(du -h "$OUT" | cut -f1); $([ -z "$DEV_ID" ] && echo ad-hoc || { [ "${NOTARIZE:-1}" = 1 ] && echo "signed, notarized" || echo "signed, not notarized"; })), sha256 $(shasum -a 256 "$OUT" | cut -d' ' -f1)"
