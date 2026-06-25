#!/bin/sh
set -eu

swift build -c release
app="Router Online Monitor.app"
if [ -e "$app" ]; then
    echo "$app already exists; move or remove it before rebuilding." >&2
    exit 1
fi
mkdir -p "$app/Contents/MacOS"
mkdir -p "$app/Contents/Resources"
cp .build/release/RouterOnlineMonitorMenuBar "$app/Contents/MacOS/"
cp Resources/Info.plist "$app/Contents/"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
xattr -cr "$app"
find "$app" -exec xattr -d com.apple.FinderInfo {} + 2>/dev/null || true
find "$app" -exec xattr -d 'com.apple.fileprovider.fpfs#P' {} + 2>/dev/null || true
signing_identity="${SIGNING_IDENTITY:--}"
if [ "$signing_identity" = "-" ]; then
    codesign --force --deep --sign - "$app"
else
    codesign --force --deep --options runtime --timestamp --sign "$signing_identity" "$app"
fi
codesign --verify --deep --strict --verbose=2 "$app"
echo "Built $app"
