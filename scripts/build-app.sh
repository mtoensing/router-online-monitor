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
if [ -d .build/release/RouterOnlineMonitor_RouterOnlineMonitorMenuBar.bundle ]; then
    cp -R .build/release/RouterOnlineMonitor_RouterOnlineMonitorMenuBar.bundle "$app/Contents/Resources/"
fi
for localized_resources in Resources/*.lproj; do
    [ -d "$localized_resources" ] || continue
    cp -R "$localized_resources" "$app/Contents/Resources/"
done
clean_extended_attributes() {
    find "$app" -exec xattr -c {} \; 2>/dev/null || true
    find "$app" -exec xattr -d com.apple.ResourceFork {} \; 2>/dev/null || true
    find "$app" -exec xattr -d com.apple.provenance {} \; 2>/dev/null || true
    find "$app" -exec xattr -d 'com.apple.fileprovider.fpfs#P' {} \; 2>/dev/null || true
    find "$app" -exec xattr -d com.apple.FinderInfo {} \; 2>/dev/null || true
    xattr -d com.apple.FinderInfo "$app" 2>/dev/null || true
    find "$app" -name "*.bundle" -exec xattr -d com.apple.FinderInfo {} \; 2>/dev/null || true
}

clean_extended_attributes
sleep 1
clean_extended_attributes
signing_identity="${SIGNING_IDENTITY:--}"
if [ "$signing_identity" = "-" ]; then
    codesign --force --deep --sign - "$app"
else
    codesign --force --deep --options runtime --timestamp --sign "$signing_identity" "$app"
fi
codesign --verify --deep --strict --verbose=2 "$app"
echo "Built $app"
