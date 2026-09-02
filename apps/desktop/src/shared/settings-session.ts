import { normalizeConfig, type AppConfig, type ConfigInput } from "./config";

export const previewSettingsConfig = (
  saved: AppConfig,
  preview: AppConfig | undefined,
  input: ConfigInput,
): AppConfig => normalizeConfig({ ...(preview ?? saved), ...input });

export const saveSettingsConfig = (saved: AppConfig, input: ConfigInput): AppConfig => (
  normalizeConfig({ ...saved, ...input })
);
