#!/bin/bash
# make_icns.sh
set -e

PNG_SRC="../my-notion-face-transparent.png"
ICONSET_DIR="AppIcon.iconset"

if [ ! -f "$PNG_SRC" ]; then
    echo "Error: $PNG_SRC not found."
    exit 1
fi

echo "=== Generating macOS AppIcon.icns from transparent PNG ==="
mkdir -p "$ICONSET_DIR"

# Generate all required macOS icon resolutions using sips
sips -z 16 16     "$PNG_SRC" --out "$ICONSET_DIR/icon_16x16.png" > /dev/null
sips -z 32 32     "$PNG_SRC" --out "$ICONSET_DIR/icon_16x16@2x.png" > /dev/null
sips -z 32 32     "$PNG_SRC" --out "$ICONSET_DIR/icon_32x32.png" > /dev/null
sips -z 64 64     "$PNG_SRC" --out "$ICONSET_DIR/icon_32x32@2x.png" > /dev/null
sips -z 128 128   "$PNG_SRC" --out "$ICONSET_DIR/icon_128x128.png" > /dev/null
sips -z 256 256   "$PNG_SRC" --out "$ICONSET_DIR/icon_128x128@2x.png" > /dev/null
sips -z 256 256   "$PNG_SRC" --out "$ICONSET_DIR/icon_256x256.png" > /dev/null
sips -z 512 512   "$PNG_SRC" --out "$ICONSET_DIR/icon_256x256@2x.png" > /dev/null
sips -z 512 512   "$PNG_SRC" --out "$ICONSET_DIR/icon_512x512.png" > /dev/null
sips -z 1024 1024 "$PNG_SRC" --out "$ICONSET_DIR/icon_512x512@2x.png" > /dev/null

# Compile into .icns file
iconutil -c icns "$ICONSET_DIR"

# Clean up
rm -rf "$ICONSET_DIR"

echo "🎉 Successfully built AppIcon.icns!"
