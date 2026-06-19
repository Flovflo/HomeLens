#!/usr/bin/env bash
# Clean install on THIS Mac, straight from the self-contained DMG.
#
# Mounts dist/HomeLens.dmg, copies HomeLens.app into /Applications (exact byte
# copy, so the ad-hoc signature -- and your camera-password Keychain ACL --
# carry over), then points the two launchd agents at the installed app:
#   - com.flo.HomeLens     : the 24/7 HomeKit bridge (KeepAlive)
#   - com.flo.HomeLens.ui  : auto-opens the monitor app at login
#
# Your camera config, Keychain password and HomeKit pairing are NOT touched.
set -euo pipefail
export LANG="${LANG:-en_US.UTF-8}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DMG="$ROOT/dist/HomeLens.dmg"
DEST="/Applications/HomeLens.app"
VOL="/Volumes/HomeLens"
UID_="$(id -u)"

if [[ ! -f "$DMG" ]]; then
  echo "DMG not found. Build it first:" >&2
  echo "  ./script/package_app.sh && ./script/make_dmg.sh" >&2
  exit 1
fi

echo "[1/4] Stopping any running HomeLens (bridge, helper, UI)..."
for L in com.flo.HomeLens com.flo.HomeLens.ui; do
  launchctl bootout "gui/${UID_}" "$HOME/Library/LaunchAgents/${L}.plist" 2>/dev/null || true
done
osascript -e 'quit app "HomeLens"' 2>/dev/null || true
pkill -f "HomeKitBridge/src/index.mjs" 2>/dev/null || true
pkill -f "homelensctl homekit-run" 2>/dev/null || true
sleep 1

echo "[2/4] Mounting ${DMG} ..."
hdiutil detach "$VOL" >/dev/null 2>&1 || true
hdiutil attach "$DMG" -nobrowse -readonly >/dev/null

echo "[3/4] Installing ${DEST} ..."
rm -rf "$DEST"
ditto "${VOL}/HomeLens.app" "$DEST"
hdiutil detach "$VOL" >/dev/null
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "[4/4] Pointing launchd agents at the installed app..."
HOMELENS_APP="$DEST" "${ROOT}/script/install_bridge_agent.sh"
HOMELENS_APP="$DEST" "${ROOT}/script/install_ui_login.sh"

echo
echo "OK: installed to ${DEST} -- bridge + UI now run from /Applications."
echo "The repo folder is no longer required at runtime."
