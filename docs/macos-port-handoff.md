# ZCode Status Light — macOS 移植交接文档

> 面向对象：在 macOS 上继续开发本项目的工程师。
> 基线版本：`0.2.0-alpha.6`（源码 `apps/desktop/package.json`，对应 GitHub Release `v0.2.0-alpha.6`）。
> 仓库：https://github.com/NNNSX/zcode-status-widget

---

## 1. 项目概况

ZCode Status Light 是一个 Electron 桌面悬浮状态灯，实时显示 ZCode 各会话的执行状态：

| 状态 | 表现 |
|---|---|
| 执行中 | 黄灯闪烁 |
| 等待非 Bash 权限审批 | 红灯快闪 + 全局提醒弹窗 |
| 本轮完成 | 绿灯慢呼吸 |
| 无活跃会话 | 三颗暗灯 + "暂无活跃会话" |

技术栈：Electron 44 / TypeScript 5.9 / Vite 7 / Vitest 3 / electron-builder 26 / ESLint 9。零运行时框架依赖（渲染层是原生 DOM + CSS，唯一 dependency 是图标库 `lucide`）。

### 仓库布局

```
zcode-status-widget/
├── apps/
│   ├── desktop/          # Electron 应用（本次移植主体）
│   │   ├── assets/       # tray.png、icon.ico、installer.nsh（NSIS，Windows 专属）、hook/ZCodeStatusHook.exe
│   │   ├── scripts/      # build-windows.ps1 / package-release.ps1 / test-hook-helper.ps1（全是 PowerShell）
│   │   ├── src/
│   │   │   ├── main/     # 主进程：生命周期、窗口、托盘、事件服务器、Hook 集成、设置持久化
│   │   │   ├── preload/  # contextBridge 暴露的受限 API
│   │   │   ├── renderer/ # 面板 / 提醒 / 设置三个 surface 的 UI
│   │   │   └── shared/   # 协议、reducer、配置模型（纯逻辑，跨平台）
│   │   ├── tests/        # Vitest 单测（平台无关为主）
│   │   └── artifacts/    # 构建产物（windows/、release-v*/）
│   └── hook-helper/      # C# helper 源码（ZCodeStatusHook.cs + Tests.cs）——Windows 专属，mac 需重写
├── docs/                 # releasing.md、zcode-hooks.example.json、本文件
├── CHANGELOG.md
└── *.py / install.ps1 等 # ⚠️ 根目录 Python 文件是 legacy 0.1.x 发布链，与 Electron 版无关，勿动勿用
```

---

## 2. 架构与数据流（移植前必须理解）

```
ZCode CLI 触发 Hook 事件
  → 拉起 helper 进程（hook 配置里 type: "process"，timeoutMs: 5000 兜底）
      helper: 读 stdin JSON（≤64KiB，严格 UTF-8，容 BOM）
              只读打开 ~/.zcode/cli/db/db.sqlite，查 session 表 parent 链（≤16 层）求根工作区
              POST http://127.0.0.1:57310/event（500ms 超时，失败重试 1 次，间隔 150ms）
              stdout 保持干净，一切异常吞掉，绝不阻塞 ZCode
  → Electron 主进程 EventServer（只绑 127.0.0.1:57310）
      校验：事件白名单、单字符串 ≤512 字符、todos ≤64 条、请求体 ≤64KiB、队列 ≤256、每 tick 消费 ≤32
  → reducer（src/shared/reducer.ts，纯函数，决定会话状态机与提醒效果）
  → WindowManager 面板/提醒窗口渲染
```

关键设计约束（mac 版必须原样保留）：

- 面板 `showInactive()` + `focusable: false` + `setIgnoreMouseEvents(true, { forward: true })`——不抢焦点、默认点击穿透。
- 提醒窗口 `pop-up-menu` 层级并周期性重新提升，同样不抢焦点。
- 多显示器逻辑以 DIP 坐标工作：按窗口中心点 `screen.getDisplayNearestPoint` 选显示器，设置窗口拖动按当前显示器 workArea 夹紧；显示器变化不伪造用户手动位置。
- 主进程生命周期有 `startupReady / startupFailed / isQuitting` 防护，窗口创建有 Promise 锁 + generation 防竞态（`src/main/window-manager.ts`），移植时不要简化掉。

---

## 3. 开发与构建命令

在 `apps/desktop/` 下：

| 用途 | 命令 | mac 备注 |
|---|---|---|
| 安装依赖 | `npm install` | 直接可用 |
| 本地开发 | `npm run dev` | 直接可用 |
| 生产构建 | `npm run build` | 直接可用 |
| 类型检查 | `npm run typecheck` | 直接可用 |
| Lint | `npm run lint` | 直接可用 |
| 单元测试 | `npx vitest run` | ⚠️ 不要用 `npm test`：它会先跑 `test:hook-helper`（PowerShell + csc 编译 C#），在 mac 上必挂 |
| Windows 安装器 | `npm run dist:win` | mac 上不可用，忽略 |

