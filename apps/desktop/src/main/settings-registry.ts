import { execFile as execFileCallback } from "node:child_process";
import { promisify } from "node:util";
import { DEFAULT_CONFIG, normalizeConfig, type AppConfig, type ConfigInput } from "../shared/config";

const execFile = promisify(execFileCallback);
const REGISTRY_COMMAND_TIMEOUT_MS = 2_000;
export const SETTINGS_REGISTRY_KEY = "HKCU\\Software\\ZCodeStatusLight";

const registryName: Readonly<Record<keyof AppConfig, string>> = {
  corner: "corner",
  marginX: "margin_x",
  marginY: "margin_y",
  displayId: "display_id",
  opacity: "opacity",
  showIdle: "show_idle",
  showTodoProgress: "show_todo_progress",
  showDuration: "show_duration",
  panelWidth: "panel_width",
  scale: "scale",
  doneTtlMinutes: "done_ttl_minutes",
  attentionMode: "attention_mode",
  attentionDurationMs: "attention_duration_ms",
  launchOnStartup: "launch_on_startup",
  showPanel: "show_panel",
};

export const parseRegistryValues = (output: string): Record<string, string> => output.split(/\r?\n/).reduce<Record<string, string>>((values, line) => {
  const parts = line.trim().split(/\s+/);
  if (parts.length >= 3) {
    const [name] = parts;
    if (name) {
      values[name] = parts.at(-1) ?? "";
    }
  }
  return values;
}, {});

export const serializeRegistryValue = (key: keyof AppConfig, value: AppConfig[keyof AppConfig]): string => {
  if (key === "attentionMode") {
    return String(value).replaceAll("-", "_");
  }
  return typeof value === "boolean" ? String(Number(value)) : String(value);
};

export class SettingsRegistry {
  /** True when the last load() could not read the registry and fell back to defaults. */
  public lastLoadDegraded = false;

  public async load(): Promise<AppConfig> {
    if (process.platform !== "win32") {
      this.lastLoadDegraded = false;
      return DEFAULT_CONFIG;
    }
    try {
      const { stdout } = await execFile("reg", ["query", SETTINGS_REGISTRY_KEY], {
        windowsHide: true,
        encoding: "utf8",
        timeout: REGISTRY_COMMAND_TIMEOUT_MS,
      });
      const values = parseRegistryValues(stdout);
      this.lastLoadDegraded = false;
      return normalizeConfig({
        corner: values.corner,
        marginX: values.margin_x,
        marginY: values.margin_y,
        displayId: values.display_id,
        opacity: values.opacity,
        showIdle: values.show_idle,
        showTodoProgress: values.show_todo_progress,
        showDuration: values.show_duration,
        panelWidth: values.panel_width,
        scale: values.scale,
        doneTtlMinutes: values.done_ttl_minutes,
        attentionMode: values.attention_mode,
        attentionDurationMs: values.attention_duration_ms,
        launchOnStartup: values.launch_on_startup,
        showPanel: values.show_panel,
      });
    } catch {
      this.lastLoadDegraded = true;
      return DEFAULT_CONFIG;
    }
  }

  public async save(candidate: ConfigInput): Promise<AppConfig> {
    const config = normalizeConfig(candidate);
    await this.persist(config);
    return config;
  }

  public async persist(config: AppConfig): Promise<void> {
    if (process.platform !== "win32") {
      return;
    }
    const results = await Promise.allSettled(
      Object.entries(registryName).map(async ([key, name]) => {
        const value = config[key as keyof AppConfig];
        const serialized = serializeRegistryValue(key as keyof AppConfig, value);
        await execFile("reg", ["add", SETTINGS_REGISTRY_KEY, "/v", name, "/t", "REG_SZ", "/d", serialized, "/f"], {
          windowsHide: true,
          encoding: "utf8",
          timeout: REGISTRY_COMMAND_TIMEOUT_MS,
        });
      }),
    );
    const failures = results
      .filter((result): result is PromiseRejectedResult => result.status === "rejected")
      .map((result) => result.reason);
    if (failures.length > 0) {
      throw new AggregateError(failures, "Windows 设置保存失败。");
    }
  }
}
