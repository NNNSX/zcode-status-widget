#!/bin/bash
# 安装 ZCode Status Light 的 LaunchAgent（登录自启 + 崩溃自动重启）。
# KeepAlive=SuccessfulExit=false：仅异常退出（崩溃/被杀）时重启；
# 托盘菜单"退出"（exit 0）不会被重新拉起。
set -euo pipefail

APP_PATH="${1:-/Applications/ZCodeStatusLight.app}"
BINARY="$APP_PATH/Contents/MacOS/ZCodeStatusLight"
LABEL="com.zcode.statuslight"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"

[ -x "$BINARY" ] || { echo "未找到可执行文件：$BINARY"; exit 1; }

mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BINARY</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
EOF

# 先停掉现有实例与旧 agent，再注册并立即启动。
launchctl unload "$PLIST" 2>/dev/null || true
pkill -TERM -x ZCodeStatusLight 2>/dev/null || true
sleep 1
launchctl load "$PLIST"
launchctl start "${LABEL}"
sleep 1

if pgrep -x ZCodeStatusLight >/dev/null; then
    echo "LaunchAgent 已安装并启动（${LABEL}）。崩溃后约 5 秒内自动重启。"
    echo "卸载：scripts/uninstall-launchagent.sh"
else
    echo "警告：agent 已注册但应用未在运行，请检查：launchctl list | grep ${LABEL}"
    exit 1
fi
