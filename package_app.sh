#!/bin/bash
set -e

echo "=== Packaging AirDrift macOS App ==="

# 1. Compile release build
swift build -c release

# 2. Setup directory layout
APP_DIR="AirDrift.app"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# 3. Copy binary
cp .build/release/AirDrift "$APP_DIR/Contents/MacOS/AirDrift"

# 3.5 Copy resources
cp ../my-notion-face-transparent.png "$APP_DIR/Contents/Resources/my-notion-face-transparent.png"
if [ -f "AppIcon.icns" ]; then
    cp AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# 4. Generate Info.plist
cat <<EOF > "$APP_DIR/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.txt">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>AirDrift</string>
    <key>CFBundleIdentifier</key>
    <string>com.drift.airdrift</string>
    <key>CFBundleName</key>
    <string>AirDrift</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# 5. Copy to user's Applications folder so they can access it instantly in Spotlight
echo "Copying AirDrift.app to /Applications folder..."
cp -R "$APP_DIR" /Applications/

echo "🎉 Success! AirDrift is now available in Spotlight."
echo "You can search for 'AirDrift' in Spotlight, or launch it from your Applications folder."
