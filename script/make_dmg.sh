#!/usr/bin/env bash
# Build a clean, self-contained HomeLens.dmg with a designed Finder window:
# background, icon positions, window size (no Finder scripting: dmgbuild writes
# the .DS_Store directly, so this runs headless and reproducibly).
# The .app already embeds ffmpeg, ffprobe, node and all dependencies
# (see package_app.sh → bundle_portable.py), so the DMG is the *only* thing a
# user needs — nothing to install separately.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/HomeLens.app"
DMG="$ROOT/dist/HomeLens.dmg"
BACKGROUND="$ROOT/Assets/Generated/dmg-background.tiff"
VENV="$ROOT/.build/dmgbuild-venv"

if [ ! -d "$APP" ]; then
  echo "error: $APP not found. Run ./script/package_app.sh first." >&2
  exit 1
fi
if [ ! -f "$BACKGROUND" ]; then
  echo "error: $BACKGROUND missing. Run ./script/make_icon.sh first." >&2
  exit 1
fi
if [ ! -x "$VENV/bin/dmgbuild" ]; then
  echo "==> Installing dmgbuild into $VENV (one-time)"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q dmgbuild
fi

SETTINGS="$(mktemp -t homelens-dmg).py"
trap 'rm -f "$SETTINGS"' EXIT
cat > "$SETTINGS" <<PY
# dmgbuild settings — window 660x400, app left, Applications right (see make_icon.swift).
format = "UDZO"
compression_level = 9
filesystem = "HFS+"
files = ["$APP"]
symlinks = {"Applications": "/Applications"}
icon = "$ROOT/Assets/HomeLens.icns"
background = "$BACKGROUND"
window_rect = ((200, 160), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
sidebar_width = 0
icon_size = 128
text_size = 13
arrange_by = None
grid_offset = (0, 0)
show_icon_preview = False
icon_locations = {"HomeLens.app": (170, 215), "Applications": (490, 215)}
PY

rm -f "$DMG"
"$VENV/bin/dmgbuild" -s "$SETTINGS" "HomeLens" "$DMG"
echo "OK: $DMG ($(du -h "$DMG" | cut -f1))"
