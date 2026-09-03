import { createIcons, BellRing, CircleCheck, Settings, X } from "lucide";
import type { AppConfig } from "../shared/config";
import type { AttentionContent, PanelSnapshot } from "../shared/protocol";
import type { HookSetupSnapshot } from "../shared/hook-setup";
import { idleSession, stateLabels } from "../shared/ui-model";
import { renderSessionRow } from "./panel";
import "./styles.css";

const renderPanel = (root: HTMLElement): void => {
  root.className = "surface surface--panel";
  const rows = document.createElement("section");
  rows.className = "session-list";
  rows.setAttribute("aria-label", "会话状态列表");
  root.append(rows);

  const update = (snapshot: PanelSnapshot): void => {
    const sessions = snapshot.sessions.length ? snapshot.sessions : snapshot.showIdle ? [idleSession] : [];
    rows.replaceChildren(...sessions.map(renderSessionRow));
    createIcons({ icons: { BellRing, CircleCheck, X } });
    rows.querySelectorAll<HTMLElement>(".session-row").forEach((row) => {
      const state = row.dataset.state;
      if (state === "working" || state === "waiting" || state === "done" || state === "unknown") {
        row.setAttribute("aria-label", stateLabels[state]);
      }
    });
  };

  void window.zcodeStatus.getPanelSnapshot().then(update);
  window.zcodeStatus.onPanelSnapshot(update);
};

const hookStatusClass = (status: HookSetupSnapshot["status"]): string => `hook-status hook-status--${status}`;

const renderHookSetup = (root: HTMLElement, snapshot: HookSetupSnapshot): void => {
  const pathOutput = root.querySelector<HTMLElement>("#hook-config-path");
  const status = root.querySelector<HTMLElement>("#hook-setup-status");
  const configure = root.querySelector<HTMLButtonElement>("[data-action='configure-hooks']");
  const unconfigure = root.querySelector<HTMLButtonElement>("[data-action='unconfigure-hooks']");
  if (pathOutput) {
    pathOutput.textContent = snapshot.configPath;
    pathOutput.title = snapshot.configPath;
  }
  if (status) {
    status.className = hookStatusClass(snapshot.status);
    status.textContent = snapshot.message;
  }
  if (configure) {
    configure.disabled = snapshot.status === "missing" || snapshot.status === "invalid" || snapshot.isConfigured;
    configure.textContent = snapshot.isConfigured
      ? "Hook 已配置"
      : snapshot.requiresEnableConfirmation
        ? "确认启用并配置 Hook"
        : `配置 ${snapshot.ruleCount} 条 Hook`;
  }
  if (unconfigure) {
    unconfigure.disabled = !snapshot.isConfigured;
  }
};

const syncSettings = (root: HTMLElement, config: AppConfig): void => {
  const width = root.querySelector<HTMLInputElement>("#width-range");
  const widthOutput = root.querySelector<HTMLOutputElement>("#width-output");
  const opacity = root.querySelector<HTMLInputElement>("#opacity-range");
  const opacityOutput = root.querySelector<HTMLOutputElement>("#opacity-output");
  if (width && widthOutput) {
    width.value = String(config.panelWidth);
    widthOutput.value = `${config.panelWidth} px`;
  }
  if (opacity && opacityOutput) {
    opacity.value = String(config.opacity);
    opacityOutput.value = `${config.opacity}%`;
  }
  const doneTtl = root.querySelector<HTMLInputElement>("#done-ttl-range");
  const doneTtlOutput = root.querySelector<HTMLOutputElement>("#done-ttl-output");
  if (doneTtl && doneTtlOutput) {
    doneTtl.value = String(config.doneTtlMinutes);
    doneTtlOutput.value = `${config.doneTtlMinutes} 分钟`;
  }
  const attentionDuration = root.querySelector<HTMLInputElement>("#attention-duration-range");
  const attentionDurationOutput = root.querySelector<HTMLOutputElement>("#attention-duration-output");
  if (attentionDuration && attentionDurationOutput) {
    attentionDuration.value = String(config.attentionDurationMs);
    attentionDurationOutput.value = `${config.attentionDurationMs} 毫秒`;
  }
  root.querySelectorAll<HTMLInputElement>("[data-setting]").forEach((input) => {
    const key = input.dataset.setting;
    if (key === "showIdle" || key === "showTodoProgress" || key === "showDuration") {
      input.checked = config[key];
    }
  });
  root.querySelectorAll<HTMLButtonElement>("[data-corner]").forEach((element) => {
    element.classList.toggle("selected", element.dataset.corner === config.corner);
  });
  root.querySelectorAll<HTMLButtonElement>("[data-attention]").forEach((element) => {
    element.classList.toggle("selected", element.dataset.attention === config.attentionMode);
  });
  const attentionModeDetail = root.querySelector<HTMLElement>("#attention-mode-detail");
  const attentionLabels = {
    off: "不显示全局提醒",
    "panel-pulse": "沿屏幕边缘提示",
    "corner-overlay": "在状态面板附近提示",
    "center-overlay": "在屏幕中央提示",
  } as const;
  if (attentionModeDetail) {
    attentionModeDetail.textContent = attentionLabels[config.attentionMode];
  }
};

