#!/bin/sh
set -eu

swift build -c release
app="Router Online Monitor.app"
if [ -e "$app" ]; then
    echo "$app already exists; move or remove it before rebuilding." >&2
    exit 1
fi
mkdir -p "$app/Contents/MacOS"
cp .build/release/RouterOnlineMonitorMenuBar "$app/Contents/MacOS/"
cp Resources/Info.plist "$app/Contents/"
echo "Built $app"
