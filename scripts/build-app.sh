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
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict --verbose=2 "$app"
echo "Built $app"