type SettingsInput = Parameters<typeof window.zcodeStatus.previewSettings>[0];

const settingRange = (
  root: HTMLElement,
  selector: string,
  key: keyof Pick<AppConfig, "panelWidth" | "opacity" | "doneTtlMinutes" | "attentionDurationMs">,
  outputSelector: string,
  preview: (input: SettingsInput) => void,
): void => {
  const input = root.querySelector<HTMLInputElement>(selector);
  const output = root.querySelector<HTMLOutputElement>(outputSelector);
  input?.addEventListener("input", () => {
    const value = Number(input.value);
    if (output) {
      output.value = key === "panelWidth"
        ? `${value} px`
        : key === "opacity"
          ? `${value}%`
          : key === "attentionDurationMs"
            ? `${value} 毫秒`
            : `${value} 分钟`;
    }
    preview({ [key]: value });
  });
};

const renderSettings = (root: HTMLElement): void => {
  root.className = "surface surface--settings";
  root.innerHTML = `
    <div class="settings-top-drag" aria-hidden="true"></div>
    <header class="settings-header">
      <div>
        <p class="eyebrow">ZCode Status Light</p>
        <h1>显示设置</h1>
      </div>
      <button class="icon-button" type="button" aria-label="关闭设置" title="关闭设置"><i data-lucide="x" aria-hidden="true"></i></button>
    </header>
    <div class="settings-content" aria-label="设置内容">
      <section class="settings-section" aria-label="面板">
        <label class="range-control">
          <span>面板宽度</span>
          <output id="width-output">380 px</output>
          <input id="width-range" type="range" min="320" max="640" step="20" value="380" />
        </label>
        <div class="segmented" role="group" aria-label="停靠位置">
          <button type="button" data-corner="bottom-right">右下</button>
          <button type="button" data-corner="bottom-left">左下</button>
          <button type="button" data-corner="top-right">右上</button>
          <button type="button" data-corner="top-left">左上</button>
        </div>
      </section>
      <section class="settings-section" aria-label="显示列">
        <label class="toggle"><span>显示 Todo 进度</span><input data-setting="showTodoProgress" type="checkbox" /><i></i></label>
        <label class="toggle"><span>显示时间</span><input data-setting="showDuration" type="checkbox" /><i></i></label>
        <label class="toggle"><span>无会话时显示空闲状态</span><input data-setting="showIdle" type="checkbox" /><i></i></label>
      </section>
      <section class="settings-section" aria-label="透明度">
        <label class="range-control">
          <span>面板透明度</span>
          <output id="opacity-output">100%</output>
          <input id="opacity-range" type="range" min="20" max="100" step="5" value="100" />
        </label>
        <label class="range-control">
          <span>完成保留时间</span>
          <output id="done-ttl-output">5 分钟</output>
          <input id="done-ttl-range" type="range" min="1" max="30" step="1" value="5" />
        </label>
      </section>
      <section class="settings-section" aria-label="全局提醒方式">
        <div class="settings-section-heading">
          <span>全局提醒方式</span>
          <span id="attention-mode-detail">中央提示</span>
        </div>
        <div class="segmented" role="group" aria-label="全局提醒方式">
          <button type="button" data-attention="off">关闭</button>
          <button type="button" data-attention="panel-pulse">边缘</button>
          <button type="button" data-attention="corner-overlay">角落</button>
          <button type="button" data-attention="center-overlay">中央</button>
        </div>
        <label class="range-control">
          <span>提醒展示时长</span>
          <output id="attention-duration-output">1800 毫秒</output>
          <input id="attention-duration-range" type="range" min="800" max="5000" step="100" value="1800" />
        </label>
      </section>
      <section class="settings-section hook-setup" aria-label="连接 ZCode Hook">
        <div class="settings-section-heading">
          <span>连接 ZCode Hook</span>
          <span>仅本机回环</span>
        </div>
        <p class="hook-config-path" id="hook-config-path">正在检查默认 Hook 配置...</p>
        <p class="hook-status" id="hook-setup-status">默认 CLI 配置可能尚未生成；不要选择 ~/.zcode/v2/config.json provider 配置。</p>
        <div class="hook-actions">
          <button class="command-button command-button--quiet" type="button" data-action="choose-hook-config"><span>选择 Hook config.json</span></button>
          <button class="command-button" type="button" data-action="configure-hooks"><span>配置 Hook</span></button>
          <button class="command-button command-button--danger" type="button" data-action="unconfigure-hooks"><span>移除 Hook</span></button>
        </div>
      </section>
    </div>
    <footer class="settings-actions">
      <button class="command-button command-button--quiet" type="button" data-action="position"><span>重置位置</span></button>
      <button class="command-button command-button--quiet" type="button" data-action="attention"><i data-lucide="bell-ring"></i><span>预览提醒</span></button>
      <button class="command-button" type="button" data-action="save"><span>保存并关闭</span></button>
    </footer>
  `;

  let draft: AppConfig | undefined;
  let draftDirty = false;
  let settingsGeneration = 0;
  let hookSetup: HookSetupSnapshot | undefined;
  let latestPreviewRequest = 0;
  let latestHookSetupRequest = 0;
  const applyHookSetup = (snapshot: HookSetupSnapshot): void => {
    latestHookSetupRequest += 1;
    hookSetup = snapshot;
    renderHookSetup(root, snapshot);
  };
  const refreshHookSetup = (): void => {
    const request = latestHookSetupRequest + 1;
    latestHookSetupRequest = request;
    void window.zcodeStatus.getHookSetup().then((snapshot) => {
      if (request === latestHookSetupRequest) {
        hookSetup = snapshot;
        renderHookSetup(root, snapshot);
      }
    });
  };
  const preview = (input: SettingsInput): void => {
    if (!draft) {
      return;
    }
    draft = { ...draft, ...input };
    draftDirty = true;
    const request = latestPreviewRequest + 1;
    latestPreviewRequest = request;
    void window.zcodeStatus.previewSettings(input).then((config) => {
      if (request === latestPreviewRequest) {
        draft = config;
        syncSettings(root, config);
      }
    });
  };
  const cancel = (): void => {
    latestPreviewRequest += 1;
    draftDirty = false;
    void window.zcodeStatus.cancelSettings().catch(() => undefined);
  };
  root.querySelector<HTMLButtonElement>("[aria-label='关闭设置']")?.addEventListener("click", cancel);
  const settingsDragSurfaces = [
    root.querySelector<HTMLElement>(".settings-top-drag"),
    root.querySelector<HTMLElement>(".settings-header"),
  ].filter((surface): surface is HTMLElement => surface !== null);
  let settingsDragActive = false;
  const beginSettingsDrag = (surface: HTMLElement, event: PointerEvent): void => {
    const target = event.target as Element | null;
    if (event.button !== 0 || target?.closest("button, input, select, textarea, a")) {
      return;
    }
    settingsDragActive = true;
    if (typeof event.pointerId === "number" && typeof surface.setPointerCapture === "function") {
      surface.setPointerCapture(event.pointerId);
    }
    window.zcodeStatus.beginSettingsDrag(event.screenX, event.screenY);
    event.preventDefault();
  };
  const moveSettingsDrag = (event: PointerEvent): void => {
    if (settingsDragActive) {
      window.zcodeStatus.moveSettingsDrag(event.screenX, event.screenY);
    }
  };
  const finishSettingsDrag = (): void => {
    if (!settingsDragActive) {
      return;
    }
    settingsDragActive = false;
    window.zcodeStatus.endSettingsDrag();
  };
  settingsDragSurfaces.forEach((surface) => {
    surface.addEventListener("pointerdown", (event) => beginSettingsDrag(surface, event));
    surface.addEventListener("pointermove", moveSettingsDrag);
    surface.addEventListener("pointerup", finishSettingsDrag);
    surface.addEventListener("pointercancel", finishSettingsDrag);
    surface.addEventListener("lostpointercapture", finishSettingsDrag);
  });
  root.querySelector<HTMLButtonElement>("[data-action='save']")?.addEventListener("click", () => {
    if (draft) {
      latestPreviewRequest += 1;
      draftDirty = false;
      void window.zcodeStatus.saveSettings(draft).catch(() => undefined);
    }
  });
  root.querySelector<HTMLButtonElement>("[data-action='attention']")?.addEventListener(
    "click",
    () => void window.zcodeStatus.showAttention(),
  );
  root.querySelector<HTMLButtonElement>("[data-action='position']")?.addEventListener(
    "click",
    () => {
      if (!draft) {
        return;
      }
      draftDirty = true;
      const request = latestPreviewRequest + 1;
      latestPreviewRequest = request;
      void window.zcodeStatus.resetPosition(draft).then((config) => {
        if (request === latestPreviewRequest) {
          draft = config;
          syncSettings(root, config);
        }
      }).catch(() => undefined);
    },
  );
  root.querySelector<HTMLButtonElement>("[data-action='choose-hook-config']")?.addEventListener("click", () => {
    void window.zcodeStatus.chooseHookConfig().then((next) => {
      applyHookSetup(next);
    });
  });
  root.querySelector<HTMLButtonElement>("[data-action='configure-hooks']")?.addEventListener("click", () => {
    if (!hookSetup || hookSetup.status === "missing" || hookSetup.status === "invalid" || hookSetup.isConfigured) {
      return;
    }
    const configure = root.querySelector<HTMLButtonElement>("[data-action='configure-hooks']");
    if (configure) {
      configure.disabled = true;
      configure.textContent = "正在配置...";
    }
    void window.zcodeStatus.configureHooks().then((next) => {
      applyHookSetup(next);
      refreshHookSetup();
    }).catch((error: unknown) => {
      if (configure) {
        configure.disabled = false;
        configure.textContent = "配置 Hook";
      }
      const status = root.querySelector<HTMLElement>("#hook-setup-status");
      if (status) {
        status.className = "hook-status hook-status--invalid";
        status.textContent = error instanceof Error ? error.message : "配置 Hook 失败。";
      }
    });
  });
  root.querySelector<HTMLButtonElement>("[data-action='unconfigure-hooks']")?.addEventListener("click", () => {
    if (!hookSetup?.isConfigured) {
      return;
    }
    const unconfigure = root.querySelector<HTMLButtonElement>("[data-action='unconfigure-hooks']");
    if (unconfigure) {
      unconfigure.disabled = true;
      unconfigure.textContent = "正在移除...";
    }
    void window.zcodeStatus.unconfigureHooks().then((next) => {
      applyHookSetup(next);
      refreshHookSetup();
    }).catch((error: unknown) => {
      if (unconfigure) {
        unconfigure.disabled = false;
        unconfigure.textContent = "移除 Hook";
      }
      const status = root.querySelector<HTMLElement>("#hook-setup-status");
      if (status) {
        status.className = "hook-status hook-status--invalid";
        status.textContent = error instanceof Error ? error.message : "移除 Hook 失败。";
      }
    });
  });
  settingRange(root, "#width-range", "panelWidth", "#width-output", preview);
  settingRange(root, "#opacity-range", "opacity", "#opacity-output", preview);
  settingRange(root, "#done-ttl-range", "doneTtlMinutes", "#done-ttl-output", preview);

  root.querySelectorAll<HTMLInputElement>("[data-setting]").forEach((input) => {
    input.addEventListener("change", () => {
      const key = input.dataset.setting;
      if (key === "showIdle" || key === "showTodoProgress" || key === "showDuration") {
        preview({ [key]: input.checked });
      }
    });
  });
  root.querySelectorAll<HTMLButtonElement>("[data-corner]").forEach((element) => {
    element.addEventListener("click", () => {
      const corner = element.dataset.corner;
      if (corner === "bottom-right" || corner === "bottom-left" || corner === "top-right" || corner === "top-left") {
        preview({ corner });
      }
    });
  });

  root.querySelectorAll<HTMLButtonElement>("[data-attention]").forEach((element) => {
    element.addEventListener("click", () => {
      const attentionMode = element.dataset.attention;
      if (attentionMode === "off" || attentionMode === "panel-pulse" || attentionMode === "corner-overlay" || attentionMode === "center-overlay") {
        preview({ attentionMode });
      }
    });
  });
  settingRange(root, "#attention-duration-range", "attentionDurationMs", "#attention-duration-output", preview);

  const initialSettingsGeneration = settingsGeneration + 1;
  settingsGeneration = initialSettingsGeneration;
  void window.zcodeStatus.getSettings().then((config) => {
    if (settingsGeneration === initialSettingsGeneration && !draftDirty) {
      draft = config;
      syncSettings(root, config);
    }
  }).catch(() => undefined);
  refreshHookSetup();
  window.zcodeStatus.onSettingsChanged((config) => {
    settingsGeneration += 1;
    if (!draftDirty) {
      draft = config;
      syncSettings(root, config);
    }
  });
};

