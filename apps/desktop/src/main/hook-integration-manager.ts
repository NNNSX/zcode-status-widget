import { access, mkdir, open, readFile, rename, rm, writeFile } from "node:fs/promises";
import { constants } from "node:fs";
import os from "node:os";
import path from "node:path";
import type { HookSetupSnapshot, HookSetupStatus } from "../shared/hook-setup";
import {
  defaultZcodeConfigPath,
  hookRuleSpecs,
  isManagedHookRule,
  mergeHookConfig,
  removeManagedHookRules,
  sessionDatabasePath,
  validateHookConfig,
  type HookIntegrationState,
} from "./hook-integration";

const backupDirectoryName = ".zcode-status-light-backups";
const stateFileName = "electron-integration-state.json";
const LOCK_RETRY_MS = 80;
const LOCK_TIMEOUT_MS = 2_000;
const hookHelperFileName = "zcodestatushook.exe";
const utf8 = new TextDecoder("utf-8", { fatal: true });

const objectValue = (value: unknown): Record<string, unknown> | undefined => (
  value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : undefined
);

const pathKey = (value: string): string => path.normalize(value).replace(/[\\/]+$/, "").toLocaleLowerCase();

const isRegularFile = async (candidate: string): Promise<boolean> => {
  try {
    await access(candidate, constants.F_OK);
    return true;
  } catch {
    return false;
  }
};

const parseConfig = (bytes: Uint8Array, configPath: string): { readonly config: Record<string, unknown>; readonly hasBom: boolean } => {
  const hasBom = bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf;
  let parsed: unknown;
  try {
    parsed = JSON.parse(utf8.decode(hasBom ? bytes.subarray(3) : bytes));
  } catch {
    throw new Error(`ZCode 配置不是有效 JSON：${configPath}`);
  }
  return { config: validateHookConfig(parsed).config, hasBom };
};

const temporaryPath = (targetPath: string, suffix: string): string => path.join(
  path.dirname(targetPath),
  `.${path.basename(targetPath)}.${process.pid}.${Date.now()}.${suffix}`,
);

const delay = (durationMs: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, durationMs));

const sameBytes = (left: Uint8Array, right: Uint8Array): boolean => (
  left.length === right.length && left.every((value, index) => value === right[index])
);

export const defaultIntegrationStatePath = (appDataPath: string): string => (
  path.join(appDataPath, "ZCodeStatusLight", stateFileName)
);

export const defaultHookConfigPath = (): string => defaultZcodeConfigPath(os.homedir());

export interface HookIntegrationManagerOptions {
  readonly executablePath: string;
  readonly statePath: string;
  readonly defaultConfigPath?: string;
}

export class HookIntegrationManager {
  private static readonly pendingOperations = new Map<string, Promise<void>>();

  private readonly executablePath: string;
  private readonly statePath: string;
  private readonly defaultConfigPath: string;

  public constructor(options: HookIntegrationManagerOptions) {
    this.executablePath = path.resolve(options.executablePath);
    this.statePath = path.resolve(options.statePath);
    this.defaultConfigPath = path.resolve(options.defaultConfigPath ?? defaultHookConfigPath());
  }

  public async suggestedConfigPath(): Promise<string> {
    const state = await this.readState();
    if (
      state
      && path.basename(state.configPath).toLocaleLowerCase() === "config.json"
      && path.basename(state.executablePath).toLocaleLowerCase() === "zcodestatushook.exe"
      && path.basename(this.executablePath).toLocaleLowerCase() === "zcodestatushook.exe"
    ) {
      return state.configPath;
    }
    return this.defaultConfigPath;
  }

