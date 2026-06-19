#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="com.flo.HomeLens"
SUPPORT="$HOME/Library/Application Support/HomeLens"
STORAGE="$SUPPORT/hap-storage"
CONFIG="$SUPPORT/homekit-bridge.json"
USERNAME="$SUPPORT/homekit-username.txt"
BACKUP_ROOT="$SUPPORT/backups"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BACKUP_ROOT/homekit-reset-$STAMP"

mkdir -p "$BACKUP"

launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/$LABEL.plist" 2>/dev/null || true

while read -r pid command; do
  [[ -z "${pid:-}" ]] && continue
  case "$command" in
    *"/homelensctl homekit-run"*|*"node "*"HomeKitBridge/src/index.mjs"*|*"/ffmpeg "*"h264Preview_01"*)
      kill "$pid" 2>/dev/null || true
      ;;
  esac
done < <(ps -axo pid=,command=)

sleep 1

while read -r pid command; do
  [[ -z "${pid:-}" ]] && continue
  case "$command" in
    *"/homelensctl homekit-run"*|*"node "*"HomeKitBridge/src/index.mjs"*|*"/ffmpeg "*"h264Preview_01"*)
      kill -9 "$pid" 2>/dev/null || true
      ;;
  esac
done < <(ps -axo pid=,command=)

if [[ -d "$STORAGE" ]]; then
  mv "$STORAGE" "$BACKUP/hap-storage"
fi
if [[ -f "$CONFIG" ]]; then
  mv "$CONFIG" "$BACKUP/homekit-bridge.json"
fi
if [[ -f "$USERNAME" ]]; then
  mv "$USERNAME" "$BACKUP/homekit-username.txt"
fi

"$ROOT/script/install_launch_agent.sh"

echo "HomeKit pairing reset complete."
echo "Backup: $BACKUP"
echo "Now remove the old HomeLens/Front Door accessory from Apple Home, then add it again with PIN 031-45-154."
