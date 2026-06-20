#!/usr/bin/env bash
# Developer ID sign (hardened runtime) + notarize + staple a .app.
#
# Prereqs (one-time):
#   1. A "Developer ID Application" certificate in your login Keychain
#      (see docs/RELEASING.md).
#   2. Notary credentials stored as a keychain profile:
#      ./script/setup_notary.sh            # creates profile "homelens-notary"
#
# Usage:
#   ./script/sign_and_notarize.sh dist/HomeLens.app
#
# Overrides via env: SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"
#                    NOTARY_PROFILE=homelens-notary
set -euo pipefail
export LANG="${LANG:-en_US.UTF-8}"

APP="${1:?usage: sign_and_notarize.sh <path-to-.app>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENT="$ROOT/script/entitlements/helper.entitlements"
PROFILE="${NOTARY_PROFILE:-homelens-notary}"

IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')"
fi
if [[ -z "$IDENTITY" ]]; then
  echo "error: no 'Developer ID Application' identity found in the Keychain." >&2
  echo "       Create one (docs/RELEASING.md) or set SIGN_IDENTITY=..." >&2
  exit 1
fi
echo "Signing identity: $IDENTITY"
[[ -d "$APP" ]] || { echo "error: $APP not found (run ./script/package_app.sh)"; exit 1; }

CTL="$APP/Contents/MacOS/homelensctl"
MAIN="$APP/Contents/MacOS/HomeLens"

sign() { codesign --force --timestamp --options runtime "$@"; }

echo "[1/4] Signing nested Mach-O binaries (dylibs, node, ffmpeg, native addons)..."
# Every Mach-O inside the bundle must be signed, inside-out. node/ffmpeg/.node
# need the JIT/library-validation relaxations; sign them all with the helper
# entitlements (harmless for plain dylibs, required for the JIT ones).
find "$APP/Contents/Resources" -type f -print0 \
  | while IFS= read -r -d '' f; do
      if file -b "$f" | grep -q "Mach-O"; then
        sign --entitlements "$ENT" --sign "$IDENTITY" "$f"
      fi
    done

echo "[2/4] Signing homelensctl + main executable..."
[[ -f "$CTL" ]] && sign --sign "$IDENTITY" "$CTL"
sign --sign "$IDENTITY" "$MAIN"

echo "[3/4] Sealing the app bundle..."
sign --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "[4/4] Notarizing (this can take a few minutes)..."
ZIP="${APP%.app}-notarize.zip"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
rm -f "$ZIP"

xcrun stapler staple "$APP"
echo "OK: $APP is Developer ID signed, notarized and stapled."
spctl --assess --type execute --verbose=2 "$APP" || true
