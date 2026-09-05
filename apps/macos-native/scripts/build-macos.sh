#!/bin/bash
# 构建 macOS 发布产物：swift release → 组装 .app → ad-hoc 签名 → dmg → sha256。
# 用法：scripts/build-macos.sh
# 产物：../../artifacts/macos/ZCodeStatusLight-v<version>-macos-arm64.dmg + SHA256SUMS.txt
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(sed -n 's/.*current = "\([^"]*\)".*/\1/p' Sources/Core/AppVersion.swift)"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "版本号非法：$VERSION（来源 Sources/Core/AppVersion.swift）" >&2
  exit 1
fi
# CFBundleShortVersionString 只接受纯三段数字；预发布后缀放 CFBundleVersion。
SHORT_VERSION="$(cut -d- -f1 <<<"$VERSION")"
BUNDLE_ID="com.zcode.statuslight"
ARTIFACT_NAME="ZCodeStatusLight-v${VERSION}-macos-arm64"
OUTPUT_ROOT="${OUTPUT_ROOT:-$(cd ../.. && pwd)/artifacts/macos}"
APP_NAME="ZCodeStatusLight"

echo "== 1/6 swift build -c release =="
# 只构建两个产品目标：TestRunner 依赖 @testable，release 配置下不可编译。
swift build -c release --product ZCodeStatusLight
swift build -c release --product ZCodeStatusHook

STAGE="$(mktemp -d)/${APP_NAME}.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources/hook" "$STAGE/Contents/Resources"

echo "== 2/6 组装 .app =="
cp ".build/release/${APP_NAME}" "$STAGE/Contents/MacOS/${APP_NAME}"
cp .build/release/ZCodeStatusHook "$STAGE/Contents/Resources/hook/ZCodeStatusHook"
chmod 755 "$STAGE/Contents/MacOS/${APP_NAME}" "$STAGE/Contents/Resources/hook/ZCodeStatusHook"
if [[ -f Resources/icon.icns ]]; then
  cp Resources/icon.icns "$STAGE/Contents/Resources/AppIcon.icns"
else
  echo "警告：Resources/icon.icns 缺失（可先运行 scripts/gen-icon.sh），跳过图标。" >&2
fi

cat > "$STAGE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh_CN</string>
	<key>CFBundleExecutable</key>
	<string>${APP_NAME}</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleDisplayName</key>
	<string>ZCode Status Light</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${SHORT_VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${VERSION}</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
EOF

echo "== 3/6 ad-hoc 签名 =="
codesign --force --sign - --timestamp=none \
  "$STAGE/Contents/Resources/hook/ZCodeStatusHook"
codesign --force --sign - --timestamp=none "$STAGE"
codesign --verify --strict "$STAGE"

echo "== 4/6 打 dmg =="
mkdir -p "$OUTPUT_ROOT"
DMG_DIR="$(mktemp -d)"
mkdir -p "$DMG_DIR/stage"
cp -R "$STAGE" "$DMG_DIR/stage/"
ln -s /Applications "$DMG_DIR/stage/Applications"
hdiutil create -volname "$APP_NAME" \
  -srcfolder "$DMG_DIR/stage" \
  -ov -format UDZO \
  "${OUTPUT_ROOT}/${ARTIFACT_NAME}.dmg" >/dev/null

echo "== 5/6 sha256 =="
(cd "$OUTPUT_ROOT" && shasum -a 256 "${ARTIFACT_NAME}.dmg" > SHA256SUMS.txt)

echo "== 6/6 完成 =="
ls -la "${OUTPUT_ROOT}/${ARTIFACT_NAME}.dmg"
cat "${OUTPUT_ROOT}/SHA256SUMS.txt"
