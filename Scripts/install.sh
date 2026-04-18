#!/bin/zsh
# Build, compose, ad-hoc sign, and install Sidekick into ~/Applications/
# Uses Swift Package Manager (no Xcode project needed).
#
# Idempotent: safe to run repeatedly. Wipes the prior copy at
# $HOME/Applications/Sidekick.app, kills any running instance, rebuilds
# Release, recomposes the .app bundle, copies the icon, signs ad-hoc,
# verifies the signature, and prints next steps.
#
# Source: derived from build-and-run.sh — see 06-PATTERNS.md keep/modify/drop
# table. Differences vs. build-and-run.sh:
#   - Targets $HOME/Applications/ (user-scoped, no sudo) instead of /Applications/
#   - Adds killall + mkdir -p safety (Pitfall 6)
#   - Adds icon copy step (CFBundleIconFile = AppIcon)
#   - Bumps Info.plist: CFBundleVersion 1, CFBundleShortVersionString 1.0.0
#   - Adds CFBundleIconFile = AppIcon
#   - Drops --deep from codesign (no nested bundles, see Pitfall 3)
#   - Adds codesign -v gate
#   - Drops pkill/sleep/open dev-loop tail
#   - Prints three-branch Gatekeeper guidance + /Applications/ cleanup reminder

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

echo "Building Sidekick..."
swift build -c release 2>&1

BINARY=".build/release/Sidekick"

if [ ! -f "$BINARY" ]; then
    echo "Build failed — binary not found at $BINARY"
    exit 1
fi

echo "Build complete."

# Create minimal .app bundle so macOS treats it as an app
APP_DIR="$HOME/Applications/Sidekick.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"

# Pre-install safety (Pitfall 6 — Launch Services / SMAppService collision):
# kill the running instance (possibly auto-launched at login via SMAppService
# on the old copy) so it does not hold file locks while we replace the bundle.
killall Sidekick 2>/dev/null || true

mkdir -p "$HOME/Applications"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Copy binary
cp "$BINARY" "$MACOS_DIR/Sidekick"

# Icon asset (ICON-05: wired via CFBundleIconFile → Contents/Resources/AppIcon.icns)
if [ ! -f "Resources/AppIcon.icns" ]; then
    echo "Resources/AppIcon.icns missing — run 'python3 Scripts/generate_icon.py' first"
    exit 1
fi
cp "Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

# Status bar template (loaded via Bundle.main.url in AppDelegate.installStatusItem)
if [ -f "Resources/StatusBarIconTemplate.png" ]; then
    cp "Resources/StatusBarIconTemplate.png" "$RESOURCES_DIR/StatusBarIconTemplate.png"
    [ -f "Resources/StatusBarIconTemplate@2x.png" ] && \
        cp "Resources/StatusBarIconTemplate@2x.png" "$RESOURCES_DIR/StatusBarIconTemplate@2x.png"
fi

# Write Info.plist (LSUIElement hides from Dock; CFBundleIconFile points at AppIcon.icns)
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
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
</dict>
</plist>
PLIST

# Ad-hoc code sign (no Developer ID; --deep dropped per Pitfall 3 — Sidekick has
# no nested bundles, so --deep is a no-op anyway and is deprecated for signing).
codesign --force --sign - "$APP_DIR" 2>/dev/null && echo "Code signed (ad-hoc)." || { echo "Code signing failed."; exit 1; }

# Verify signature before declaring success (RESEARCH.md §Validation Architecture gap-fill).
codesign -v "$APP_DIR" || { echo "codesign verification failed"; exit 1; }

# No pkill/open here — production install exits without auto-launching (see PATTERNS.md).

cat <<'MSG'

Installed: ~/Applications/Sidekick.app (1.0.0 / build 1, ad-hoc signed)

Next steps:
  1. Double-click ~/Applications/Sidekick.app in Finder to register with Launch Services.
  2. If Gatekeeper blocks it:
       a) right-click the app → Open, OR
       b) run: xattr -dr com.apple.quarantine ~/Applications/Sidekick.app
       c) if macOS still refuses, check System Settings → Privacy & Security for an "Open Anyway" button.
  3. In Sidekick → Settings, enable "Launch at login".
  4. If you previously installed via build-and-run.sh to /Applications/:
       rm -rf /Applications/Sidekick.app    # avoid Launch Services collision
       (SMAppService may also need: toggle Launch at Login OFF on old copy before deleting)

MSG
