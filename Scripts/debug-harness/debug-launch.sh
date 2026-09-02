#!/bin/zsh
# Build a scratch .app bundle around .build/release/Sidekick and launch it via
# LaunchServices with the debug harness flags. Usage: debug-launch.sh <notes-folder> [port]
set -e
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
S=${TMPDIR:-/tmp}/sidekick-debug; mkdir -p "$S"
NOTES=$1; PORT=${2:-4567}
APP=$S/SidekickDebug.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$REPO/.build/release/Sidekick" "$APP/Contents/MacOS/Sidekick"
cp -R "$REPO"/.build/release/*.bundle "$APP/Contents/Resources/" 2>/dev/null || true
cp "$REPO/Resources/AppIcon.icns" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.oguzoral.SidekickDebug</string>
<key>CFBundleName</key><string>SidekickDebug</string>
<key>CFBundleExecutable</key><string>Sidekick</string>
<key>CFBundleVersion</key><string>1.0</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
codesign --deep --force --sign - "$APP" 2>/dev/null || true
pkill -x Sidekick 2>/dev/null || true; sleep 1
open -n "$APP" --args --debug-port "$PORT" --debug-notes-folder "$NOTES"
