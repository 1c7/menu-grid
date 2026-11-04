#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
APP="$PWD/build/菜单栏面板.app"
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -O -framework AppKit -framework SwiftUI -framework ApplicationServices Sources/main.swift -o "$APP/Contents/MacOS/MenuGrid"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.onec7.menugrid</string>
<key>CFBundleName</key><string>菜单栏面板</string>
<key>CFBundleExecutable</key><string>MenuGrid</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.3</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
codesign --force --sign - --identifier com.onec7.menugrid "$APP"
echo "$APP"
