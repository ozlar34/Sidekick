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
</dict>
</plist>
PLIST

# Ad-hoc code sign
codesign --deep --force --sign - "$APP_DIR" 2>/dev/null && echo "Code signed (ad-hoc)." || echo "Code signing skipped."

# NOTE: this script used to silently mirror the build into
# ~/Applications/Sidekick.app whenever that copy existed, on the assumption
# that Launch-at-Login (SMAppService) pointed there. In practice the
# registered login item was found to point at /Applications/Sidekick.app
# (verified via `sfltool dumpbtm`), so that auto-mirror was just quietly
# recreating a second permanent .app copy every dev-loop run — the actual
# cause of recurring "two Sidekick's" confusion (2026-09-04 cleanup). It has
# been removed: build-and-run.sh now only ever touches /Applications/. If
# you want a separate ~/Applications production install kept in sync,
# re-run Scripts/install.sh explicitly — don't let this script do it as a
# side effect.
USER_APP_DIR="$HOME/Applications/Sidekick.app"
if [ -d "$USER_APP_DIR" ]; then
    echo "NOTE: $USER_APP_DIR also exists and was NOT touched by this script."
    echo "      Run Scripts/install.sh if you want it refreshed too — having"
    echo "      both /Applications/Sidekick.app and this copy installed"
    echo "      long-term is what caused the duplicate-app confusion before."
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
