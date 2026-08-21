#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="充电功率.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
DEPLOY_TARGET="12.0"

rm -rf "$APP" build
mkdir -p "$MACOS" build

echo "Compiling universal binary (arm64 + x86_64)..."
swiftc src/main.swift -target arm64-apple-macosx$DEPLOY_TARGET  -o build/BatteryWatts-arm64
swiftc src/main.swift -target x86_64-apple-macosx$DEPLOY_TARGET -o build/BatteryWatts-x86_64
lipo -create -output "$MACOS/BatteryWatts" build/BatteryWatts-arm64 build/BatteryWatts-x86_64
rm -rf build
echo "Architectures: $(lipo -archs "$MACOS/BatteryWatts")"

mkdir -p "$RESOURCES"
cp src/AppIcon.icns "$RESOURCES/AppIcon.icns"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>充电功率</string>
    <key>CFBundleDisplayName</key>     <string>充电功率</string>
    <key>CFBundleIdentifier</key>      <string>com.jpert.batterywatts</string>
    <key>CFBundleVersion</key>         <string>1.8.2</string>
    <key>CFBundleShortVersionString</key><string>1.8.2</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleExecutable</key>      <string>BatteryWatts</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>  <string>12.0</string>
    <key>LSUIElement</key>             <true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS is happy launching it locally
codesign --force --sign - "$APP" 2>/dev/null || true

echo "Built $APP"
