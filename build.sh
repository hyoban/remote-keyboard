#!/bin/sh
# 构建两个独立的菜单栏 App：
#   build/RemoteKeyboard.app  屏幕键盘
#   build/TelegramInput.app   Telegram 输入
# 只构建其中一个：./build.sh keyboard 或 ./build.sh telegram
set -e
cd "$(dirname "$0")"
mkdir -p build

# build_app <可执行文件名> <bundle id> <显示名> <源码目录>
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

  # 用 bundle id 作为签名要求，而不是默认的二进制哈希，
  # 这样重新构建后 macOS 仍认为是同一个 App，辅助功能权限不会失效。
  codesign --force --sign - --identifier "$id" -r="designated => identifier \"$id\"" "$app"
  echo "构建完成: $app"
}

target=${1:-all}
if [ "$target" = all ] || [ "$target" = keyboard ]; then
  build_app RemoteKeyboard dev.hyoban.remote-keyboard "屏幕键盘" Sources/Keyboard
fi
if [ "$target" = all ] || [ "$target" = telegram ]; then
  build_app TelegramInput dev.hyoban.telegram-input "Telegram 输入" Sources/TelegramInput
fi
