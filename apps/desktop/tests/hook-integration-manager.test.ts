import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { HookIntegrationManager } from "../src/main/hook-integration-manager";

const temporaryRoots: string[] = [];

const createFixture = async (): Promise<{
  readonly root: string;
  readonly configPath: string;
  readonly executablePath: string;
  readonly statePath: string;
}> => {
  const root = await mkdtemp(path.join(os.tmpdir(), "zcode-status-hook-test-"));
  temporaryRoots.push(root);
  const configPath = path.join(root, "config.json");
  const executablePath = path.join(root, "ZCodeStatusHook.exe");
  const statePath = path.join(root, "app-data", "electron-integration-state.json");
  await writeFile(executablePath, "helper", "utf8");
  return { root, configPath, executablePath, statePath };
};

const managerFor = (fixture: Awaited<ReturnType<typeof createFixture>>): HookIntegrationManager => new HookIntegrationManager({
  executablePath: fixture.executablePath,
  statePath: fixture.statePath,
  defaultConfigPath: fixture.configPath,
});

afterEach(async () => {
  await Promise.all(temporaryRoots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe("HookIntegrationManager", () => {
  it("backs up and merges only its six rules while preserving unknown configuration", async () => {
    const fixture = await createFixture();
    const source = {
      mcp: { servers: { existing: { command: "tool" } } },
      plugins: { enabled: ["existing"] },
      hooks: {
        enabled: true,
        events: {
          UserPromptSubmit: [{ hooks: [{ type: "process", command: "third-party", args: [], timeoutMs: 1000 }] }],
          Stop: [{ matcher: "third-party", hooks: [{ type: "process", command: "third-party", args: [], timeoutMs: 1000 }] }],
        },
      },
    };
    await writeFile(fixture.configPath, JSON.stringify(source), "utf8");

    const manager = managerFor(fixture);
    const result = await manager.configure();
    const written = JSON.parse(await readFile(fixture.configPath, "utf8")) as typeof source & { hooks: { events: Record<string, unknown[]> } };

    expect(result).toMatchObject({ status: "configured", isConfigured: true, ruleCount: 6 });
    expect(written.mcp).toEqual(source.mcp);
    expect(written.plugins).toEqual(source.plugins);
    expect(written.hooks.events.UserPromptSubmit).toHaveLength(2);
    expect(written.hooks.events.Stop).toHaveLength(2);
    const backupDirectory = path.join(fixture.root, ".zcode-status-light-backups");
    const { readdir } = await import("node:fs/promises");
    await expect(readdir(backupDirectory)).resolves.toHaveLength(1);
    expect(JSON.parse(await readFile(fixture.statePath, "utf8"))).toMatchObject({ configPath: fixture.configPath });
  });

  it("requires an explicit confirmation before enabling disabled hooks", async () => {
    const fixture = await createFixture();
    const source = { hooks: { enabled: false, events: {} }, mcp: { retained: true } };
    await writeFile(fixture.configPath, JSON.stringify(source), "utf8");

    const manager = managerFor(fixture);
    await expect(manager.configure()).rejects.toThrow("单独确认");
    expect(JSON.parse(await readFile(fixture.configPath, "utf8"))).toEqual(source);

    const configured = await manager.configure(undefined, true);
    expect(configured.status).toBe("configured");
    expect(JSON.parse(await readFile(fixture.configPath, "utf8"))).toMatchObject({ hooks: { enabled: true }, mcp: source.mcp });
  });

  it("removes only its exact rules and retains third-party hooks", async () => {
    const fixture = await createFixture();
    await writeFile(fixture.configPath, JSON.stringify({
      hooks: {
        enabled: true,
        events: {
          Stop: [{ hooks: [{ type: "process", command: "third-party", args: [], timeoutMs: 1000 }] }],
        },
      },
    }), "utf8");

    const manager = managerFor(fixture);
    await manager.configure();
    expect(await manager.unconfigure()).toBe(true);
    const written = JSON.parse(await readFile(fixture.configPath, "utf8")) as { hooks: { events: Record<string, unknown[]> } };

    expect(written.hooks.events.Stop).toHaveLength(1);
    expect(await manager.unconfigure()).toBe(false);
  });

  it("uses the recorded custom config path when inspecting after restart", async () => {
    const fixture = await createFixture();
    const customDirectory = path.join(fixture.root, "custom profile");
    const customConfigPath = path.join(customDirectory, "config.json");
    await mkdir(customDirectory, { recursive: true });
    await writeFile(fixture.configPath, JSON.stringify({ hooks: { enabled: true, events: {} } }), "utf8");
    await writeFile(customConfigPath, JSON.stringify({ hooks: { enabled: true, events: {} } }), "utf8");

    const manager = managerFor(fixture);
    await manager.configure(customConfigPath);

    const restartedManager = managerFor(fixture);
    await expect(restartedManager.inspect()).resolves.toMatchObject({
      configPath: customConfigPath,
      status: "configured",
      isConfigured: true,
    });
  });

  it("does not restore a recorded custom path for a different hook helper", async () => {
    const fixture = await createFixture();
    const customDirectory = path.join(fixture.root, "custom profile");
    const customConfigPath = path.join(customDirectory, "config.json");
    await mkdir(customDirectory, { recursive: true });
    await writeFile(fixture.configPath, JSON.stringify({ hooks: { enabled: true, events: {} } }), "utf8");
    await writeFile(customConfigPath, JSON.stringify({ hooks: { enabled: true, events: {} } }), "utf8");

    const manager = managerFor(fixture);
    await manager.configure(customConfigPath);

    const otherExecutablePath = path.join(fixture.root, "other-helper.exe");
    await writeFile(otherExecutablePath, "helper", "utf8");
    const restartedManager = new HookIntegrationManager({
      executablePath: otherExecutablePath,
      statePath: fixture.statePath,
      defaultConfigPath: fixture.configPath,
    });

    await expect(restartedManager.inspect()).resolves.toMatchObject({
      configPath: fixture.configPath,
      status: "ready",
      isConfigured: false,
    });
  });

  it("migrates only recorded hook rules to a new installation path", async () => {
    const fixture = await createFixture();
    await writeFile(fixture.configPath, JSON.stringify({ hooks: { enabled: true, events: {} } }), "utf8");
    const originalManager = managerFor(fixture);
    await originalManager.configure();

    const nextDirectory = path.join(fixture.root, "next-install");
    const nextExecutablePath = path.join(nextDirectory, "ZCodeStatusHook.exe");
    await mkdir(nextDirectory, { recursive: true });
    await writeFile(nextExecutablePath, "helper", "utf8");
    const upgradedManager = new HookIntegrationManager({
      executablePath: nextExecutablePath,
      statePath: fixture.statePath,
      defaultConfigPath: fixture.configPath,
    });

    await expect(upgradedManager.inspect()).resolves.toMatchObject({ configPath: fixture.configPath, status: "ready" });
    await upgradedManager.configure();
    const written = await readFile(fixture.configPath, "utf8");
    expect(written).toContain(nextExecutablePath.replaceAll("\\", "\\\\"));
    expect(written).not.toContain(fixture.executablePath.replaceAll("\\", "\\\\"));
    await expect(upgradedManager.unconfigure()).resolves.toBe(true);
  });

  it("reports fully present rules as disabled until the user explicitly re-enables hooks", async () => {
    const fixture = await createFixture();
    const configuredManager = managerFor(fixture);
    await writeFile(fixture.configPath, JSON.stringify({ hooks: { enabled: true, events: {} } }), "utf8");
    await configuredManager.configure();
    const configured = JSON.parse(await readFile(fixture.configPath, "utf8")) as { hooks: { enabled: boolean } };
    configured.hooks.enabled = false;
    await writeFile(fixture.configPath, JSON.stringify(configured), "utf8");

    const manager = managerFor(fixture);
    await expect(manager.inspect()).resolves.toMatchObject({
      status: "disabled",
      isConfigured: false,
      requiresEnableConfirmation: true,
    });
  });

  it("serializes concurrent configuration requests without duplicate rules", async () => {
    const fixture = await createFixture();
    await writeFile(fixture.configPath, JSON.stringify({ hooks: { enabled: true, events: {} } }), "utf8");
    const manager = managerFor(fixture);

    const [first, second] = await Promise.all([manager.configure(), manager.configure()]);
    expect(first.isConfigured).toBe(true);
    expect(second.isConfigured).toBe(true);
    const written = JSON.parse(await readFile(fixture.configPath, "utf8")) as { hooks: { events: Record<string, unknown[]> } };
    expect(written.hooks.events.Stop).toHaveLength(1);
  });

  it("serializes configure and unconfigure across manager instances sharing state", async () => {
    const fixture = await createFixture();
    await writeFile(fixture.configPath, JSON.stringify({ hooks: { enabled: true, events: {} } }), "utf8");
    const configuringManager = managerFor(fixture);
    const removingManager = managerFor(fixture);
    const unsafeManager = configuringManager as unknown as {
      writeState(state: unknown): Promise<Uint8Array>;
    };
    const writeState = unsafeManager.writeState.bind(configuringManager);
    let releaseStateWrite: (() => void) | undefined;
    const stateWritePaused = new Promise<void>((resolve) => { releaseStateWrite = resolve; });
    let stateWriteEntered: (() => void) | undefined;
    const stateWriteStarted = new Promise<void>((resolve) => { stateWriteEntered = resolve; });
    unsafeManager.writeState = async (state) => {
      stateWriteEntered?.();
      await stateWritePaused;
      return writeState(state);
    };

    const configuring = configuringManager.configure();
    await stateWriteStarted;
    const removing = removingManager.unconfigure();
    releaseStateWrite?.();

    await expect(configuring).resolves.toMatchObject({ isConfigured: true });
    await expect(removing).resolves.toBe(true);
    const written = JSON.parse(await readFile(fixture.configPath, "utf8")) as { hooks: { events: Record<string, unknown[]> } };
    expect(written.hooks.events.Stop).toHaveLength(0);
    await expect(readFile(fixture.statePath, "utf8")).rejects.toThrow();
  });

  it("restores the original config when state persistence fails", async () => {
    const fixture = await createFixture();
    const source = JSON.stringify({ hooks: { enabled: true, events: {} }, retained: "value" });
    await writeFile(fixture.configPath, source, "utf8");
    const manager = managerFor(fixture);
    const unsafeManager = manager as unknown as {
      writeState(state: unknown): Promise<Uint8Array>;
    };
    unsafeManager.writeState = async () => {
      throw new Error("state write failed");
    };

    await expect(manager.configure()).rejects.toThrow("state write failed");
    await expect(readFile(fixture.configPath, "utf8")).resolves.toBe(source);
    await expect(readFile(fixture.statePath, "utf8")).rejects.toThrow();
  });

  it("restores managed rules when state removal fails", async () => {
    const fixture = await createFixture();
    await writeFile(fixture.configPath, JSON.stringify({ hooks: { enabled: true, events: {} } }), "utf8");
    const manager = managerFor(fixture);
    await manager.configure();
    const configuredRaw = await readFile(fixture.configPath);
    const unsafeManager = manager as unknown as {
      removeStateIfUnchanged(expected: Uint8Array): Promise<void>;
    };
    unsafeManager.removeStateIfUnchanged = async () => {
      throw new Error("state removal failed");
    };

    await expect(manager.unconfigure()).rejects.toThrow("state removal failed");
    await expect(readFile(fixture.configPath)).resolves.toEqual(configuredRaw);
    const restoredState = JSON.parse(await readFile(fixture.statePath, "utf8")) as { configPath: string };
    expect(restoredState.configPath).toBe(fixture.configPath);
  });

  it("keeps externally changed config content when a state write fails", async () => {
    const fixture = await createFixture();
    await writeFile(fixture.configPath, JSON.stringify({ hooks: { enabled: true, events: {} } }), "utf8");
    const manager = managerFor(fixture);
    const unsafeManager = manager as unknown as {
      writeState(state: unknown): Promise<Uint8Array>;
    };
    unsafeManager.writeState = async () => {
      await writeFile(fixture.configPath, JSON.stringify({ external: true }), "utf8");
      throw new Error("state write failed");
    };

    await expect(manager.configure()).rejects.toThrow("配置文件已被外部修改，未覆盖");
    await expect(readFile(fixture.configPath, "utf8")).resolves.toBe(JSON.stringify({ external: true }));
  });

  it("fails after a bounded wait when another transaction lock is present", async () => {
    const fixture = await createFixture();
    await writeFile(fixture.configPath, JSON.stringify({ hooks: { enabled: true, events: {} } }), "utf8");
    const lockPath = path.join(fixture.root, ".zcode-status-light.lock");
    await writeFile(lockPath, "locked", "utf8");
    const manager = managerFor(fixture);

    await expect(manager.configure()).rejects.toThrow("正在被其他状态灯操作修改");
    await expect(readFile(fixture.configPath, "utf8")).resolves.toBe(JSON.stringify({ hooks: { enabled: true, events: {} } }));
  });

  it("deduplicates managed rules but does not report duplicate rules as configured", async () => {
    const fixture = await createFixture();
    const configuredManager = managerFor(fixture);
    await writeFile(fixture.configPath, JSON.stringify({ hooks: { enabled: true, events: {} } }), "utf8");
    await configuredManager.configure();
    const configured = JSON.parse(await readFile(fixture.configPath, "utf8")) as { hooks: { events: { Stop: unknown[] } } };
    configured.hooks.events.Stop.push(structuredClone(configured.hooks.events.Stop[0]));
    await writeFile(fixture.configPath, JSON.stringify(configured), "utf8");

    const manager = managerFor(fixture);
    await expect(manager.inspect()).resolves.toMatchObject({ status: "ready", isConfigured: false });
    await manager.configure();
    const rewritten = JSON.parse(await readFile(fixture.configPath, "utf8")) as { hooks: { events: { Stop: unknown[] } } };
    expect(rewritten.hooks.events.Stop).toHaveLength(1);
  });

  it("preserves a UTF-8 BOM while configuring and removing hooks", async () => {
    const fixture = await createFixture();
    await writeFile(fixture.configPath, Buffer.from(`\uFEFF${JSON.stringify({ hooks: { enabled: true, events: {} } })}`, "utf8"));

    const manager = managerFor(fixture);
    await manager.configure();
    expect((await readFile(fixture.configPath)).subarray(0, 3)).toEqual(Buffer.from([0xef, 0xbb, 0xbf]));
    await manager.unconfigure();
    expect((await readFile(fixture.configPath)).subarray(0, 3)).toEqual(Buffer.from([0xef, 0xbb, 0xbf]));
  });

  it("rejects malformed event structures without modifying the source config", async () => {
    const fixture = await createFixture();
    const source = { hooks: { enabled: true, events: { Stop: { invalid: true } } } };
    await writeFile(fixture.configPath, JSON.stringify(source), "utf8");

    const manager = managerFor(fixture);
    await expect(manager.inspect()).resolves.toMatchObject({ status: "invalid" });
    await expect(manager.configure()).rejects.toThrow("hooks.events.Stop 必须是数组");
    await expect(readFile(fixture.configPath, "utf8")).resolves.toBe(JSON.stringify(source));
  });

  it("restores the original config when unconfigure verification finds a managed rule", async () => {
    const fixture = await createFixture();
    await writeFile(fixture.configPath, JSON.stringify({ hooks: { enabled: true, events: {} } }), "utf8");

    const manager = managerFor(fixture);
    await manager.configure();
    const configuredRaw = await readFile(fixture.configPath);
    const configured = JSON.parse(configuredRaw.toString("utf8")) as { hooks: { events: { Stop: unknown[] } } };
    const retainedRule = configured.hooks.events.Stop[0];
    const unsafeManager = manager as unknown as {
      writeConfigAtomically(configPath: string, config: Record<string, unknown>, hasBom?: boolean): Promise<Uint8Array>;
    };
    const writeConfigAtomically = unsafeManager.writeConfigAtomically.bind(manager);
    unsafeManager.writeConfigAtomically = async (configPath, config) => {
      const altered = structuredClone(config) as { hooks: { events: Record<string, unknown[]> } };
      altered.hooks.events.Stop = [...(altered.hooks.events.Stop ?? []), retainedRule];
      return writeConfigAtomically(configPath, altered);
    };

    await expect(manager.unconfigure()).rejects.toThrow("仍检测到本程序管理的状态 Hook");
    await expect(readFile(fixture.configPath)).resolves.toEqual(configuredRaw);
    const retainedState = JSON.parse(await readFile(fixture.statePath, "utf8")) as { configPath: string };
    expect(retainedState.configPath).toBe(fixture.configPath);
  });

  it("does not create a config file when no explicit ZCode configuration exists", async () => {
    const fixture = await createFixture();
    const manager = managerFor(fixture);

    await expect(manager.configure()).rejects.toThrow("未找到默认 Hook 配置");
    await expect(readFile(fixture.configPath, "utf8")).rejects.toThrow();
  });

  it("rejects provider-only configuration without modifying it", async () => {
    const fixture = await createFixture();
    const source = JSON.stringify({ provider: { endpoint: "https://provider.example" } });
    await writeFile(fixture.configPath, source, "utf8");
    const manager = managerFor(fixture);

    await expect(manager.inspect()).resolves.toMatchObject({
      status: "invalid",
      message: expect.stringContaining("provider 配置"),
    });
    await expect(manager.configure()).rejects.toThrow("provider 配置");
    await expect(readFile(fixture.configPath, "utf8")).resolves.toBe(source);
  });

  it("rejects the canonical ZCode provider path before reading or writing it", async () => {
    const fixture = await createFixture();
    const providerPath = path.join(os.homedir(), ".zcode", "v2", "config.json");
    const manager = managerFor(fixture);

    await expect(manager.inspect(providerPath)).resolves.toMatchObject({
      configPath: path.resolve(providerPath),
      status: "invalid",
      message: expect.stringContaining("provider 配置"),
    });
    await expect(manager.configure(providerPath)).rejects.toThrow("provider 配置");
  });
});
