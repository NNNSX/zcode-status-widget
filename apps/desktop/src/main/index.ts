import path from "node:path";
import { app, dialog, ipcMain, type Tray } from "electron";
import { defaultIntegrationStatePath, HookIntegrationManager } from "./hook-integration-manager";
import { hookExecutablePath } from "./hook-integration";
import { DEFAULT_CONFIG, resetPositionConfig, type AppConfig, type ConfigInput } from "../shared/config";
import { previewSettingsConfig, saveSettingsConfig } from "../shared/settings-session";
import { attentionRequestForConfig } from "./attention-policy";
import { ConfigPersistenceQueue } from "./config-persistence";
import type { AttentionContent, PanelSnapshot, ReducerEffect } from "../shared/protocol";
import { SessionReducer } from "../shared/reducer";
import { EventServer, MAX_EVENTS_PER_TICK } from "./event-server";
import { SettingsRegistry } from "./settings-registry";
import { createTray } from "./tray";
import { WindowManager } from "./window-manager";

const launchArguments = new Set(process.argv.slice(1));
const setupHooksOnLaunch = launchArguments.has("--setup-hooks");
const unconfigureHooksOnLaunch = launchArguments.has("--unconfigure-hooks");
const silentLaunch = launchArguments.has("--silent");
const singleInstance = unconfigureHooksOnLaunch || app.requestSingleInstanceLock();
if (!singleInstance) {
  app.quit();
}

const windows = new WindowManager();
const reducer = new SessionReducer();
const settingsRegistry = new SettingsRegistry();
const configPersistence = new ConfigPersistenceQueue((next) => settingsRegistry.persist(next));
const configuredEventPort = Number(process.env.ZCODE_STATUS_PORT);
const hasConfiguredEventPort = Number.isInteger(configuredEventPort) && configuredEventPort > 0 && configuredEventPort <= 65535;
const eventPort = hasConfiguredEventPort ? configuredEventPort : undefined;
const eventServer = new EventServer({ port: eventPort });
let hookIntegration: HookIntegrationManager | undefined;
let selectedHookConfigPath: string | undefined;
let config: AppConfig = DEFAULT_CONFIG;
let previewConfig: AppConfig | undefined;
let isQuitting = false;
let tray: Tray | undefined;
let refreshTimer: NodeJS.Timeout | undefined;
let consumptionScheduled = false;

const EXIT_GRACE_PERIOD_MS = 2_500;

const settleBeforeExit = async (): Promise<void> => {
  await Promise.race([
    Promise.allSettled([eventServer.stop(), configPersistence.flush()]).then(() => undefined),
    new Promise<void>((resolve) => setTimeout(resolve, EXIT_GRACE_PERIOD_MS)),
  ]);
};

const getHookIntegration = (): HookIntegrationManager => {
  if (!hookIntegration) {
    hookIntegration = new HookIntegrationManager({
      executablePath: hookExecutablePath({
        isPackaged: app.isPackaged,
        resourcesPath: process.resourcesPath,
        dirname: __dirname,
      }),
      statePath: defaultIntegrationStatePath(app.getPath("userData")),
    });
  }
  return hookIntegration;
};

const inspectHookSetup = async () => getHookIntegration().inspect(selectedHookConfigPath);

const chooseHookConfig = async (): Promise<Awaited<ReturnType<typeof inspectHookSetup>>> => {
  const suggestedPath = selectedHookConfigPath ?? await getHookIntegration().suggestedConfigPath();
  const result = await dialog.showOpenDialog({
    title: "选择 ZCode config.json",
    defaultPath: suggestedPath,
    properties: ["openFile"],
    filters: [{ name: "ZCode config.json", extensions: ["json"] }],
  });
  if (!result.canceled && result.filePaths[0]) {
    selectedHookConfigPath = result.filePaths[0];
  }
  return inspectHookSetup();
};