const attentionPresentation = (): "card" | "edge" => (
  new URLSearchParams(window.location.search).get("presentation") === "edge" ? "edge" : "card"
);

const renderAttention = (root: HTMLElement): void => {
  const presentation = attentionPresentation();
  root.className = presentation === "edge"
    ? "surface surface--attention-edge"
    : "surface surface--attention";
  const update = (content: AttentionContent): void => {
    root.dataset.kind = content.kind;
    if (presentation === "edge") {
      const live = document.createElement("p");
      live.className = "attention-live";
      live.setAttribute("role", "status");
      live.setAttribute("aria-live", "polite");
      live.setAttribute("aria-atomic", "true");
      live.textContent = content.kind === "waiting"
        ? `等待用户操作：${content.title}`
        : `任务已完成：${content.title}`;
      const edges = ["top", "right", "bottom", "left"].map((side) => {
        const edge = document.createElement("div");
        edge.className = `attention-edge attention-edge--${side}`;
        edge.setAttribute("aria-hidden", "true");
        return edge;
      });
      root.replaceChildren(...edges, live);
      return;
    }

    const mark = document.createElement("div");
    mark.className = "attention-mark";
    mark.setAttribute("aria-hidden", "true");
    const icon = document.createElement("i");
    icon.dataset.lucide = content.kind === "waiting" ? "bell-ring" : "circle-check";
    mark.append(icon);

    const copy = document.createElement("div");
    copy.className = "attention-copy";
    const eyebrow = document.createElement("p");
    eyebrow.className = "eyebrow";
    eyebrow.textContent = content.kind === "waiting" ? "等待用户操作" : "任务已完成";

    const title = document.createElement("h1");
    title.className = "attention-title";
    title.textContent = content.title;

    const detail = document.createElement("p");
    detail.className = "attention-detail";
    const workspace = document.createElement("span");
    workspace.className = "attention-workspace";
    workspace.textContent = content.workspace;
    detail.append(workspace);
    if (content.summary) {
      const separator = document.createElement("span");
      separator.className = "attention-separator";
      separator.setAttribute("aria-hidden", "true");
      separator.textContent = "·";
      const summary = document.createElement("span");
      summary.className = "attention-summary";
      summary.textContent = content.summary;
      detail.append(separator, summary);
    }

    copy.append(eyebrow, title, detail);
    root.replaceChildren(mark, copy);
    createIcons({ icons: { BellRing, CircleCheck, X } });
  };
  void window.zcodeStatus.getAttentionContent().then(update);
  window.zcodeStatus.onAttentionContent(update);
};

const root = document.querySelector<HTMLElement>("#app");
if (!root) {
  throw new Error("Renderer root is missing.");
}

switch (window.zcodeStatus.getSurface()) {
  case "settings":
    renderSettings(root);
    break;
  case "attention":
    renderAttention(root);
    break;
  case "panel":
    renderPanel(root);
    break;
}

createIcons({ icons: { BellRing, CircleCheck, Settings, X } });
