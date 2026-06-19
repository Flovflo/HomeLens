#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/HomeLens.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

cd "$ROOT"
swift build -c release --product HomeLens
swift build -c release --product homelensctl

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

cp "$ROOT/.build/release/HomeLens" "$MACOS/HomeLens"
cp "$ROOT/.build/release/homelensctl" "$MACOS/homelensctl"
cp "$ROOT/Assets/HomeLens.icns" "$RESOURCES/HomeLens.icns"

mkdir -p "$RESOURCES/Helpers"
rsync -a "$ROOT/Helpers/HomeKitBridge" "$RESOURCES/Helpers/"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>HomeLens</string>
    <key>CFBundleIconFile</key>
    <string>HomeLens</string>
    <key>CFBundleIdentifier</key>
    <string>com.flo.HomeLens</string>
    <key>CFBundleName</key>
    <string>HomeLens</string>
    <key>CFBundleDisplayName</key>
    <string>HomeLens</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST

chmod +x "$MACOS/HomeLens" "$MACOS/homelensctl"

# Bundle ffmpeg/ffprobe/node + their dylibs so the app runs with nothing
# installed (rewrites install names to @rpath, ad-hoc re-signs the bundled bins).
python3 "$ROOT/script/bundle_portable.py" "$APP"

# Ad-hoc sign inside-out so the sealed bundle is internally consistent. There is
# no Developer ID here, so Gatekeeper still quarantines on first download — the
# DMG README explains the one-time right-click→Open / xattr step.
codesign --force --sign - "$MACOS/homelensctl"
codesign --force --sign - "$MACOS/HomeLens"
codesign --force --sign - "$APP"

SIZE="$(du -sh "$APP" | cut -f1)"
echo "Built self-contained $APP ($SIZE)"