已知的 Windows 侧教训（mac 对应处理）：

- electron-builder 曾反复因下载 `winCodeSign` 超时失败，靠 `CSC_IDENTITY_AUTO_DISCOVERY=false` + 本地缓存规避。mac 构建签名用 ad-hoc（见 §4.3），没有这个问题。
- 发布脚本输出全 ASCII，避免 PowerShell 5.1 按系统代码页解析中文出错。bash 版无此约束，但保持输出可机器解析的习惯。

---

## 4. Windows 专属耦合点与 mac 替换方案（移植清单）

### 4.1 Hook helper（工作量最大）

- 现状：`apps/hook-helper/ZCodeStatusHook.cs`，.NET Framework，P/Invoke `winsqlite3.dll`（Windows 系统 SQLite）。C# 测试在 `ZCodeStatusHook.Tests.cs`。
- mac 方案：用 **Swift 或 C 单文件工具重写**（建议 Swift，系统自带编译器，零第三方依赖）：
  - 链接系统 `libsqlite3.dylib`，`sqlite3_open_v2` 只读打开 db.sqlite；
  - 只执行一条查询：`SELECT directory, parent_id FROM session WHERE id = ?`，沿 parent 链上溯 ≤16 层、防环（HashSet），取最深非空 `directory` 为根工作区；
  - HTTP POST 用 `URLSession`（超时 500ms，非 2xx 或失败后 sleep 150ms 重试一次）；
  - 端口默认 57310，环境变量 `ZCODE_STATUS_PORT` 可覆盖（1–65535）；
  - stdin 读取 ≤64KiB，严格 UTF-8 解码、容忍 BOM，JSON 解析失败直接退出；
  - **stdout 必须无任何输出**，所有异常吞掉静默退出——helper 的失败绝不能影响 ZCode；
  - 产出 payload 字段（POST JSON 体）：

    ```
    event(必填，见 §5 token 表) / session_id / project / project_dir / workspace_dir /
    workspace_source("session_root"|"event_dir") / prompt_preview(≤60 字符) /
    last_tool(≤40) / error_preview(≤60) / todos[{content≤80,status}] /
    current_task / turn_id(≤128) / ts(Unix 秒，浮点)
    ```

  - stdin 输入 JSON 中实际用到的字段：`prompt|user_prompt|message`、`tool_name|toolName`、`tool_response.{error|message|stderr}`、`todos[{content|activeForm|subject,status}]`、`turn_id|turnId`（也查 `tool_input`、`message` 两层嵌套）。
- 产物命名建议 `ZCodeStatusHook`（无 .exe），放 `apps/desktop/assets/hook-macos/ZCodeStatusHook`，构建时 `chmod +x` 并打进 extraResources。
- helper 的完整行为规格以 `ZCodeStatusHook.cs` 为准（约 500 行，逐条对照移植），配套自测参照 `scripts/test-hook-helper.ps1` 的思路写 `test-hook-helper.sh`（swiftc 编译 + 断言脚本）。

### 4.2 设置持久化

- 现状：`src/main/settings-registry.ts` 写 Windows 注册表 `HKCU\Software\ZCodeStatusLight`（reg.exe），**非 win32 平台 load/persist 直接跳过**——即当前代码在 mac 上设置不保存。
- mac 方案：新增 `settings-file.ts`（读写 `app.getPath("userData")/settings.json`），在 `src/main/index.ts` 的 `SettingsRegistry` 注入点按 `process.platform` 分支。`ConfigPersistenceQueue`（串行、只持久化最新、失败聚合、`lastError` 可观察）原样复用，只换底层 sink。
- 注意：Windows 注册表字段名和序列化格式是为了兼容旧 Python 版，mac 是全新平台，直接用干净的 JSON 键名即可。

### 4.3 electron-builder 配置（`apps/desktop/package.json` 的 `build` 段）

- 现状：`directories.output: "artifacts/windows"`、`win.target: ["nsis"]`、`nsis.include: assets/installer.nsh`、extraResources 带 `ZCodeStatusHook.exe`、图标 `icon.ico`。
- mac 方案（增量添加，不动 Windows 配置）：

  ```jsonc
  "mac": {
    "target": [{ "target": "dmg", "arch": ["arm64"] }],   // 如需 Intel 再加 x64 或用 universal
    "icon": "assets/icon.icns",
    "category": "public.app-category.developer-tools",
    "identity": null,          // ad-hoc 签名：无 Apple 开发者证书时的最低要求，否则 Gatekeeper 拦截
    "extendInfo": { "LSUIElement": true }  // 建议值：不在 Dock 显示，只留菜单栏托盘（按产品决策定）
  },
  "dmg": { "writeUpdateInfo": false }
  ```

