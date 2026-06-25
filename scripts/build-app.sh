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
signing_identity="${SIGNING_IDENTITY:--}"
if [ "$signing_identity" = "-" ]; then
    codesign --force --deep --sign - "$app"
else
    codesign --force --deep --options runtime --timestamp --sign "$signing_identity" "$app"
fi
codesign --verify --deep --strict --verbose=2 "$app"
echo "Built $app"
