#!/bin/bash
# 卸载 ZCode Status Light 的 LaunchAgent（停止自启与崩溃重启；不动应用本身）。
set -euo pipefail

LABEL="com.zcode.statuslight"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
echo "LaunchAgent 已卸载（$LABEL）。应用仍在运行，之后需手动启动。"
