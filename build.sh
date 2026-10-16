#!/bin/sh
# Builds two independent menu bar apps:
#   build/RemoteKeyboard.app  on-screen keyboard
#   build/TelegramInput.app   Telegram input
# Build just one with ./build.sh keyboard or ./build.sh telegram
set -e
cd "$(dirname "$0")"
mkdir -p build

# build_app <executable name> <bundle id> <display name> <source dir>
build_app() {
  name=$1 id=$2 display=$3 dir=$4
  app="build/$name.app"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS"
  swiftc -O -swift-version 5 Sources/Shared/*.swift "$dir"/*.swift -o "$app/Contents/MacOS/$name"

  cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$id</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundleDisplayName</key><string>$display</string>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

  # Sign with a bundle-id requirement instead of the default binary hash, so macOS still treats a
  # rebuild as the same app and the Accessibility grant survives.
  codesign --force --sign - --identifier "$id" -r="designated => identifier \"$id\"" "$app"
  echo "Built $app"
}

target=${1:-all}
if [ "$target" = all ] || [ "$target" = keyboard ]; then
  build_app RemoteKeyboard dev.hyoban.remote-keyboard "Remote Keyboard" Sources/Keyboard
fi
if [ "$target" = all ] || [ "$target" = telegram ]; then
  build_app TelegramInput dev.hyoban.telegram-input "Telegram Input" Sources/TelegramInput
fi
