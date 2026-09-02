# Electron 桌面运行时

此目录包含 ZCode 状态灯的 Electron + TypeScript + Vite Windows 桌面运行时。它只通过 `127.0.0.1:57310` 接收既有 Hook 事件协议，并渲染悬浮状态面板、设置页、托盘菜单和点击穿透的短时提醒。当前版本为 `0.2.0-alpha.4` 预发布版。

## Hook 集成

- 安装包会包含已编译的 `ZCodeStatusHook.exe`。ZCode 调用 Hook 时不需要 Python、PowerShell、Node 或外部服务。
- 首次启动时，设置页的“连接 ZCode Hook”默认只检查 `%USERPROFILE%\.zcode\cli\config.json`。非默认位置必须由用户明确选择实际的 `config.json`；程序不扫描用户目录，也不会猜测或新建配置文件。
- 点击“配置 Hook”后，主进程会显示目标路径、六条计划添加的 `process` 规则、备份目录，以及“仅发送到 `http://127.0.0.1:57310/event`，不访问外网”的边界。未确认前不会写入文件。
- 写入前会将原始字节备份到配置目录下的 `.zcode-status-light-backups`；随后使用临时文件原子替换并回读验证。写入失败会恢复原始字节，MCP、插件、未知顶层字段和第三方 Hook 规则均会保留。
- 若 `hooks.enabled` 明确为 `false`，确认对话框会单独说明将启用 Hooks，程序不会静默开启。
- 应用会在 `%LOCALAPPDATA%\ZCodeStatusLight\electron-integration-state.json` 中记录受管路径，不保存完整配置、提示词、会话 ID 或错误正文。重启后只在助手路径仍匹配时恢复用户选择的自定义 `config.json`。
- 正常卸载仅对仍完全匹配记录的规则执行 `--unconfigure-hooks --silent` 精确清理；升级跳过清理，卸载不会删除整个 `hooks` 对象或应用数据。

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

当前没有配置 Authenticode 证书，因此 Windows 构建设置为 `signExecutable: false`，仅跳过代码签名，仍会保留 Electron Builder 的 EXE 图标与版本资源编辑。首次构建可能需要下载 Electron Builder 的 NSIS 工具链；网络不可用时构建会失败而不会保留半成品安装器。