const configureHooks = async (): Promise<Awaited<ReturnType<typeof inspectHookSetup>>> => {
  const before = await inspectHookSetup();
  if (before.status === "missing" || before.status === "invalid") {
    throw new Error(before.message);
  }
  if (before.isConfigured) {
    return before;
  }
  const detail = [
    `目标配置：${before.configPath}`,
    `将添加：${before.ruleCount} 条 process Hook 规则`,
    "发送范围：仅 http://127.0.0.1:57310/event，不访问外网。",
    `原始文件会先备份到：${path.join(path.dirname(before.configPath), ".zcode-status-light-backups")}`,
    before.requiresEnableConfirmation ? "当前 Hooks 已被明确关闭；确认后会将 hooks.enabled 设为 true。" : "",
  ].filter(Boolean).join("\n\n");
  const confirmation = await dialog.showMessageBox({
    type: "warning",
    title: "配置 ZCode Hook",
    message: "确认修改此 ZCode 配置吗？",
    detail,
    buttons: ["取消", "备份并配置"],
    defaultId: 0,
    cancelId: 0,
    noLink: true,
  });
  if (confirmation.response !== 1) {
    return before;
  }
  const result = await getHookIntegration().configure(selectedHookConfigPath, before.requiresEnableConfirmation);
  selectedHookConfigPath = result.configPath;
  return result;
};

const unconfigureHooks = async (): Promise<Awaited<ReturnType<typeof inspectHookSetup>>> => {
  const before = await inspectHookSetup();
  if (!before.isConfigured) {
    return before;
  }
  const detail = [
    `目标配置：${before.configPath}`,
    `将仅移除：${before.ruleCount} 条本应用管理的 process Hook 规则`,
    "不会删除 config.json，也不会修改其他 Hook、MCP、插件或 ZCode 设置。",
    `原始文件会先备份到：${path.join(path.dirname(before.configPath), ".zcode-status-light-backups")}`,
  ].join("\n\n");
  const confirmation = await dialog.showMessageBox({
    type: "warning",
    title: "移除 ZCode Hook",
    message: "确认移除本应用配置的 ZCode Hook 吗？",
    detail,
    buttons: ["取消", "备份并移除"],
    defaultId: 0,
    cancelId: 0,
    noLink: true,
  });
  if (confirmation.response !== 1) {
    return before;
  }
  if (!await getHookIntegration().unconfigure()) {
    throw new Error("当前 Hook 集成记录不可用或不属于此安装实例，已拒绝移除。");
  }
  selectedHookConfigPath = before.configPath;
  return inspectHookSetup();
};

const effectiveConfig = (): AppConfig => previewConfig ?? config;

const snapshot = (): PanelSnapshot => {
  const currentConfig = effectiveConfig();
  return {
    sessions: reducer.displaySessions(Date.now(), currentConfig.doneTtlMinutes, {
      showTodoProgress: currentConfig.showTodoProgress,
      showDuration: currentConfig.showDuration,
    }),
    showIdle: currentConfig.showIdle,
  };
};

const publish = (): void => {
  const current = snapshot();
  windows.publishSnapshot(current);
  windows.applyConfig(effectiveConfig());
};

const attentionDurationMs = (): number => {
  const previewDuration = Number(process.env.ZCODE_STATUS_POC_ATTENTION_MS);
  return Number.isFinite(previewDuration) && previewDuration > 0
    ? Math.trunc(previewDuration)
    : effectiveConfig().attentionDurationMs;
};

const showAttentionForConfig = (content?: AttentionContent): void => {
  const request = attentionRequestForConfig(effectiveConfig(), attentionDurationMs());
  if (request.kind === "none") {
    windows.closeAttention();
    return;
  }
  if (request.kind === "edge") {
    void windows.showAttention(content, request.durationMs, "edge").catch(() => undefined);
    return;
  }
  void windows.showAttention(content, request.durationMs, request.placement).catch(() => undefined);
};