  public async inspect(requestedPath?: string): Promise<HookSetupSnapshot> {
    const configPath = this.resolveConfigPath(requestedPath ?? await this.suggestedConfigPath());
    const databasePath = sessionDatabasePath(configPath);
    if (!await isRegularFile(configPath)) {
      return this.snapshot(configPath, databasePath, "missing", "未找到 ZCode 配置文件。请先启动 ZCode，或选择实际的 config.json。", false, false);
    }

    let config: Record<string, unknown>;
    let hooks: Record<string, unknown> | undefined;
    try {
      const parsed = parseConfig(await readFile(configPath), configPath);
      config = parsed.config;
      hooks = validateHookConfig(config).hooks;
    } catch (error) {
      return this.snapshot(configPath, databasePath, "invalid", this.messageFor(error), false, false);
    }

    if (hooks?.enabled === false) {
      return this.snapshot(configPath, databasePath, "disabled", "ZCode Hooks 已被明确关闭。只有确认后才会启用并添加状态 Hook。", false, true);
    }
    if (this.isFullyConfigured(config, databasePath)) {
      return this.snapshot(configPath, databasePath, "configured", "已配置 6 条本机状态 Hook。", true, false);
    }
    return this.snapshot(configPath, databasePath, "ready", "将添加 6 条仅发送到本机回环地址的状态 Hook。", false, false);
  }

  public async configure(requestedPath?: string, enableDisabledHooks = false): Promise<HookSetupSnapshot> {
    return this.serialize(() => this.configureUnlocked(requestedPath, enableDisabledHooks));
  }

  public async unconfigure(): Promise<boolean> {
    return this.serialize(() => this.unconfigureUnlocked());
  }

  private async configureUnlocked(requestedPath: string | undefined, enableDisabledHooks: boolean): Promise<HookSetupSnapshot> {
    const initial = await this.inspect(requestedPath);
    if (initial.status === "missing" || initial.status === "invalid") {
      throw new Error(initial.message);
    }
    return this.withConfigLock(initial.configPath, async () => {
      const before = await this.inspect(initial.configPath);
      if (before.status === "missing" || before.status === "invalid") {
        throw new Error(before.message);
      }
      if (before.status === "disabled" && !enableDisabledHooks) {
        throw new Error("ZCode Hooks 当前已被明确关闭；请单独确认启用后再配置。");
      }
      if (!await isRegularFile(this.executablePath)) {
        throw new Error("本机 Hook 助手文件缺失，无法修改 ZCode 配置。");
      }

      const raw = await readFile(before.configPath);
      const stateRaw = await this.readOptionalRaw(this.statePath);
      const parsed = parseConfig(raw, before.configPath);
      const recordedState = await this.readState();
      const merged = this.mergeForCurrentExecutable(
        parsed.config,
        before.databasePath,
        enableDisabledHooks,
        recordedState && pathKey(recordedState.configPath) === pathKey(before.configPath) ? recordedState : undefined,
      );
      const backupPath = await this.backup(before.configPath, raw, "before-setup");
      const nextState: HookIntegrationState = {
        version: 1,
        configPath: before.configPath,
        executablePath: this.executablePath,
        databasePath: before.databasePath,
        backupPath,
        installedAt: new Date().toISOString(),
      };
      let writtenConfig: Uint8Array | undefined;
      let writtenState: Uint8Array | undefined;
      try {
        await this.assertUnchanged(before.configPath, raw, "配置文件");
        writtenConfig = await this.writeConfigAtomically(before.configPath, merged.config, parsed.hasBom);
        await this.assertUnchanged(before.configPath, writtenConfig, "配置文件");
        const verified = await this.inspect(before.configPath);
        if (!verified.isConfigured) {
          throw new Error("写入后未能验证全部状态 Hook。");
        }
        await this.assertUnchanged(before.configPath, writtenConfig, "配置文件");
        await this.assertOptionalUnchanged(this.statePath, stateRaw, "集成状态记录");
        writtenState = await this.writeState(nextState);
        await this.assertUnchanged(this.statePath, writtenState, "集成状态记录");
        await this.assertUnchanged(before.configPath, writtenConfig, "配置文件");
        return verified;
      } catch (error) {
        const recovery = await this.recoverTransaction({
          configPath: before.configPath,
          configRaw: raw,
          writtenConfig,
          stateRaw,
          writtenState,
        });
        throw this.transactionError(error, recovery);
      }
    });
  }

