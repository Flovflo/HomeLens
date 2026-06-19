#!/usr/bin/env bash
# Build a clean, self-contained HomeLens.dmg.
# The .app already embeds ffmpeg, ffprobe, node and all dependencies
# (see package_app.sh → bundle_portable.py), so the DMG is the *only* thing a
# user needs — nothing to install separately.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/HomeLens.app"
DMG="$ROOT/dist/HomeLens.dmg"
VOL="HomeLens"

if [ ! -d "$APP" ]; then
  echo "error: $APP not found. Run ./script/package_app.sh first." >&2
  exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# ditto preserves the code signature and extended attributes.
ditto "$APP" "$STAGE/HomeLens.app"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/À LIRE — Première ouverture.txt" <<'TXT'
HomeLens — installation
=======================

1. Glissez « HomeLens » sur le dossier « Applications ».

2. Première ouverture (une seule fois) :
   L'app n'est pas signée par un développeur identifié Apple, donc macOS
   demande une confirmation au premier lancement.
   → Faites un CLIC DROIT sur HomeLens dans Applications, puis « Ouvrir ».
   → Cliquez « Ouvrir » dans la fenêtre qui apparaît.

   (Variante en Terminal, si besoin :
      xattr -dr com.apple.quarantine /Applications/HomeLens.app )

Tout est inclus
===============
ffmpeg, ffprobe et Node.js sont DÉJÀ à l'intérieur de l'app — il n'y a
RIEN d'autre à installer. Aucune dépendance Homebrew n'est requise.

Ensuite
=======
Ouvrez HomeLens, allez dans l'onglet « Réglages » pour saisir l'adresse et
le mot de passe de votre caméra, puis appairez la caméra dans l'app Maison
(Ajouter un accessoire → code affiché par HomeLens).
TXT

rm -f "$DMG"
hdiutil create \
  -volname "$VOL" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  "$DMG"

SIZE="$(du -sh "$DMG" | cut -f1)"
echo "Created $DMG ($SIZE)"