const applyEffects = (effects: readonly ReducerEffect[]): void => {
  for (const effect of effects) {
    if (effect.kind === "cancel-attention") {
      windows.closeAttention(effect.sessionId);
      continue;
    }
    if (effect.kind === "show-attention" && effect.attention) {
      showAttentionForConfig(effect.attention);
    }
  }
};

const consumeEvents = (): void => {
  for (const event of eventServer.drain(MAX_EVENTS_PER_TICK)) {
    const result = reducer.apply(event);
    if (result.accepted) {
      applyEffects(result.effects);
    }
  }
  publish();
};

const scheduleConsumption = (): void => {
  if (consumptionScheduled) {
    return;
  }
  consumptionScheduled = true;
  setImmediate(() => {
    consumptionScheduled = false;
    consumeEvents();
    if (eventServer.pending) {
      scheduleConsumption();
    }
  });
};

const closeAttentionWhenDisabled = (): void => {
  if (attentionRequestForConfig(effectiveConfig()).kind === "none") {
    windows.closeAttention();
  }
};

const previewSettings = (input: ConfigInput): AppConfig => {
  previewConfig = previewSettingsConfig(config, previewConfig, input);
  closeAttentionWhenDisabled();
  publish();
  windows.publishSettings(previewConfig);
  return previewConfig;
};

const discardPreviewSettings = (): AppConfig => {
  previewConfig = undefined;
  publish();
  windows.publishSettings(config);
  return config;
};

const saveSettings = (input: ConfigInput): AppConfig => {
  config = saveSettingsConfig(config, input);
  previewConfig = undefined;
  closeAttentionWhenDisabled();
  configPersistence.schedule(config);
  publish();
  windows.publishSettings(config);
  return config;
};

const previewResetPosition = (input?: ConfigInput): AppConfig => {
  previewConfig = resetPositionConfig(previewSettingsConfig(config, previewConfig, input ?? {}));
  publish();
  windows.publishSettings(previewConfig);
  return previewConfig;
};

const resetSavedPosition = (): AppConfig => saveSettings(resetPositionConfig(config));

windows.setPanelPositionListener((position) => {
  saveSettings(position);
});

windows.setSettingsClosedListener(() => {
  if (!isQuitting) {
    discardPreviewSettings();
  }
});

const registerIpc = (): void => {
  ipcMain.handle("zcode-status:open-settings", async () => windows.openSettings());
  ipcMain.handle("zcode-status:close-settings", () => windows.closeSettings());
  ipcMain.handle("zcode-status:cancel-settings", (): AppConfig => {
    const current = discardPreviewSettings();
    windows.closeSettings();
    return current;
  });
  ipcMain.handle("zcode-status:save-settings", (_event, input: unknown): AppConfig => {
    if (input && typeof input === "object" && !Array.isArray(input)) {
      const saved = saveSettings(input as ConfigInput);
      windows.closeSettings();
      return saved;
    }
    return config;
  });
  ipcMain.handle("zcode-status:preview-settings", (_event, input: unknown): AppConfig => {
    if (input && typeof input === "object" && !Array.isArray(input)) {
      return previewSettings(input as ConfigInput);
    }
    return effectiveConfig();
  });
  ipcMain.handle("zcode-status:get-hook-setup", () => inspectHookSetup());
  ipcMain.handle("zcode-status:choose-hook-config", () => chooseHookConfig());
  ipcMain.handle("zcode-status:configure-hooks", () => configureHooks());
  ipcMain.handle("zcode-status:unconfigure-hooks", () => unconfigureHooks());
  ipcMain.on("zcode-status:settings-drag-start", (event, pointerX: unknown, pointerY: unknown) => {
    if (typeof pointerX === "number" && Number.isFinite(pointerX) && typeof pointerY === "number" && Number.isFinite(pointerY)) {
      windows.beginSettingsDrag(event.sender.id, pointerX, pointerY);
    }
  });
  ipcMain.on("zcode-status:settings-drag-move", (event, pointerX: unknown, pointerY: unknown) => {
    if (typeof pointerX === "number" && Number.isFinite(pointerX) && typeof pointerY === "number" && Number.isFinite(pointerY)) {
      windows.moveSettingsDrag(event.sender.id, pointerX, pointerY);
    }
  });
  ipcMain.on("zcode-status:settings-drag-end", (event) => {
    windows.endSettingsDrag(event.sender.id);
  });
  ipcMain.handle("zcode-status:get-panel-snapshot", () => snapshot());
  ipcMain.handle("zcode-status:get-settings", () => config);
  ipcMain.handle("zcode-status:get-attention-content", (): AttentionContent => windows.getAttentionContent());
  ipcMain.handle("zcode-status:show-attention", () => showAttentionForConfig());
  ipcMain.handle("zcode-status:show-panel", () => windows.showPanel(effectiveConfig()));
  ipcMain.handle("zcode-status:toggle-panel", () => windows.togglePanel(effectiveConfig()));
  ipcMain.handle("zcode-status:reset-position", (_event, input: unknown): AppConfig => (
    input && typeof input === "object" && !Array.isArray(input)
      ? previewResetPosition(input as ConfigInput)
      : previewResetPosition()
  ));
  ipcMain.handle("zcode-status:quit", () => app.quit());
};