  private async unconfigureUnlocked(): Promise<boolean> {
    const initialState = await this.readState();
    if (
      !initialState
      || pathKey(initialState.executablePath) !== pathKey(this.executablePath)
      || !await isRegularFile(initialState.configPath)
    ) {
      return false;
    }
    return this.withConfigLock(initialState.configPath, async () => {
      const state = await this.readState();
      if (
        !state
        || pathKey(state.executablePath) !== pathKey(this.executablePath)
        || !await isRegularFile(state.configPath)
      ) {
        return false;
      }
      const raw = await readFile(state.configPath);
      const stateRaw = await this.readOptionalRaw(this.statePath);
      if (!stateRaw) {
        return false;
      }
      const parsed = parseConfig(raw, state.configPath);
      const source = parsed.config;
      const next = removeManagedHookRules(source, state.executablePath, state.databasePath);
      let writtenConfig: Uint8Array | undefined;
      try {
        if (JSON.stringify(next) !== JSON.stringify(source)) {
          await this.backup(state.configPath, raw, "before-unconfigure");
          await this.assertUnchanged(state.configPath, raw, "配置文件");
          writtenConfig = await this.writeConfigAtomically(state.configPath, next, parsed.hasBom);
          await this.assertUnchanged(state.configPath, writtenConfig, "配置文件");
          if (this.countManagedRules(await readFile(state.configPath), state.configPath, state.executablePath, state.databasePath) !== 0) {
            throw new Error("写入后仍检测到本程序管理的状态 Hook。");
          }
          await this.assertUnchanged(state.configPath, writtenConfig, "配置文件");
        }
        await this.removeStateIfUnchanged(stateRaw);
        return true;
      } catch (error) {
        const recovery = await this.recoverTransaction({
          configPath: state.configPath,
          configRaw: raw,
          writtenConfig,
          stateRaw,
        });
        throw this.transactionError(error, recovery);
      }
    });
  }

  private mergeForCurrentExecutable(
    source: Record<string, unknown>,
    databasePath: string,
    enableDisabledHooks: boolean,
    state: HookIntegrationState | undefined,
  ): { readonly config: Record<string, unknown>; readonly enabledWasFalse: boolean } {
    const migrated = state && this.isManagedHelperPath(state.executablePath) && this.isManagedHelperPath(this.executablePath)
      && pathKey(state.executablePath) !== pathKey(this.executablePath)
      ? removeManagedHookRules(source, state.executablePath, state.databasePath)
      : source;
    return mergeHookConfig(migrated, this.executablePath, databasePath, enableDisabledHooks);
  }

  private isManagedHelperPath(candidate: string): boolean {
    return path.basename(candidate).toLocaleLowerCase() === hookHelperFileName;
  }

  private isFullyConfigured(config: Record<string, unknown>, databasePath: string): boolean {
    return hookRuleSpecs.every((spec) => this.managedRuleOccurrences(config, spec, databasePath) === 1);
  }

  private managedRuleOccurrences(
    config: Record<string, unknown>,
    spec: typeof hookRuleSpecs[number],
    databasePath: string,
    executablePath = this.executablePath,
  ): number {
    const events = validateHookConfig(config).events;
    const eventRules = events?.[spec.event];
    const rules: unknown[] = Array.isArray(eventRules) ? eventRules : [];
    return rules.filter((rule) => isManagedHookRule(rule, spec, executablePath, databasePath)).length;
  }

  private managedRuleCount(
    config: Record<string, unknown>,
    databasePath: string,
    executablePath = this.executablePath,
  ): number {
    return hookRuleSpecs.reduce(
      (total, spec) => total + this.managedRuleOccurrences(config, spec, databasePath, executablePath),
      0,
    );
  }

  private countManagedRules(
    raw: Uint8Array,
    configPath: string,
    executablePath = this.executablePath,
    databasePath = sessionDatabasePath(configPath),
  ): number {
    return this.managedRuleCount(parseConfig(raw, configPath).config, databasePath, executablePath);
  }

