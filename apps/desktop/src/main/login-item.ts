export const LOGIN_ITEM_NAME = "ZCode Status Light";

export interface LoginItemEnvironment {
  readonly isPackaged: boolean;
  readonly platform: NodeJS.Platform;
  readonly execPath: string;
}

export interface LoginItemSettings {
  readonly openAtLogin: boolean;
  readonly path: string;
  readonly args: readonly string[];
  readonly name: string;
}

export interface LoginItemSetter {
  setLoginItemSettings(settings: LoginItemSettings): void;
}

export const loginItemSettingsFor = (environment: LoginItemEnvironment, enabled: boolean): LoginItemSettings | undefined => (
  environment.isPackaged && environment.platform === "win32"
    ? {
        openAtLogin: enabled,
        path: environment.execPath,
        args: [],
        name: LOGIN_ITEM_NAME,
      }
    : undefined
);

export const applyLaunchOnStartup = (
  setter: LoginItemSetter,
  environment: LoginItemEnvironment,
  enabled: boolean,
): boolean => {
  const settings = loginItemSettingsFor(environment, enabled);
  if (!settings) {
    return false;
  }
  try {
    setter.setLoginItemSettings(settings);
    return true;
  } catch {
    return false;
  }
};
