# ZCode 状态灯

[![Windows](https://img.shields.io/badge/platform-Windows%2010%20%2F%2011-0078D4)](#系统要求)
[![Python](https://img.shields.io/badge/hook%20Python-3.8%2B-3776AB)](#系统要求)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

`ZCodeStatusLight` 是一个仅在本机运行的 Windows 悬浮状态灯。它把 ZCode 会话状态显示在屏幕角落：不替代 ZCode，不上传会话数据，不建立云端服务。

每个活动会话占一行，方便在多个窗口之间工作时快速确认哪个会话在执行、等待确认或已经完成。

## 状态语义

| 灯 | 动效 | 会话含义 | ZCode 事件 |
|---|---|---|---|
| 黄灯 | 闪烁 | 正在执行 | `UserPromptSubmit`、`TodoWrite`、Bash 的 `PermissionRequest` |
| 红灯 | 快闪 | 等待你确认权限 | 非 Bash 工具的 `PermissionRequest` |
| 绿灯 | 呼吸 | 本轮完成 | `Stop` |

工具失败不是会话状态。`PostToolUseFailure` 只在悬停详情中累计错误次数和最近一条摘要，不会把会话灯切成错误色。

面板按最近活跃时间排序。白色粗体列优先显示 ZCode 根会话的工作区名称，不受子会话执行目录影响；例如子会话在 `latex` 目录运行时，仍显示其根工作区。无法读取本机会话数据库时，才回退到 hook 传入目录的名称。后续 hook 不会改名；同名工作区会稳定追加序号。右侧优先显示 TodoWrite 进度；没有任务清单时，执行中和等待确认状态显示该状态的已持续时间，完成状态显示冻结的本轮总耗时。Bash 权限请求按执行中显示，避免在已批准后的终端执行期间继续误显示等待确认。已完成会话默认保留 5 分钟，可在设置中调整为 1 至 30 分钟；所有会话仍有 30 分钟无活动保护上限，超时后自动移除。

## 功能范围

- 横向红、黄、绿三灯与状态动效。
- 多会话列表、TodoWrite 进度、状态时长与悬停详情。
- 拖动定位、系统托盘、位置记忆、透明度、完成会话保留时间、空闲常驻显示、可选开机自启。
- 无活跃会话时默认显示一行三颗暗灯和“暂无活跃会话”；设置中可以关闭该行为，关闭后只保留托盘。
- 仅监听 `127.0.0.1:57310`，不会暴露网络端口。
- 输入不超过 64 KiB，队列最多 256 条，每次界面刷新最多处理 32 条；异常日志采用 1 MiB 单备份轮转。

## 系统要求

- Windows 10 或 Windows 11。
- ZCode 已安装，且使用用户配置文件 `~/.zcode/cli/config.json`。
- Python 3.8 或更高版本，仅用于启动 `hook_handler.py`。悬浮窗 EXE 本身不需要 Python。
- PowerShell 5.1 或更高版本，仅用于安装和卸载脚本。

首发 EXE 未进行 Authenticode 签名。Windows SmartScreen 可能提示“未知发布者”；请只从对应 GitHub Release 下载，并先验证 SHA-256。

## 安装

1. 从 GitHub Releases 下载 `ZCodeStatusLight-v0.1.1-windows-x64.zip`。
2. 在下载目录解压 ZIP。不要直接从 ZIP 内运行安装脚本。
3. 在 PowerShell 中校验下载包的哈希：

```powershell
Get-FileHash .\ZCodeStatusLight-v0.1.1-windows-x64.zip -Algorithm SHA256
Get-Content .\ZCodeStatusLight-v0.1.1-windows-x64.zip.sha256
```

两行中的 64 位 SHA-256 值必须完全一致。解压后的 `SHA256SUMS.txt` 用于校验包内文件。

4. 预览安装脚本的参数和将要写入的目标：

```powershell
Get-Help .\install.ps1 -Detailed
```

5. 安装到当前用户目录，并精确合并 5 类 ZCode hooks（共 6 条 `process` 规则）：

```powershell
.\install.ps1
```

默认安装目录为 `%LOCALAPPDATA%\ZCodeStatusLight`。脚本会在修改前校验 Release 内容、Python 解释器和 ZCode JSON；写入前会备份原始配置到安装目录的 `backups\`。它不会覆盖 `mcp`、`plugins`、已有 hooks 或其他顶层配置。

如果 Python 不在 `py -3` 或 `python` 可发现的位置，显式指定解释器：

```powershell
.\install.ps1 -PythonPath "C:\Path\To\python.exe"
```

如果用户已经显式关闭了 `hooks.enabled`，安装会停止。只有明确希望重新启用 hooks 时，才应执行：

```powershell
.\install.ps1 -EnableHooks
```

安装完成后，重启 ZCode 或新开会话；ZCode 在会话启动时读取 hooks。

## 安装脚本的配置边界

安装器管理五类事件的六条 `process` 规则：

- `UserPromptSubmit`
- `PermissionRequest`：`^Bash$` 单独路由为执行中；`^(?!Bash$).+` 路由为等待确认。
- `PostToolUse`，且 matcher 精确为 `TodoWrite`
- `PostToolUseFailure`
- `Stop`

每条受管规则都必须同时匹配 handler 路径、事件 token、matcher、`${CLAUDE_SESSION_ID}`、`${ZCODE_PROJECT_DIR}` 和 5000 ms 超时。Bash 与非 Bash 的权限规则互斥，因此同一次权限请求只会向状态灯发送一个状态事件。重复安装会去重；不匹配的第三方规则一律保留。

[`docs/zcode-hooks.example.json`](docs/zcode-hooks.example.json) 是不含个人路径的配置模板，用于审查实际写入结构，不建议手工覆盖整个 `config.json`。

## 使用

- 双击安装目录中的 `ZCodeStatusLight.exe` 启动。安装完成后脚本默认启动一次。
- 左键托盘图标打开设置；右键托盘图标可重置位置或退出。
- 面板右键菜单可打开设置、切换置顶或退出。
- 开机自启仅由设置窗口中的“开机自动启动”控制，安装脚本不会自动开启。
- 透明度为 20% 到 100%。低于 100% 时 Windows 不渲染 DWM 圆角；调回 100% 时圆角恢复。
- 可在设置中调整完成会话保留时间，范围为 1 至 30 分钟；该选项只影响已完成的绿灯会话。

## 卸载

先退出悬浮窗，然后在**原解压目录或安装目录**中执行：

```powershell
.\uninstall.ps1
```

卸载器依据 `install-state.json` 精确移除本程序添加的 hooks，不会删除整个 `hooks` 块，不会覆盖历史 `config.json.bak`，也不会删除其他项目的规则。每次卸载写入前，原始 ZCode 配置会备份到 `~/.zcode/cli/.zcode-status-light-backups/`。默认保留：

- `HKCU\Software\ZCodeStatusLight` 中的位置与显示偏好。
- `%LOCALAPPDATA%\zcode-status` 中的 hook 诊断日志。

需要一并清理这两类本地数据时，才使用：

```powershell
.\uninstall.ps1 -PurgeUserData
```

若安装时曾用 `-EnableHooks` 将原来关闭的 hooks 打开，且卸载后不再有任何 hooks，可用 `-RestoreEnabledState` 恢复关闭状态。

## 隐私与安全

- 事件仅从 `hook_handler.py` 发送到本机回环地址 `127.0.0.1:57310`。
- 软件没有网络上传、遥测、账号、数据库或云同步功能。
- 会话状态仅在悬浮窗进程内存中保存，进程退出后丢弃。
- 正常离线时不写日志；非预期 hook 错误记录在 `%LOCALAPPDATA%\zcode-status\hook_error.log`，最多保留当前日志和一个备份，合计约 2 MiB。
- 不要将日志、截图、ZCode 配置或 Release 中的 `install-state.json` 发布到公开位置，其中可能含本机路径或其他本地信息。

## 排障

- 面板不显示：确认 `ZCodeStatusLight.exe` 正在运行，重新启动 ZCode 或新开会话，再检查 `%LOCALAPPDATA%\zcode-status\hook_error.log`。
- 新实例立即退出：`127.0.0.1:57310` 已被现有实例占用；状态灯使用独占绑定避免重复运行。
- hooks 没有事件：检查 Python 仍存在，确认 `config.json` 中的 hooks 已被 ZCode 重新加载，并查看 ZCode 自己的 hook 触发日志。
- 面板位置异常：托盘菜单选择“重置位置”。
- 需要诊断渲染：从源码目录运行 `python widget.py`，这样可以在控制台看到 tkinter traceback。

## 从源码构建

构建环境使用 Python 3.9 或更高版本。该操作只构建本地 EXE，不会改 ZCode 配置：

```powershell
.\scripts\build-release.ps1
.\scripts\package-release.ps1
```

第一个脚本读取 [`requirements-build.txt`](requirements-build.txt)，使用 PyInstaller 在 `dist\` 生成 `ZCodeStatusLight.exe`。第二个脚本从白名单文件生成当前版本的 `release\ZCodeStatusLight-v0.1.1-windows-x64.zip` 和 SHA-256 校验文件。

回归测试维持简单脚本形式：

```powershell
python -m py_compile widget.py hook_handler.py version.py
python test_handler.py
python test_tooltip.py
python test_opacity_regression.py
python test_session_display.py
python test_stability.py
```

其中 GUI 回归测试需要 Windows 图形桌面；它们使用随机临时端口，不会向运行中的状态灯发送测试会话。

## 已知限制

- 只支持 Windows，不支持 macOS 或 Linux。
- 坐标恢复采用单屏模型；多显示器热插拔、每显示器 DPI 与复杂窗口管理不在首发范围。
- 标准库 HTTP 服务为每连接一线程，但服务仅绑定回环地址，且请求、队列和 GUI 消费都已有固定上限。
- `hook_handler.py` 为同步本地请求，单次失败会重试一次；最坏耗时约 1.2 秒，低于 hook 的 5 秒超时。

## 许可证

本项目采用 [MIT License](LICENSE)。打包依赖的许可证说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
