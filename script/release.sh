#!/usr/bin/env bash
# One command to cut a public release:
#   build -> Developer ID sign + notarize + staple the app -> build DMG ->
#   sign + notarize + staple the DMG -> create a GitHub Release with the DMG.
#
# Prereqs (one-time): a "Developer ID Application" cert in the Keychain and
# notary credentials stored via ./script/setup_notary.sh. See docs/RELEASING.md.
#
# Usage:
#   ./script/release.sh v0.1.0
set -euo pipefail
export LANG="${LANG:-en_US.UTF-8}"

VERSION="${1:?usage: release.sh vX.Y.Z}"
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must look like v0.1.0"; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
APP="$ROOT/dist/HomeLens.app"
DMG="$ROOT/dist/HomeLens.dmg"
PROFILE="${NOTARY_PROFILE:-homelens-notary}"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
[[ -n "$IDENTITY" ]] || { echo "No 'Developer ID Application' identity. See docs/RELEASING.md"; exit 1; }
command -v gh >/dev/null || { echo "gh CLI required"; exit 1; }

echo "==> [1/5] Building the self-contained app"
./script/package_app.sh

echo "==> [2/5] Signing + notarizing + stapling the app"
NOTARY_PROFILE="$PROFILE" SIGN_IDENTITY="$IDENTITY" ./script/sign_and_notarize.sh "$APP"

echo "==> [3/5] Building the DMG (from the signed app)"
./script/make_dmg.sh

echo "==> [4/5] Signing + notarizing + stapling the DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" || true

echo "==> [5/5] Creating GitHub release $VERSION"
NOTES="$(mktemp)"
cat > "$NOTES" <<EOF
## HomeLens $VERSION

Mettez votre caméra **Reolink** dans l'app **Maison** d'Apple — vidéo en direct avec audio + **HomeKit Secure Video**, jusqu'à la 4K.

### Installation
1. Téléchargez **HomeLens.dmg** ci-dessous.
2. Glissez **HomeLens** dans **Applications**, puis ouvrez l'app (double-clic — signée et notarisée par Apple, aucun avertissement).
3. Suivez l'assistant : entrez l'adresse + le mot de passe de votre caméra, et appairez dans l'app Maison.

**Tout est inclus** (ffmpeg + Node.js) — rien d'autre à installer. macOS 14+ Apple Silicon.
EOF

if gh release view "$VERSION" >/dev/null 2>&1; then
  gh release upload "$VERSION" "$DMG" --clobber
else
  gh release create "$VERSION" "$DMG" --target main --title "HomeLens $VERSION" --notes-file "$NOTES"
fi
rm -f "$NOTES"

echo
echo "OK: released $VERSION"
gh release view "$VERSION" --web >/dev/null 2>&1 || true