  private async serialize<T>(operation: () => Promise<T>): Promise<T> {
    const key = pathKey(this.statePath);
    const previous = HookIntegrationManager.pendingOperations.get(key) ?? Promise.resolve();
    let release: (() => void) | undefined;
    const pending = new Promise<void>((resolve) => { release = resolve; });
    HookIntegrationManager.pendingOperations.set(key, pending);
    await previous.catch(() => undefined);
    try {
      return await operation();
    } finally {
      release?.();
      if (HookIntegrationManager.pendingOperations.get(key) === pending) {
        HookIntegrationManager.pendingOperations.delete(key);
      }
    }
  }

  private async withConfigLock<T>(configPath: string, operation: () => Promise<T>): Promise<T> {
    const lockPath = path.join(path.dirname(configPath), ".zcode-status-light.lock");
    const deadline = Date.now() + LOCK_TIMEOUT_MS;
    let handle: Awaited<ReturnType<typeof open>> | undefined;
    while (!handle) {
      try {
        handle = await open(lockPath, "wx");
      } catch (error) {
        const code = error && typeof error === "object" && "code" in error ? String(error.code) : "";
        if (code !== "EEXIST" || Date.now() >= deadline) {
          throw new Error("ZCode 配置正在被其他状态灯操作修改；请稍后重试。");
        }
        await delay(LOCK_RETRY_MS);
      }
    }
    try {
      return await operation();
    } finally {
      await handle.close().catch(() => undefined);
      await rm(lockPath, { force: true }).catch(() => undefined);
    }
  }

  private async assertUnchanged(targetPath: string, expected: Uint8Array, label = "配置文件"): Promise<void> {
    const current = await readFile(targetPath);
    if (!sameBytes(current, expected)) {
      throw new Error(`${label}在操作期间被其他程序修改，已停止写入。`);
    }
  }

  private async assertOptionalUnchanged(targetPath: string, expected: Uint8Array | undefined, label: string): Promise<void> {
    const current = await this.readOptionalRaw(targetPath);
    if ((expected && (!current || !sameBytes(current, expected))) || (!expected && current)) {
      throw new Error(`${label}在操作期间被其他程序修改，已停止写入。`);
    }
  }

  private async readOptionalRaw(targetPath: string): Promise<Uint8Array | undefined> {
    try {
      return await readFile(targetPath);
    } catch (error) {
      const code = error && typeof error === "object" && "code" in error ? String(error.code) : "";
      if (code === "ENOENT") {
        return undefined;
      }
      throw error;
    }
  }

  private async restoreRawIfUnchanged(
    targetPath: string,
    previous: Uint8Array | undefined,
    written: Uint8Array,
  ): Promise<boolean> {
    const current = await this.readOptionalRaw(targetPath);
    if (previous && current && sameBytes(current, previous)) {
      return true;
    }
    if (!previous && !current) {
      return true;
    }
    if (!current || !sameBytes(current, written)) {
      return false;
    }
    if (previous) {
      await this.restoreRaw(targetPath, previous);
    } else {
      await rm(targetPath);
    }
    return true;
  }

  private async recoverTransaction(input: {
    readonly configPath: string;
    readonly configRaw: Uint8Array;
    readonly writtenConfig: Uint8Array | undefined;
    readonly stateRaw: Uint8Array | undefined;
    readonly writtenState?: Uint8Array;
  }): Promise<readonly string[]> {
    const issues: string[] = [];
    if (input.writtenState) {
      try {
        if (!await this.restoreRawIfUnchanged(this.statePath, input.stateRaw, input.writtenState)) {
          issues.push("集成状态记录已被外部修改，未覆盖");
        }
      } catch {
        issues.push("集成状态记录恢复失败");
      }
    }
    if (input.writtenConfig) {
      try {
        if (!await this.restoreRawIfUnchanged(input.configPath, input.configRaw, input.writtenConfig)) {
          issues.push("配置文件已被外部修改，未覆盖");
        }
      } catch {
        issues.push("配置文件恢复失败");
      }
    }
    return issues;
  }

