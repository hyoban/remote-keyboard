#!/bin/sh
set -e
cd "$(dirname "$0")"

APP=build/RemoteKeyboard.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 Sources/*.swift -o "$APP/Contents/MacOS/RemoteKeyboard"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.hyoban.remote-keyboard</string>
  <key>CFBundleName</key><string>RemoteKeyboard</string>
  <key>CFBundleDisplayName</key><string>屏幕键盘</string>
  <key>CFBundleExecutable</key><string>RemoteKeyboard</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP" >/dev/null 2>&1
echo "构建完成: $APP"
