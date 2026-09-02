export type HookSetupStatus = "configured" | "disabled" | "invalid" | "missing" | "ready";

export interface HookSetupSnapshot {
  readonly configPath: string;
  readonly databasePath: string;
  readonly status: HookSetupStatus;
  readonly message: string;
  readonly isConfigured: boolean;
  readonly requiresEnableConfirmation: boolean;
  readonly ruleCount: number;
}
