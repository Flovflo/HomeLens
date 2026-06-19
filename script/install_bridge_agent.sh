#!/usr/bin/env bash
set -euo pipefail

# Runs the HomeKit bridge (homelensctl homekit-run) as a KeepAlive launch agent.
# This is the reliability boundary: the bridge runs 24/7 independently of the GUI,
# which is only a monitor/preview/diagnostics surface.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/HomeLens.app"
CTL="$APP/Contents/MacOS/homelensctl"
HELPER="$APP/Contents/Resources/Helpers/HomeKitBridge/src/index.mjs"
LABEL="com.flo.HomeLens"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/HomeLens"

if [[ ! -x "$CTL" ]]; then
  echo "homelensctl missing. Run ./script/package_app.sh first." >&2
  exit 1
fi
if [[ ! -f "$HELPER" ]]; then
  echo "HAP helper missing in bundle. Run ./script/package_app.sh first." >&2
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
        <string>$CTL</string>
        <string>homekit-run</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$ROOT</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>HOMELENS_HOMEKIT_HELPER</key>
        <string>$HELPER</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/bridge.out.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/bridge.err.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl enable "gui/$(id -u)/$LABEL"
launchctl kickstart -k "gui/$(id -u)/$LABEL"

echo "Installed and started bridge agent $LABEL"
echo "$PLIST"
