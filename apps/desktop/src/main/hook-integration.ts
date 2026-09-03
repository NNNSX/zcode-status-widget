import path from "node:path";

export interface HookRuleSpec {
  readonly event: "UserPromptSubmit" | "PermissionRequest" | "PostToolUse" | "PostToolUseFailure" | "Stop";
  readonly matcher?: string;
  readonly token: "user_prompt_submit" | "permission_bash" | "permission_request" | "todo_update" | "tool_failure" | "stop";
}

export const hookRuleSpecs: readonly HookRuleSpec[] = [
  { event: "UserPromptSubmit", token: "user_prompt_submit" },
  { event: "PermissionRequest", matcher: "^Bash$", token: "permission_bash" },
  { event: "PermissionRequest", matcher: "^(?!Bash$).+", token: "permission_request" },
  { event: "PostToolUse", matcher: "TodoWrite", token: "todo_update" },
  { event: "PostToolUseFailure", token: "tool_failure" },
  { event: "Stop", token: "stop" },
] as const;

export interface HookExecutableLocation {
  readonly isPackaged: boolean;
  readonly resourcesPath: string;
  readonly dirname: string;
}

export const hookExecutablePath = (location: HookExecutableLocation): string => location.isPackaged
  ? path.join(location.resourcesPath, "hook", "ZCodeStatusHook.exe")
  : path.join(location.dirname, "..", "..", "assets", "hook", "ZCodeStatusHook.exe");

export interface HookConfigPreview {
  readonly configPath: string;
  readonly databasePath: string;
  readonly executablePath: string;
  readonly rules: readonly HookRuleSpec[];
  readonly enabled: boolean | undefined;
  readonly canConfigure: boolean;
  readonly reason: string;
}

export interface HookIntegrationState {
  readonly version: 1;
  readonly configPath: string;
  readonly executablePath: string;
  readonly databasePath: string;
  readonly backupPath: string;
  readonly installedAt: string;
}

export const defaultZcodeConfigPath = (homeDirectory: string): string => (
  path.join(homeDirectory, ".zcode", "cli", "config.json")
);

export const providerConfigPath = (homeDirectory: string): string => (
  path.join(homeDirectory, ".zcode", "v2", "config.json")
);

export const isProviderOnlyConfig = (source: unknown): boolean => {
  if (!source || typeof source !== "object" || Array.isArray(source)) {
    return false;
  }
  const config = source as Record<string, unknown>;
  return Boolean(
    config.provider
    && typeof config.provider === "object"
    && !Array.isArray(config.provider)
    && config.hooks === undefined,
  );
};

export const sessionDatabasePath = (configPath: string): string => (
  path.join(path.dirname(configPath), "db", "db.sqlite")
);

export const managedHookRule = (spec: HookRuleSpec, executablePath: string, databasePath: string): Record<string, unknown> => {
  const hook = {
    type: "process",
    command: executablePath,
    args: [spec.token, "${CLAUDE_SESSION_ID}", "${ZCODE_PROJECT_DIR}", databasePath],
    timeoutMs: 5000,
  };
  return spec.matcher ? { matcher: spec.matcher, hooks: [hook] } : { hooks: [hook] };
};

const recordValue = (value: unknown): Record<string, unknown> | undefined => (
  value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : undefined
);

const normalizePath = (value: unknown): string => typeof value === "string"
  ? path.normalize(value).replace(/[\\/]+$/, "").toLocaleLowerCase()
  : "";

export interface ValidatedHookConfig {
  readonly config: Record<string, unknown>;
  readonly hooks: Record<string, unknown> | undefined;
  readonly events: Record<string, unknown> | undefined;
}

export const validateHookConfig = (source: unknown): ValidatedHookConfig => {
  const config = recordValue(source);
  if (!config) {
    throw new Error("ZCode 配置必须是 JSON 对象。");
  }
  const hooks = recordValue(config.hooks);
  if (config.hooks !== undefined && !hooks) {
    throw new Error("ZCode 配置中的 hooks 必须是对象。");
  }
  const events = hooks && recordValue(hooks.events);
  if (hooks?.events !== undefined && !events) {
    throw new Error("ZCode 配置中的 hooks.events 必须是对象。");
  }
  for (const [event, rules] of Object.entries(events ?? {})) {
    if (!Array.isArray(rules)) {
      throw new Error(`ZCode 配置中的 hooks.events.${event} 必须是数组。`);
    }
  }
  return { config, hooks, events };
};

export const isManagedHookRule = (
  candidate: unknown,
  spec: HookRuleSpec,
  executablePath: string,
  databasePath: string,
): boolean => {
  const rule = recordValue(candidate);
  if (!rule || rule.matcher !== spec.matcher) {
    return false;
  }
  if (spec.matcher === undefined && "matcher" in rule && rule.matcher !== undefined) {
    return false;
  }
  if (!Array.isArray(rule.hooks) || rule.hooks.length !== 1) {
    return false;
  }
  const hook = recordValue(rule.hooks[0]);
  if (
    !hook
    || hook.type !== "process"
    || normalizePath(hook.command) !== normalizePath(executablePath)
    || hook.timeoutMs !== 5000
    || !Array.isArray(hook.args)
    || hook.args.length !== 4
  ) {
    return false;
  }
  const [token, sessionId, projectDirectory, database] = hook.args;
  return token === spec.token
    && sessionId === "${CLAUDE_SESSION_ID}"
    && projectDirectory === "${ZCODE_PROJECT_DIR}"
    && normalizePath(database) === normalizePath(databasePath);
};

export const mergeHookConfig = (
  source: unknown,
  executablePath: string,
  databasePath: string,
  enableDisabledHooks = false,
): { readonly config: Record<string, unknown>; readonly enabledWasFalse: boolean } => {
  const validated = validateHookConfig(source);
  const config = validated.config;
  const hooks = validated.hooks ?? {};
  const enabledWasFalse = hooks.enabled === false;
  if (enabledWasFalse && !enableDisabledHooks) {
    throw new Error("ZCode Hooks 当前已被明确关闭；请先确认是否启用。");
  }
  const events = validated.events ?? {};
  const nextEvents: Record<string, unknown> = { ...events };
  for (const spec of hookRuleSpecs) {
    const eventRules = nextEvents[spec.event];
    const current: unknown[] = Array.isArray(eventRules) ? eventRules : [];
    nextEvents[spec.event] = [
      ...current.filter((rule) => !isManagedHookRule(rule, spec, executablePath, databasePath)),
      managedHookRule(spec, executablePath, databasePath),
    ];
  }
  return {
    config: {
      ...config,
      hooks: {
        ...hooks,
        enabled: hooks.enabled === undefined || enabledWasFalse ? true : hooks.enabled,
        events: nextEvents,
      },
    },
    enabledWasFalse,
  };
};

export const removeManagedHookRules = (
  source: unknown,
  executablePath: string,
  databasePath: string,
): Record<string, unknown> => {
  const validated = validateHookConfig(source);
  const config = validated.config;
  const hooks = validated.hooks;
  const events = validated.events;
  if (!hooks || !events) {
    return config;
  }
  const nextEvents: Record<string, unknown> = { ...events };
  for (const spec of hookRuleSpecs) {
    const eventRules = nextEvents[spec.event];
    const current: unknown[] = Array.isArray(eventRules) ? eventRules : [];
    nextEvents[spec.event] = current.filter((rule) => !isManagedHookRule(rule, spec, executablePath, databasePath));
  }
  return { ...config, hooks: { ...hooks, events: nextEvents } };
};
