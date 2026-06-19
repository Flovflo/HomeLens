#!/usr/bin/env bash
set -euo pipefail

# Auto-launches the visible HomeLens app (Dock + menu-bar icon) at login, so you
# can always see/monitor the bridge. This is separate from the headless bridge
# agent (com.flo.HomeLens) — the bridge runs HomeKit; this just shows the UI.
# RunAtLoad + no KeepAlive => `open` runs once at login (no respawn loop).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/HomeLens.app"
LABEL="com.flo.HomeLens.ui"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/HomeLens"

if [[ ! -d "$APP" ]]; then
  echo "HomeLens.app missing. Run ./script/package_app.sh first." >&2
  exit 1
fi

mkdir -p "$(dirname "$PLIST")" "$LOG_DIR"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>$APP</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/ui.out.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/ui.err.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart "gui/$(id -u)/$LABEL"

echo "Installed UI auto-launch agent $LABEL"
echo "$PLIST"
