# ZCode 状态灯

[![Windows](https://img.shields.io/badge/platform-Windows%2010%20%2F%2011-0078D4)](#系统要求)
[![Electron](https://img.shields.io/badge/runtime-Electron%2044-47848F)](#系统要求)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

`ZCodeStatusLight` 是一个仅在本机运行的 Windows 悬浮状态灯。它把 ZCode 会话状态显示在屏幕角落：不替代 ZCode，不上传会话数据，不建立云端服务。

> 当前仓库同时保留已发布的 Python 版 `0.1.x` 兼容运行时，并提供 Electron 桌面版 `0.2.0-alpha.4` 的 Windows x64 预发布安装器。GitHub Release 的主资产是 Electron 安装器；两个运行时共用本机端口 `127.0.0.1:57310`，请勿同时启动。

本仓库的发布方式分为两部分：源码随 Git tag 发布，GitHub 会为该 tag 自动生成 Source code ZIP/TAR；Windows 安装器、`.blockmap` 和 `SHA256SUMS.txt` 作为同一 Release 的二进制资产上传。`v0.2.0-alpha.4` 对应 Electron 桌面版预发布提交，不与历史 Python `0.1.x` tag 混用。

## 状态语义

| 灯 | 动效 | 会话含义 | ZCode 事件 |
|---|---|---|---|
| 黄灯 | 闪烁 | 正在执行 | `UserPromptSubmit`、`TodoWrite`、Bash 的 `PermissionRequest` |
| 红灯 | 快闪 | 等待你确认权限 | 非 Bash 工具的 `PermissionRequest` |
| 绿灯 | 呼吸 | 本轮完成 | `Stop` |

工具失败不是会话状态。`PostToolUseFailure` 只在悬停详情中累计错误次数和最近一条摘要，不会把会话灯切成错误色。

面板按最近活跃时间排序。白色粗体列优先显示 ZCode 根会话的工作区名称，不受子会话执行目录影响；例如子会话在 `latex` 目录运行时，仍显示其根工作区。无法读取本机会话数据库时，才回退到 hook 传入目录的名称。后续 hook 不会改名；同名工作区会稳定追加序号。右侧分为独立的 Todo 进度列和时间列：TodoWrite 有清单时显示完成数/总数；执行中和等待确认时显示该状态的已持续时间，完成状态显示冻结的本轮总耗时。两列可分别在设置中关闭，Todo 进度不会再覆盖时间。中间摘要仅使用扣除固定三灯、工作区名和右侧两列后的剩余空间。Bash 权限请求按执行中显示，避免在已批准后的终端执行期间继续误显示等待确认。非 Bash 权限首次切入等待确认时，默认在屏幕中央短暂提示“请完成审批”；本轮完成时短暂提示“本轮任务完成”。提醒层不抢焦点、不拦截鼠标键盘，且只展示工作区名称与进度或耗时。已完成会话默认保留 5 分钟，可在设置中调整为 1 至 30 分钟；所有会话仍有 30 分钟无活动保护上限，超时后自动移除。

## 功能范围

- 横向红、黄、绿三灯与状态动效。
- 多会话列表、独立 TodoWrite 进度列、状态时间列与悬停详情。
- 拖动定位、系统托盘、位置记忆、透明度、可调面板宽度、完成会话保留时间、状态提醒、空闲常驻显示、可选开机自启。
- 无活跃会话时默认显示一行三颗暗灯和“暂无活跃会话”；设置中可以关闭该行为，关闭后只保留托盘。
- 仅监听 `127.0.0.1:57310`，不会暴露网络端口。
- 输入不超过 64 KiB，队列最多 256 条，每次界面刷新最多处理 32 条；异常日志采用 1 MiB 单备份轮转。

## 系统要求

- Windows 10 或 Windows 11。
- ZCode 已安装，且使用用户配置文件 `~/.zcode/cli/config.json`。
- `0.2.0-alpha.4` 的 Electron 安装器不要求 Python、Node.js 或 PowerShell 运行时。
- Python `0.1.x` 仅保留为历史兼容版本，使用它时才需要 Python 3.8 或更高版本与 PowerShell 安装脚本。

Electron 安装器尚未进行 Authenticode 签名。Windows SmartScreen 可能提示“未知发布者”；请只从对应 GitHub Release 下载，并先验证 SHA-256。

## 安装 Electron 预发布版

1. 从 GitHub Releases 下载 `ZCode Status Light Setup 0.2.0-alpha.4.exe` 和 `SHA256SUMS.txt`。`.blockmap` 是增量更新元数据，也可一并下载留存。
2. 在下载目录通过 PowerShell 校验安装器：

```powershell
Get-FileHash '.\ZCode Status Light Setup 0.2.0-alpha.4.exe' -Algorithm SHA256
Get-Content .\SHA256SUMS.txt
```

输出的 64 位 SHA-256 值必须与 `SHA256SUMS.txt` 中同名安装器的值完全一致。

3. 运行安装器。若 SmartScreen 显示未知发布者，请先确认文件名与 SHA-256 均正确，再按 Windows 的“更多信息”继续。
4. 从开始菜单启动 **ZCode Status Light**。安装器不会写入或猜测 ZCode 配置；首次连接 Hook 需要在设置页主动确认。

连接完成后，重启 ZCode 或新开会话；ZCode 在会话启动时读取 Hooks。

## Electron Hook 配置边界

设置页只会默认检查 `%USERPROFILE%\.zcode\cli\config.json`。非默认位置必须由用户明确选择实际的 `config.json`；程序不会递归扫描目录、猜测路径或新建配置文件。

配置前会显示目标路径、六条计划添加的 `process` 规则、仅发送到 `http://127.0.0.1:57310/event` 的回环地址及备份位置。未经确认不会写入文件。

确认后，应用管理五类事件的六条 `process` 规则：

- `UserPromptSubmit`
- `PermissionRequest`：`^Bash$` 单独路由为执行中；`^(?!Bash$).+` 路由为等待确认。
- `PostToolUse`，且 matcher 精确为 `TodoWrite`
- `PostToolUseFailure`
- `Stop`

每条受管规则都必须同时匹配助手路径、事件 token、四个固定参数和 5000 ms 超时。Bash 与非 Bash 的权限规则互斥，因此同一次权限请求只会向状态灯发送一个状态事件。重复受管规则会去重；不匹配的第三方规则一律保留。

写入前会备份原始字节到配置目录的 `.zcode-status-light-backups`，随后临时写入、原子替换并回读验证。配置、回读或集成状态记录任一步失败时都会尝试恢复；操作期间检测到外部改写时会停止而不会覆盖外部内容。应用只记录受管路径和助手标识，不保存完整配置、提示词、会话 ID、错误正文或凭据。

[`docs/zcode-hooks.example.json`](docs/zcode-hooks.example.json) 是不含个人路径的配置模板，用于审查实际写入结构，不建议手工覆盖整个 `config.json`。

## 使用

- 从开始菜单启动 **ZCode Status Light**；安装完成后也可直接启动应用。
- 左键托盘图标打开设置；右键托盘图标可重置位置或退出。无边框设置窗口可从最顶部拖动带或标题区移动。
- 面板右键菜单可打开设置、切换置顶或退出。
- 开机自启仅由设置窗口中的“开机自动启动”控制，安装器不会自动开启。
- 透明度为 20% 到 100%。低于 100% 时 Windows 不渲染 DWM 圆角；调回 100% 时圆角恢复。
- 可在设置中调整完成会话保留时间，范围为 1 至 30 分钟；该选项只影响已完成的绿灯会话。
- 可在设置中独立显示或隐藏 Todo 进度列与时间列。执行中/等待确认时的时间为当前状态持续时间，完成态时间为冻结的本轮耗时。
- 面板宽度可设为 320 至 640 像素，默认 380 像素，步长 20 像素。宽度只影响中间摘要长度；三灯、工作区名、Todo 和时间列保持固定。
- 可在设置中选择状态提醒：关闭、面板脉冲、角落提示或中央提示。默认中央提示，时长可设为 800 至 5000 毫秒，默认 1800 毫秒。
- 提醒只在非 Bash 权限首次进入等待确认时显示“请完成审批”，或在 `Stop` 首次进入完成态时显示“本轮任务完成”。审批提醒不会持续常驻：ZCode 未公开审批已完成或已开始执行的对应 hook。

## 卸载

先退出应用，再通过 Windows“已安装的应用”或开始菜单中的卸载入口卸载。卸载器只会精确移除仍完全匹配本应用记录的 Hook 规则，不会删除整个 `hooks` 对象、其他 Hook、`mcp`、插件或未知顶层配置。

卸载前会备份原始配置到相同配置目录的 `.zcode-status-light-backups`。若 Hook 清理、回读验证或集成状态删除失败，卸载会停止并保留应用安装目录，避免遗留指向已删除助手的规则。界面偏好和本地诊断信息默认保留。

## 隐私与安全

- 事件仅由 `ZCodeStatusHook.exe` 发送到本机回环地址 `127.0.0.1:57310/event`。
- 软件没有网络上传、遥测、账号、数据库或云同步功能。
- 会话状态仅在悬浮窗进程内存中保存，进程退出后丢弃。
- 集成状态只保存受管配置路径与助手标识，不保存完整配置、提示词、会话 ID、错误正文或凭据。
- 不要将日志、截图、ZCode 配置、备份或集成状态文件发布到公开位置，其中可能含本机路径或其他本地信息。

## 排障

- 面板不显示：确认 **ZCode Status Light** 正在运行，然后重新启动 ZCode 或新开会话。
- 新实例立即退出：`127.0.0.1:57310` 已被已有 Python 或 Electron 运行时占用；一次只运行其中一个。
- Hooks 没有事件：在设置页检查 Hook 状态，确认 ZCode 已重新加载 `config.json`，并查看 ZCode 自己的 Hook 触发日志。
- 面板位置异常：托盘菜单选择“重置位置”。
- 安装器提示未知发布者：只在安装器文件名和 SHA-256 与 Release 校验文件一致时继续。

## 从源码构建

构建 Electron 运行时需要 Node.js 与 npm。以下操作只构建本地安装器，不会改 ZCode 配置：

```powershell
cd apps\desktop
npm install
npm run typecheck
npm run lint
npm test
npm run build
npm run dist:win
```

安装器与 `.blockmap` 会生成在 `apps\desktop\artifacts\windows\`。构建器未配置代码签名；发布前应为安装器生成 SHA-256，并与发行说明一同审查。

Python `0.1.x` 的源码与脚本保留在根目录，用于已安装旧版本的兼容维护，不是 `0.2.0-alpha.4` 的构建或安装路径。

## 已知限制

- 只支持 Windows，不支持 macOS 或 Linux。
- `0.2.0-alpha.4` 是预发布版本，建议先在非关键工作流验证安装、设置窗口拖动与 Hook 配置。
- 当前安装器未做 Authenticode 签名，SmartScreen 可能提示未知发布者。
- 不会自动迁移 Python `0.1.x` 的旧 Hook 或开机自启状态；迁移前请先退出旧运行时，并在 Electron 设置页明确确认新的 Hook 配置。

## 许可证

本项目采用 [MIT License](LICENSE)。打包依赖的许可证说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
