# ZCode 状态灯

[![Windows](https://img.shields.io/badge/platform-Windows%2010%20%2F%2011-0078D4)](#系统要求)
[![macOS](https://img.shields.io/badge/platform-macOS%2013%2B-111111)](#系统要求macOS)
[![Electron](https://img.shields.io/badge/runtime-Electron%2044-47848F)](#系统要求)
[![Swift](https://img.shields.io/badge/runtime-Swift%20%2F%20AppKit-F05138)](#系统要求macos)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

`ZCodeStatusLight` 是一个仅在本机运行的 Windows 悬浮状态灯。它把 ZCode 会话状态显示在屏幕角落：不替代 ZCode，不上传会话数据，不建立云端服务。

当前发布版本：Windows Electron 桌面版 `0.2.0-alpha.6`（源码 `apps/desktop/`，Hook 助手 `apps/hook-helper/`）；macOS 原生版 `0.3.0-alpha.1`（Swift/AppKit，源码 `apps/macos-native/`，安装见[ macOS 版](#系统要求macos)）。GitHub tag 会自动生成当前源码的 Source code ZIP/TAR；Windows 安装器、`.blockmap` 和 SHA-256 校验文件作为 Release 资产提供。

## 状态语义

| 灯 | 动效 | 会话含义 | ZCode 事件 |
|---|---|---|---|
| 黄灯 | 闪烁 | 正在执行 | `UserPromptSubmit`、`TodoWrite`、Bash 的 `PermissionRequest` |
| 红灯 | 快闪 | 等待你确认权限 | 非 Bash 工具的 `PermissionRequest` |
| 绿灯 | 呼吸 | 本轮完成 | `Stop` |

工具失败不是会话状态。`PostToolUseFailure` 只在悬停详情中累计错误次数和最近一条摘要，不会把会话灯切成错误色。

面板按最近活跃时间排序。白色粗体列优先显示 ZCode 根会话的工作区名称，不受子会话执行目录影响；无法读取本机会话数据库时，才回退到 Hook 传入目录的名称。右侧分为独立的 Todo 进度列和时间列：执行中和等待确认时显示状态持续时间，完成状态显示冻结的本轮总耗时。提醒层不抢焦点、不拦截鼠标键盘。

## 功能范围

- 横向红、黄、绿三灯与状态动效。
- 多会话列表、独立 Todo 进度列、状态时间列与悬停详情。
- 拖动定位、系统托盘、位置记忆、透明度、面板宽度、完成会话保留时间和状态提醒。
- 无活跃会话时显示三颗暗灯和“暂无活跃会话”，也可在设置中关闭空闲常驻。
- 仅监听 `127.0.0.1:57310`，不会暴露网络端口。
- 输入不超过 64 KiB，队列最多 256 条，每次界面刷新最多处理 32 条。

## 系统要求（macOS）

- macOS 13 或更新版本，Apple Silicon（arm64）。
- 已安装 ZCode。默认 Hook 候选为 `~/.zcode/cli/config.json`；`~/.zcode/v2/config.json` 是 provider 配置，状态灯会拒绝写入。
- 事件服务器只监听 `127.0.0.1:57310`，不访问外网。

### 安装（macOS）

1. 从 [GitHub Releases](https://github.com/NNNSX/zcode-status-widget/releases) 下载 `ZCodeStatusLight-v0.3.0-alpha.1-macos-arm64.dmg` 与 `SHA256SUMS.txt`，校验一致后安装。
2. 安装包为 ad-hoc 签名，首次打开若提示无法验证：`xattr -cr /Applications/ZCodeStatusLight.app` 后再启动。
3. 应用为菜单栏常驻（无 Dock 图标）。首次使用在设置页确认 Hook 连接；可选 `apps/macos-native/scripts/install-launchagent.sh` 开机自启与崩溃自动重启。

构建与开发说明见 `apps/macos-native/README.md`。

## 系统要求

- Windows 10 或 Windows 11。
- 已安装 ZCode。默认 Hook 候选为 `%USERPROFILE%\.zcode\cli\config.json`，但新系统首次安装时该文件可能尚未生成。
- `%USERPROFILE%\.zcode\v2\config.json` 是 provider 配置，不是 Hook 配置；状态灯会拒绝写入该文件。
- Electron 安装器已内置运行时，不要求用户另行安装 Node.js 或其他脚本运行时。

安装器尚未进行 Authenticode 签名。Windows SmartScreen 可能提示“未知发布者”；请只从对应 GitHub Release 下载，并先验证 SHA-256。

## 安装

1. 从 [GitHub Releases](https://github.com/NNNSX/zcode-status-widget/releases) 下载 `ZCode Status Light Setup 0.2.0-alpha.6.exe` 和 `SHA256SUMS.txt`。
2. 在下载目录通过 PowerShell 校验安装器：

```powershell
Get-FileHash '.\ZCode Status Light Setup 0.2.0-alpha.6.exe' -Algorithm SHA256
Get-Content .\SHA256SUMS.txt
```

输出的 64 位 SHA-256 值必须与 `SHA256SUMS.txt` 中同名安装器的值完全一致。

3. 运行安装器。若 SmartScreen 显示未知发布者，请先确认文件名与 SHA-256 均正确，再按 Windows 的“更多信息”继续。
4. 从开始菜单启动 **ZCode Status Light**。首次连接 Hook 需要在设置页主动确认。

连接完成后，重启 ZCode 或新开会话；ZCode 在会话启动时读取 Hooks。

## Hook 配置边界

设置页只会默认检查 `%USERPROFILE%\.zcode\cli\config.json`。该文件在新系统上可能尚未生成；程序不会创建、递归扫描或猜测 Hook 配置路径。`%USERPROFILE%\.zcode\v2\config.json` 仅包含 ZCode provider 配置，不能用于承载 Hook，状态灯会拒绝写入。请先通过 ZCode 当前配置流程获得实际承载 `hooks` 的 `config.json`，再在设置页选择“选择 Hook config.json”。

配置前会显示目标路径、六条计划添加的 `process` 规则、仅发送到 `http://127.0.0.1:57310/event` 的回环地址及备份位置。未经确认不会写入文件。

应用管理五类事件的六条 `process` 规则：

- `UserPromptSubmit`
- `PermissionRequest`：`^Bash$` 单独路由为执行中；`^(?!Bash$).+` 路由为等待确认。
- `PostToolUse`，且 matcher 精确为 `TodoWrite`
- `PostToolUseFailure`
- `Stop`

每条受管规则都必须同时匹配助手路径、事件 token、四个固定参数和 5000 ms 超时。重复受管规则会去重；不匹配的第三方规则一律保留。审批 `PermissionRequest` 即使没有轮次标识也会更新当前会话并触发等待提醒；完成态和完成提醒只在 `Stop` 携带与当前轮相同的可验证轮次标识时生效，避免迟到的旧事件误标记新任务完成。

全局提醒是短时、本机、点击穿透的 Electron 窗口。提醒显示期间会使用较高的窗口层级并周期性重新提升，以减少被 Fences 等桌面整理或置顶软件遮挡的概率；Windows 不允许应用对所有第三方置顶窗口作绝对层级保证。

写入前会备份原始字节到配置目录的 `.zcode-status-light-backups`，随后临时写入、原子替换并回读验证。操作期间检测到外部改写时会停止而不会覆盖外部内容。应用只记录受管路径和助手标识，不保存完整配置、提示词、会话 ID、错误正文或凭据。

[`docs/zcode-hooks.example.json`](docs/zcode-hooks.example.json) 是不含个人路径的配置模板，不建议手工覆盖整个 `config.json`。

## 使用

- 从开始菜单启动 **ZCode Status Light**。
- 左键托盘图标打开设置；右键托盘图标可重置位置或退出。
- 无边框设置窗口可从最顶部拖动带或标题区移动。
- 当前没有面板右键菜单或 Electron 开机自启开关；请使用托盘菜单管理显示、设置、重置位置、提醒演示和退出。
- 透明度为 20% 到 100%；低于 100% 时 Windows 不渲染 DWM 圆角。
- 完成会话保留时间可设为 1 至 30 分钟。
- Todo 进度列与时间列可分别显示或隐藏。
- 面板宽度可设为 320 至 640 像素，步长 20 像素。
- 状态提醒可选择关闭、面板脉冲、角落提示或中央提示，时长可设为 800 至 5000 毫秒。

## 卸载

先退出应用，再通过 Windows“已安装的应用”或开始菜单中的卸载入口卸载。卸载器只会精确移除仍完全匹配本应用记录的 Hook 规则，不会删除整个 `hooks` 对象、其他 Hook、`mcp`、插件或未知顶层配置。

卸载前会备份原始配置到相同配置目录的 `.zcode-status-light-backups`。若 Hook 清理、回读验证或集成状态删除失败，卸载会停止并保留应用安装目录，避免遗留指向已删除助手的规则。

## 隐私与安全

- 事件仅由 `ZCodeStatusHook.exe` 发送到本机回环地址 `127.0.0.1:57310/event`。
- Electron 集成状态保存在 `app.getPath("userData")\ZCodeStatusLight\electron-integration-state.json`；Windows 常见位置为 `%APPDATA%\zcode-status-light-desktop\ZCodeStatusLight\electron-integration-state.json`，实际以 Electron 返回值为准。安装器默认保留该 userData；根目录 `uninstall.ps1 -PurgeUserData` 只属于 legacy Python 运行时，不能清理 Electron 数据。需要彻底清除时，请先退出应用，再按实际 `app.getPath("userData")` 路径手工删除。
- 不要将日志、截图、ZCode 配置、备份或集成状态文件发布到公开位置，其中可能含本机路径或其他本地信息。

## 排障

- 面板不显示：确认 **ZCode Status Light** 正在运行，然后重新启动 ZCode 或新开会话。
- 新实例立即退出：`127.0.0.1:57310` 已被另一个状态灯实例占用；一次只运行一个实例。
- Hooks 没有事件：确认设置页选择的是实际承载 `hooks` 的 CLI 配置，不是 `%USERPROFILE%\.zcode\v2\config.json` provider 配置；配置后重新启动 ZCode 或新开会话。
- 没有完成绿灯或完成提示：确认 ZCode 的 `Stop` Hook 已重新加载，并检查事件是否携带当前轮次标识；状态灯会拒绝缺少或不匹配轮次标识的 `Stop`，避免旧事件结束新任务。
- 面板位置异常：托盘菜单选择“重置位置”。
- 安装器提示未知发布者：只在安装器文件名和 SHA-256 与 Release 校验文件一致时继续。

## 从源码构建

构建 Electron 运行时需要 Node.js、npm，以及 Windows .NET Framework C# 编译器。以下操作只构建本地安装器，不会改 ZCode 配置：

```powershell
cd apps\desktop
npm install
npm run typecheck
npm run lint
npm test
npm run build
npm run dist:win
```

安装器与 `.blockmap` 会生成在 `apps\desktop\artifacts\windows\`。构建器未配置代码签名；发布前应重新计算 SHA-256。

## 已知限制

- 只支持 Windows，不支持 macOS 或 Linux。
- `0.2.0-alpha.6` 是预发布版本，建议先在非关键工作流验证安装、设置窗口拖动与 Hook 配置。
- 当前安装器未做 Authenticode 签名，SmartScreen 可能提示未知发布者。
- 不会自动迁移其他状态灯实现的旧 Hook 或开机自启状态；切换运行时前请退出旧程序，并在设置页明确确认新的 Hook 配置。

## 许可证

本项目采用 [MIT License](LICENSE)。打包依赖的许可证说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。