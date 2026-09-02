import { describe, expect, it } from "vitest";
import {
  hookRuleSpecs,
  isManagedHookRule,
  mergeHookConfig,
  removeManagedHookRules,
} from "../src/main/hook-integration";

const executablePath = "C:\\Program Files\\ZCode Status Light\\resources\\hook\\ZCodeStatusHook.exe";
const databasePath = "C:\\Users\\Test User\\.zcode\\cli\\db\\db.sqlite";

const managedRuleCount = (config: Record<string, unknown>): number => {
  const hooks = config.hooks as { events?: Record<string, unknown[]> } | undefined;
  const events = hooks?.events ?? {};
  return hookRuleSpecs.reduce((total, spec) => {
    const rules = events[spec.event] ?? [];
    return total + Number(rules.some((rule) => isManagedHookRule(rule, spec, executablePath, databasePath)));
  }, 0);
};

describe("Hook integration config", () => {
  it("merges six managed rules without changing third-party config", () => {
    const source = {
      mcp: { servers: { retained: { command: "third-party" } } },
      plugins: { enabled: ["plugin-a"] },
      hooks: {
        events: {
          Stop: [{ hooks: [{ type: "process", command: "third-party.exe", args: [], timeoutMs: 1000 }] }],
        },
      },
    };

    const result = mergeHookConfig(source, executablePath, databasePath);
    const stopRules = (result.config.hooks as { events: Record<string, unknown[]> }).events.Stop;

    expect(result.enabledWasFalse).toBe(false);
    expect(result.config.mcp).toEqual(source.mcp);
    expect(result.config.plugins).toEqual(source.plugins);
    expect((result.config.hooks as { enabled: boolean }).enabled).toBe(true);
    expect(stopRules).toHaveLength(2);
    expect(managedRuleCount(result.config)).toBe(6);
  });

  it("is idempotent for managed rules when executable and database paths contain spaces", () => {
    const first = mergeHookConfig({ hooks: { enabled: true, events: {} } }, executablePath, databasePath).config;
    const second = mergeHookConfig(first, executablePath, databasePath).config;

    expect(second).toEqual(first);
    expect(managedRuleCount(second)).toBe(6);
  });

  it("recognizes equivalent Windows path spellings for exact managed rules", () => {
    const config = mergeHookConfig({ hooks: { enabled: true, events: {} } }, executablePath, databasePath).config;
    const rules = (config.hooks as { events: Record<string, unknown[]> }).events.Stop ?? [];

    expect(isManagedHookRule(
      rules[0],
      hookRuleSpecs.find((spec) => spec.event === "Stop")!,
      "c:/program files/ZCode Status Light/resources/hook/ZCodeStatusHook.exe",
      "c:/users/Test User/.zcode/cli/db/db.sqlite",
    )).toBe(true);
  });

  it("requires a separate confirmation before enabling explicitly disabled hooks", () => {
    const source = { hooks: { enabled: false, events: {} } };

    expect(() => mergeHookConfig(source, executablePath, databasePath)).toThrow("明确关闭");
    const result = mergeHookConfig(source, executablePath, databasePath, true);

    expect(result.enabledWasFalse).toBe(true);
    expect((result.config.hooks as { enabled: boolean }).enabled).toBe(true);
  });

  it("removes only exact managed rules and leaves similar or third-party rules intact", () => {
    const configured = mergeHookConfig({ hooks: { enabled: true, events: {} } }, executablePath, databasePath).config;
    const events = (configured.hooks as { events: Record<string, unknown[]> }).events;
    const stopRules = events.Stop ?? [];
    events.Stop = [
      ...stopRules,
      { hooks: [{ type: "process", command: executablePath, args: ["stop", "${CLAUDE_SESSION_ID}", "${ZCODE_PROJECT_DIR}", "C:\\other\\db.sqlite"], timeoutMs: 5000 }] },
      { hooks: [{ type: "process", command: "third-party.exe", args: [], timeoutMs: 1000 }] },
    ];

    const removed = removeManagedHookRules(configured, executablePath, databasePath);
    const remainingStopRules = (removed.hooks as { events: Record<string, unknown[]> }).events.Stop ?? [];

    expect(managedRuleCount(removed)).toBe(0);
    expect(remainingStopRules).toHaveLength(2);
  });

  it("does not claim rules with extra arguments and leaves them untouched during removal", () => {
    const configured = mergeHookConfig({ hooks: { enabled: true, events: {} } }, executablePath, databasePath).config;
    const events = (configured.hooks as { events: Record<string, unknown[]> }).events;
    const stop = events.Stop?.[0] as { hooks: [{ args: unknown[] }] };
    const similar = structuredClone(stop) as { hooks: [{ args: unknown[] }] };
    similar.hooks[0].args.push("third-party-option");
    events.Stop = [stop, similar];

    expect(isManagedHookRule(similar, hookRuleSpecs.find((spec) => spec.event === "Stop")!, executablePath, databasePath)).toBe(false);
    const removed = removeManagedHookRules(configured, executablePath, databasePath);

    expect((removed.hooks as { events: Record<string, unknown[]> }).events.Stop).toEqual([similar]);
  });

  it("rejects non-array event rules instead of overwriting them", () => {
    expect(() => mergeHookConfig({ hooks: { events: { Stop: {} } } }, executablePath, databasePath)).toThrow("hooks.events.Stop 必须是数组");
    expect(() => removeManagedHookRules({ hooks: { events: { Stop: "invalid" } } }, executablePath, databasePath)).toThrow("hooks.events.Stop 必须是数组");
  });

  it("rejects non-object configuration and malformed hooks sections", () => {
    expect(() => mergeHookConfig([], executablePath, databasePath)).toThrow("JSON 对象");
    expect(() => mergeHookConfig({ hooks: [] }, executablePath, databasePath)).toThrow("hooks 必须是对象");
    expect(() => mergeHookConfig({ hooks: { events: [] } }, executablePath, databasePath)).toThrow("hooks.events 必须是对象");
  });
});
