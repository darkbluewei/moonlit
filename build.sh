#!/bin/bash
# 构建 MacTaskManager.app（需要 macOS 13+ 和 Xcode 命令行工具：xcode-select --install）
set -e
cd "$(dirname "$0")"
APP="MacTaskManager"

echo "==> 编译（Release）…"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/$APP"

echo "==> 打包 .app …"
rm -rf "build/$APP.app"
mkdir -p "build/$APP.app/Contents/MacOS" "build/$APP.app/Contents/Resources"
cp "$BIN" "build/$APP.app/Contents/MacOS/$APP"

cat > "build/$APP.app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>任务管理器</string>
  <key>CFBundleDisplayName</key><string>任务管理器</string>
  <key>CFBundleIdentifier</key><string>com.local.mactaskmanager</string>
  <key>CFBundleExecutable</key><string>MacTaskManager</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF

echo "==> 临时签名 …"
codesign --force --deep --sign - "build/$APP.app"

echo "完成：$(pwd)/build/$APP.app"
if [ -z "$CI" ]; then open build; fi