if (singleInstance) {
  app.on("second-instance", () => {
    windows.showPanel(config);
  });

  app.whenReady().then(async () => {
    if (unconfigureHooksOnLaunch) {
      let exitCode = 0;
      try {
        await getHookIntegration().unconfigure();
      } catch (error) {
        exitCode = 1;
        if (!silentLaunch) {
          await dialog.showMessageBox({
            type: "error",
            title: "ZCode 会话状态",
            message: error instanceof Error ? error.message : "无法移除状态 Hook。",
          });
        }
      }
      app.exit(exitCode);
      return;
    }

    app.setAppUserModelId("com.zcode.statuslight.desktop");
    config = await settingsRegistry.load();
    registerIpc();
    await windows.createPanel(config);
    tray = createTray(windows, {
      togglePanel: () => windows.togglePanel(effectiveConfig()),
      openSettings: () => void windows.openSettings(),
      resetPosition: () => { resetSavedPosition(); },
      showAttention: showAttentionForConfig,
    });
    eventServer.on("enqueued", scheduleConsumption);
    try {
      await eventServer.start();
    } catch (error) {
      const code = error && typeof error === "object" && "code" in error ? String(error.code) : "";
      const port = eventPort ?? 57310;
      const message = code === "EADDRINUSE"
        ? `端口 ${port} 已被其他状态灯实例占用。请先退出旧版 Python 状态灯或另一桌面实例。`
        : `状态事件服务无法监听 127.0.0.1:${port}。`;
      await dialog.showMessageBox({ type: "error", title: "ZCode 会话状态", message });
      tray?.destroy();
      tray = undefined;
      windows.destroyAll();
      app.quit();
      return;
    }
    refreshTimer = setInterval(publish, 1_000);
    publish();
    if (setupHooksOnLaunch || !(await inspectHookSetup()).isConfigured) {
      await windows.openSettings();
    }
  });

  app.on("before-quit", (event) => {
    if (!isQuitting) {
      event.preventDefault();
      isQuitting = true;
      if (refreshTimer) {
        clearInterval(refreshTimer);
        refreshTimer = undefined;
      }
      tray?.destroy();
      tray = undefined;
      void settleBeforeExit().finally(() => {
        windows.destroyAll();
        app.quit();
      });
      return;
    }
    windows.destroyAll();
  });

  app.on("window-all-closed", () => {
    if (!isQuitting) {
      void windows.createPanel(effectiveConfig()).catch(() => undefined);
    }
  });
}