  private transactionError(error: unknown, recovery: readonly string[]): Error {
    const message = this.messageFor(error);
    return recovery.length === 0 ? new Error(message) : new Error(`${message} ${recovery.join("；")}。`);
  }

  private async removeStateIfUnchanged(expected: Uint8Array): Promise<void> {
    await this.assertUnchanged(this.statePath, expected, "集成状态记录");
    await rm(this.statePath);
  }

  private resolveConfigPath(requestedPath?: string): string {
    const candidate = requestedPath?.trim() || this.defaultConfigPath;
    if (path.basename(candidate).toLocaleLowerCase() !== "config.json") {
      throw new Error("只能选择 ZCode 的 config.json 文件。");
    }
    return path.resolve(candidate);
  }

  private snapshot(
    configPath: string,
    databasePath: string,
    status: HookSetupStatus,
    message: string,
    isConfigured: boolean,
    requiresEnableConfirmation: boolean,
  ): HookSetupSnapshot {
    return {
      configPath,
      databasePath,
      status,
      message,
      isConfigured,
      requiresEnableConfirmation,
      ruleCount: hookRuleSpecs.length,
    };
  }

  private async backup(configPath: string, raw: Uint8Array, operation: string): Promise<string> {
    const directory = path.join(path.dirname(configPath), backupDirectoryName);
    await mkdir(directory, { recursive: true });
    const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
    const backupPath = path.join(directory, `config-${operation}-${timestamp}.json`);
    await writeFile(backupPath, raw, { flag: "wx" });
    return backupPath;
  }

  private async writeConfigAtomically(
    configPath: string,
    config: Record<string, unknown>,
    hasBom = false,
  ): Promise<Uint8Array> {
    const temporary = temporaryPath(configPath, "tmp");
    const encoded = `${hasBom ? "\uFEFF" : ""}${JSON.stringify(config, null, 2)}\n`;
    const written = Buffer.from(encoded, "utf8");
    try {
      await writeFile(temporary, written, { flag: "wx" });
      await rename(temporary, configPath);
      return written;
    } finally {
      await rm(temporary, { force: true });
    }
  }

  private async restoreRaw(configPath: string, raw: Uint8Array): Promise<void> {
    const temporary = temporaryPath(configPath, "restore");
    try {
      await writeFile(temporary, raw, { flag: "wx" });
      await rename(temporary, configPath);
    } finally {
      await rm(temporary, { force: true });
    }
  }

  private async readState(): Promise<HookIntegrationState | undefined> {
    if (!await isRegularFile(this.statePath)) {
      return undefined;
    }
    try {
      const value = JSON.parse(await readFile(this.statePath, "utf8")) as unknown;
      const state = objectValue(value);
      if (
        state?.version !== 1
        || typeof state.configPath !== "string"
        || typeof state.executablePath !== "string"
        || typeof state.databasePath !== "string"
        || typeof state.backupPath !== "string"
        || typeof state.installedAt !== "string"
      ) {
        return undefined;
      }
      return {
        version: 1,
        configPath: state.configPath,
        executablePath: state.executablePath,
        databasePath: state.databasePath,
        backupPath: state.backupPath,
        installedAt: state.installedAt,
      };
    } catch {
      return undefined;
    }
  }

  private async writeState(state: HookIntegrationState): Promise<Uint8Array> {
    await mkdir(path.dirname(this.statePath), { recursive: true });
    const temporary = temporaryPath(this.statePath, "tmp");
    const written = Buffer.from(`${JSON.stringify(state, null, 2)}\n`, "utf8");
    try {
      await writeFile(temporary, written, { flag: "wx" });
      await rename(temporary, this.statePath);
      return written;
    } finally {
      await rm(temporary, { force: true });
    }
  }

  private messageFor(error: unknown): string {
    return error instanceof Error ? error.message : "无法读取 ZCode 配置。";
  }
}
