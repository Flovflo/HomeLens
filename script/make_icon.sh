#!/usr/bin/env bash
# Render the app icon + DMG background (SwiftUI, see make_icon.swift), then build
# Assets/AppIcon.iconset and Assets/HomeLens.icns from the 1024 px master.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
swift script/make_icon.swift "$ROOT"
MASTER="Assets/Generated/HomeLensIcon.png"
SET="Assets/AppIcon.iconset"
rm -rf "$SET"; mkdir -p "$SET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$MASTER" --out "$SET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$MASTER" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Assets/HomeLens.icns
# Retina-aware DMG background: Finder picks the 2x representation on HiDPI displays.
tiffutil -cathidpicheck Assets/Generated/dmg-background.png Assets/Generated/dmg-background@2x.png \
  -out Assets/Generated/dmg-background.tiff >/dev/null
echo "OK: Assets/HomeLens.icns + Assets/Generated/dmg-background.tiff"
