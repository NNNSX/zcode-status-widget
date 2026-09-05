# ZCode Status Light — macOS 原生版

Swift/AppKit 原生实现的状态灯（对应 Windows Electron 版 0.2.0-alpha.6 的功能对齐移植）。悬浮三色状态面板 + 全局提醒 + 设置窗口 + ZCode Hook 集成。菜单栏托盘常驻，不占 Dock 图标。

- 黄灯 = 会话执行中；红灯 = 等待非 Bash 审批；绿灯 = 本轮任务完成；暗色 = 无会话。
- 全局提醒四种模式：关闭 / 边缘扫光（panel-pulse）/ 角落卡片（corner-overlay）/ 屏幕中央卡片（center-overlay）。
- 事件来源：ZCode CLI Hook → 本地 helper（只读 SQLite）→ `http://127.0.0.1:57310/event`（仅回环地址）。

## 安装（dmg）

1. 下载 `ZCodeStatusLight-v<版本>-macos-arm64.dmg`，打开后把 `ZCodeStatusLight` 拖入 `Applications`。
2. 首次启动会自动打开设置窗口，在「ZCode Hook 集成」区块点「配置 Hook」，确认对话框会列出：
   - 目标配置文件路径（`~/.zcode/cli/config.json`）
   - 将写入的 6 条规则
   - 发送范围仅 `http://127.0.0.1:<port>/event`，不访问外网
   - 备份位置（配置同目录 `.zcode-status-light-backups/`）
3. 确认后写入前自动备份原配置，原子替换并回读校验，失败自动还原。

### Gatekeeper 提示“已损坏”怎么办

当前 dmg 为 ad-hoc 签名（无开发者证书），部分 macOS 版本首次打开会提示“已损坏，无法打开”。执行：

```bash
xattr -cr /Applications/ZCodeStatusLight.app
```

然后重新打开即可。这是对未公证 App 的常规隔离标记，与二进制本身无关。

## 开机自启与崩溃自动重启（LaunchAgent，可选）

安装后登录时自动启动，异常退出（崩溃/被杀）约 5 秒内自动重启；托盘菜单的正常退出不会被重新拉起：

```bash
scripts/install-launchagent.sh    # 安装并立即启动（默认 /Applications 路径）
scripts/uninstall-launchagent.sh  # 停止自启与守护（不动应用本身）
```

注意：agent 记录的是安装时的应用路径，把 .app 移到别处后需重跑安装脚本。

## 卸载

1. 先移除 Hook 集成（会先备份再还原配置）：
   - 设置窗口 →「ZCode Hook 集成」→「移除 Hook」，或
   - 命令行：`/Applications/ZCodeStatusLight.app/Contents/MacOS/ZCodeStatusLight --unconfigure-hooks`
2. 如安装过 LaunchAgent：`scripts/uninstall-launchagent.sh`。
3. 退出托盘程序，删除 `/Applications/ZCodeStatusLight.app`。
4. 残留数据（可选清理）：`~/Library/Application Support/ZCodeStatusLight/`（settings.json 与 integration-state.json）。

## 从源码构建

人工验收清单（步骤与预期现象，可对照勾选）：[manual-test-checklist.html](manual-test-checklist.html)（浏览器打开）。

要求：macOS 14+，Xcode Command Line Tools（`xcode-select --install`）。

```bash
# 构建并跑单元测试（79 个，自定义 TestRunner；本机无 Xcode 时 XCTest 不可用）
swift build && .build/debug/TestRunner

# helper 端到端自测（34 个：构建 helper、sqlite3 种子库、本地 HTTP 捕获断言）
bash scripts/test-hook-helper.sh

# 开发运行（helper 自动指向 .build/debug 产物）
swift build && .build/debug/ZCodeStatusLight

# 打包 dmg（版本号来源 Sources/Core/AppVersion.swift，输出 ../../artifacts/macos/）
scripts/build-macos.sh

# 重新生成图标（Resources/icon.icns）
scripts/gen-icon.sh
```

## 与 Windows 版的已知差异

- 设置持久化为 JSON 文件（`~/Library/Application Support/ZCodeStatusLight/settings.json`），与 Windows 相同的原子写策略。
- Hook 配置重写采用 JSONSerialization（键序按字母排序），语义与原文件等价；Windows 侧保持原键序。
- 坐标系差异已按 AppKit 左下原点适配；`CGWindowList` 对无边框 NSPanel 报告的 x/宽度有 8pt 元数据收缩（视觉与 AppKit frame 均正确），不影响使用。

## 版本

版本唯一来源：`Sources/Core/AppVersion.swift`。当前 `0.3.0-alpha.1`。