- extraResources 按 `process.platform` 分别声明（electron-builder 支持在 extraResources 条目上加 `"os": ["mac"]`）：mac 条目放 helper 二进制（记得保留可执行位）和 mac 托盘图标。
- 图标：新做 `assets/icon.icns`（1024 原稿导出全尺寸）。

### 4.4 安装/卸载与 Hook 清理

- 现状：Windows 用 NSIS `assets/installer.nsh`，卸载时以 `--unconfigure-hooks --silent` 拉起主程序清理 Hook（失败则中止卸载，保护用户配置）。
- mac 方案：dmg 拖拽安装没有卸载器。**必须在设置窗口加"取消 Hook 集成"按钮**（`HookIntegrationManager.unconfigure()` 已实现，含备份恢复），并在 README 提供手工清理指引。这是硬要求：不能让用户卸载后残留 Hook 指向不存在的二进制。

### 4.5 Hook 可执行路径解析

- `src/main/hook-integration.ts:24` `hookExecutablePath()`：按 `isPackaged` 拼接 `resources/hook/ZCodeStatusHook.exe`。mac 分支改为 `Contents/Resources/hook/ZCodeStatusHook`（无后缀）。
- `managedHookRule()`/`isManagedHookRule()` 里的路径归一化（`normalizePath`，大小写不敏感比较）在 mac 上语义不完美（APFS 默认大小写不敏感，保持现状即可），命令字段会随平台变化——集成状态与备份逻辑按"当前安装实例的 executablePath"判定归属，这块逻辑是参数化的，无需改动。

### 4.6 托盘

- 现状：`assets/tray.png` 静态彩色图标，`src/main/tray-icon.ts` 只做路径解析，托盘菜单在 `tray.ts`。
- mac 方案：黑白 **template image**（命名 `trayTemplate.png` + `trayTemplate@2x.png`，或代码 `image.setTemplateImage(true)`），否则菜单栏深浅色模式下图标会难看/隐形。菜单结构可复用。

### 4.7 平台标识清理

- `src/main/app-identity.ts` 的 `APP_USER_MODEL_ID`（Windows 任务栏分组用）在 mac 无意义，保留常量无害，调用点 `app.setAppUserModelId` 内部已按平台忽略。
- `scripts/*.ps1` 三件套不删不改，新增 mac 对应 bash 脚本：`build-macos.sh`（npm build → electron-builder mac → 校验 dmg 唯一性 → sha256）。

---

## 5. Hook 配置协议（跨平台，照搬即可）

配置文件：`~/.zcode/cli/config.json`（mac 同路径）。管理的事件规则（`hook-integration.ts:9` `hookRuleSpecs`）：

| ZCode 事件 | matcher | token |
|---|---|---|
| UserPromptSubmit | — | `user_prompt_submit` |
| PermissionRequest | `^Bash$` | `permission_bash` |
| PermissionRequest | `^(?!Bash$).+` | `permission_request` |
| PostToolUse | `TodoWrite` | `todo_update` |
| PostToolUseFailure | — | `tool_failure` |
| Stop | — | `stop` |

每条规则形如：

```jsonc
{
  "matcher": "^Bash$",           // 无 matcher 的规则省略此字段
  "hooks": [{
    "type": "process",
    "command": "<安装路径>/ZCodeStatusHook(.exe)",
    "args": ["<token>", "${CLAUDE_SESSION_ID}", "${ZCODE_PROJECT_DIR}", "<config同目录>/db/db.sqlite"],
    "timeoutMs": 5000
  }]
}
```

合并/移除逻辑（`mergeHookConfig` / `removeManagedHookRules`）只按"参数完全匹配本安装实例"识别自有规则，用户其他 Hook 规则原样保留。`isProviderOnlyConfig()` 拒绝把 `~/.zcode/v2/config.json`（provider 配置）误当 Hook 配置——**mac 上同样存在这个文件，必须保留此防护**。

---

## 6. 安全与隐私边界（硬约束，mac 版一条都不能少）

