#!/bin/zsh
# Build and run Sidekick as a macOS LSUIElement app
# Uses Swift Package Manager (no Xcode project needed)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "Building Sidekick..."
swift build -c release 2>&1

BINARY=".build/release/Sidekick"

if [ ! -f "$BINARY" ]; then
    echo "Build failed — binary not found at $BINARY"
    exit 1
fi

echo "Build complete."

# Create minimal .app bundle so macOS treats it as an app
APP_DIR="/Applications/Sidekick.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Copy binary
cp "$BINARY" "$MACOS_DIR/Sidekick"

# Copy app icon
cp "Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

# Copy bundled fonts (Geist) — ATSApplicationFontsPath in Info.plist
# points here so AppKit auto-registers them at launch. SidekickFont.register()
# in main.swift handles programmatic registration for non-bundle dev runs.
if [ -d "Resources/Fonts" ]; then
    mkdir -p "$RESOURCES_DIR/Fonts"
    cp Resources/Fonts/*.ttf "$RESOURCES_DIR/Fonts/" 2>/dev/null || true
    cp Resources/Fonts/*.otf "$RESOURCES_DIR/Fonts/" 2>/dev/null || true
fi

# Copy SPM-generated resource bundles (e.g. KeyboardShortcuts localizations).
# Without these, Bundle.module traps when dependencies with resources init.
cp -R .build/release/*.bundle "$RESOURCES_DIR/" 2>/dev/null || true

# Write Info.plist (LSUIElement hides from Dock)
cat > "$APP_DIR/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.oguzoral.Sidekick</string>
    <key>CFBundleName</key>
    <string>Sidekick</string>
    <key>CFBundleDisplayName</key>
    <string>Sidekick</string>
    <key>CFBundleExecutable</key>
    <string>Sidekick</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>ATSApplicationFontsPath</key>
    <string>Fonts</string>
</dict>
</plist>
PLIST

# Ad-hoc code sign
codesign --deep --force --sign - "$APP_DIR" 2>/dev/null && echo "Code signed (ad-hoc)." || echo "Code signing skipped."

# Mirror into ~/Applications if that copy exists — keeps the user-level
# install (auto-launched at login via SMAppService) in sync with the dev build.
USER_APP_DIR="$HOME/Applications/Sidekick.app"
if [ -d "$USER_APP_DIR" ]; then
    rm -rf "$USER_APP_DIR"
    cp -R "$APP_DIR" "$USER_APP_DIR"
    touch "$USER_APP_DIR"
    echo "Synced to $USER_APP_DIR"
fi

# Kill any running instance so `open` actually launches the freshly built
# binary — `open` on its own just foregrounds an existing process, which
# silently masks code changes when the old instance is still running
# (e.g. auto-launched at login via SMAppService).
pkill -x Sidekick 2>/dev/null && echo "Killed running instance." || true
# Give launchd a moment to notice the process exited before we relaunch.
sleep 1

echo "Launching $APP_DIR..."
open "$APP_DIR"
