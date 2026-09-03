# Electron 桌面运行时

此目录包含 ZCode 状态灯的 Electron + TypeScript + Vite Windows 桌面运行时。它只通过 `127.0.0.1:57310` 接收既有 Hook 事件协议，并渲染悬浮状态面板、设置页、托盘菜单和点击穿透的短时提醒。当前版本为 `0.2.0-alpha.6` 预发布版。

## Hook 集成

- 安装包会包含已编译的 `ZCodeStatusHook.exe`。ZCode 调用 Hook 时不需要 Python、PowerShell、Node 或外部服务。
- 首次启动时，设置页的“连接 ZCode Hook”默认只检查 `%USERPROFILE%\.zcode\cli\config.json`，该文件在新系统上可能尚未生成。程序不会扫描用户目录、猜测或新建配置文件；`%USERPROFILE%\.zcode\v2\config.json` 是 provider 配置，不能选择或写入。必须由用户明确选择实际承载 `hooks` 的 `config.json`。
- 点击“配置 Hook”后，主进程会显示目标路径、六条计划添加的 `process` 规则、备份目录，以及“仅发送到 `http://127.0.0.1:57310/event`，不访问外网”的边界。未确认前不会写入文件。
- 写入前会将原始字节备份到配置目录下的 `.zcode-status-light-backups`；随后使用临时文件原子替换并回读验证。写入失败会恢复原始字节，MCP、插件、未知顶层字段和第三方 Hook 规则均会保留。
- 若 `hooks.enabled` 明确为 `false`，确认对话框会单独说明将启用 Hooks，程序不会静默开启。
- 应用会在 Electron `app.getPath("userData")\ZCodeStatusLight\electron-integration-state.json` 中记录受管路径；在常见 Windows 安装下通常对应 `%APPDATA%\zcode-status-light-desktop\ZCodeStatusLight\electron-integration-state.json`，实际路径以 Electron 返回值为准。不保存完整配置、提示词、会话 ID 或错误正文。重启后只在助手路径仍匹配时恢复用户选择的自定义 `config.json`。
- 正常卸载仅对仍完全匹配记录的规则执行 `--unconfigure-hooks --silent` 精确清理；升级跳过清理，安装器默认保留 Electron userData。根目录 `uninstall.ps1 -PurgeUserData` 仅属于旧 Python 运行时，不会清理此目录。
- 左键托盘图标打开设置；右键托盘图标可重置位置或退出。当前没有面板右键菜单或 Electron 开机自启开关。
- 提醒 `PermissionRequest` 即使 Hook 输入没有 `turn_id` 也会更新当前会话并显示等待提醒；只有完成用的 `Stop` 仍要求与当前轮匹配的轮次标识。重复审批会刷新同一提醒，不会无限创建窗口。提醒显示期间会周期性重新提升窗口层级，降低被 Fences 等桌面软件遮挡的概率。
- 正常卸载仅对仍完全匹配记录的规则执行 `--unconfigure-hooks --silent` 精确清理；升级跳过清理，安装器默认保留 Electron userData。

## 开发

```powershell
cd apps\desktop
npm install
npm run typecheck
npm run lint
npm test
npm run dev
```

开发服务器默认只监听回环地址。如需避免本机已有状态灯实例占用生产端口，可仅在开发环境设置替代端口：

```powershell
$env:ZCODE_STATUS_PORT = "57311"
npm run dev
```

## 本地 Windows 安装器

构建未签名的 x64 NSIS 安装器：

```powershell
npm run dist:win
```

构建过程会先重新编译原生 Hook 助手；该步骤失败时不会生成安装器。安装器与 `.blockmap` 会输出到 `apps\desktop\artifacts\windows\`。安装器不修改 ZCode 配置，Hook 配置始终需要用户在应用内明确确认。

当前没有配置 Authenticode 证书，因此 Windows 构建设置为 `signExecutable: false`，并由打包脚本自动设置 `CSC_IDENTITY_AUTO_DISCOVERY=false`，跳过证书探测和 `winCodeSign` 下载。Electron、NSIS 等基础工具仍优先复用 `%LOCALAPPDATA%` 下的缓存；首次缓存缺失时需要网络下载。