1. helper 对 `~/.zcode/cli/db/db.sqlite` **只读**（`sqlite3_open_v2` READONLY flag），绝不写 ZCode 数据库。
2. 不记录提示词全文、会话 ID 日志、错误正文、凭据；预览截断（60/80/128 字符）。
3. Hook 集成默认只探测 `~/.zcode/cli/config.json`；非默认路径必须用户明确选择实际文件，**禁止递归扫描、禁止创建猜测的配置**。
4. 写配置前向用户展示：路径、规则数、回环地址、备份位置，取得明确确认。
5. 配置写入流程：备份原始字节 → 临时文件 → 原子替换 → 回读校验，任何一步失败还原备份。
6. 事件服务器只绑 `127.0.0.1`。
7. helper stdout 恒为空、异常全吞、有自超时意识（ZCode 的 timeoutMs: 5000 是兜底不是借口）。
8. 渲染进程安全基线：`contextIsolation: true`、`nodeIntegration: false`、`sandbox: true`、`webSecurity: true`——preload 只暴露白名单 IPC。

---

## 7. mac 真机验收清单（发版前逐项过）

> 2026-09-04 移植完成后的核对结果：`[x]` 已自动/程序化验证，`[x!]` 已验证但建议真机再确认，`[ ]` 需人工在真机完成。

- [x] 原生 App 全功能可用（面板、三色状态、Todo/时间双列、提醒、设置）——curl 六类事件端到端验证，含 debug 与打包版
- [ ] 托盘 template 图标在浅色/深色菜单栏下均清晰；菜单入口齐全（图标为运行时 SF Symbol template，需人工目测）
- [x!] 面板不抢焦点（nonactivating NSPanel + canBecomeKey=false）、`Cmd+Tab` 不出现窗口（accessory 策略 + LSUIElement + ignoresCycle；建议真机确认）
- [x] 点击穿透：提醒窗口 ignoresMouseEvents=true；面板为非激活可交互（无"点击穿透开启"设置项，与 Windows 版行为一致按规格实现）
- [x!] 提醒弹窗不激活 App（borderless + orderFrontRegardless + ignoresMouseEvents）；重复提醒复用同一窗口并刷新内容（复用路径端到端验证）；自动关闭（新窗口/复用/取消三条路径验证）
- [ ] 多显示器 + Retina：面板/设置窗口拖到副屏位置正确；拔掉副屏后回退到主屏；设置窗口拖动不出工作区（几何有单测，真机多屏待人工）
- [x] Hook 集成：安装→config.json 内容正确（路径为 bundle 内 mac helper）；卸载→完整还原并恢复备份（临时配置文件事务测试 28 个全绿；真实 ~/.zcode/cli/config.json 的安装留给用户首次运行时确认执行）
- [x] mac 上验证 ZCode 的 db.sqlite `session` 表结构与 Windows 一致（`directory`、`parent_id` 字段存在）——M0 已完成，helper e2e 基于真实表结构
- [x] dmg 安装、ad-hoc 签名（codesign --verify 通过；本机构建无隔离属性可正常打开，下载分发后如判"已损坏"用 `xattr -cr` 解除，见 mac README）
- [x] 单测全绿：TestRunner 78 个（本机无 Xcode，XCTest 不可用，用自定义迷你测试框架）
- [x] helper 自测脚本（test-hook-helper.sh）全绿：34/34

---

## 8. 版本与发布

- 版本唯一来源：`apps/desktop/package.json`（`package-lock.json` 同步）。Windows 发布流程见 `docs/releasing.md`。
- mac 版建议版本策略：首次可用定为 `0.3.0-alpha.1`（跨平台是 minor 级变化），changelog 单独条目。
- mac 构建产物输出 `artifacts/macos/`，发布打包产物放 `artifacts/release-v<version>/`，同样生成 `SHA256SUMS.txt`。发布脚本参照 `scripts/package-release.ps1` 的白名单纪律：只收当前版本 dmg/zip + 校验和 + 发布说明，不混入历史产物。
- GitHub Release：目前只有 Windows 资产（v0.2.0-alpha.6）；mac 资产追加到同一 Release 或新 tag 皆可，保持 prerelease 标记。

---

## 9. 背景备忘（避免误判的已知问题）

- **ZCode 客户端自身的渲染进程 V8 内存泄漏**（长会话数小时后 4GB 堆耗尽 → 白屏）已在 Windows 3.10.2 实证（crashpad dump：`v8-oom-location: CALL_AND_RETRY_LAST`），机制上全平台存在。与本悬浮窗无关（数据流单向、helper 只读），mac 开发时如遇 ZCode 白屏，先查 `~/.zcode/v2/crash/` 下的 dump，不要怀疑本项目。
- Windows 侧仍未做的人工验收（真实多显示器/不同 DPI/Fences 等）与 mac 验收可以并行推进。
- alpha.4 → alpha.6 期间修复的关键回归（勿回退）：Bash/非 Bash 审批区分、`Stop.turn_id` 校验、无 `turn_id` 审批事件更新会话、重复提醒窗口复用、设置窗口拖动夹紧、卸载 Hook 清理失败即中止。
