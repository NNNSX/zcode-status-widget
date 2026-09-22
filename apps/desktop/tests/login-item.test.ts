import { describe, expect, it, vi } from "vitest";
import { applyLaunchOnStartup, LOGIN_ITEM_NAME, loginItemSettingsFor } from "../src/main/login-item";

const packagedWindowsEnvironment = {
  isPackaged: true,
  platform: "win32" as const,
  execPath: "C:\\Program Files\\ZCode Status Light\\ZCode Status Light.exe",
};

describe("login item", () => {
  it("registers autostart for packaged Windows installs", () => {
    const setter = vi.fn();
    expect(applyLaunchOnStartup({ setLoginItemSettings: setter }, packagedWindowsEnvironment, true)).toBe(true);
    expect(setter).toHaveBeenCalledWith({
      openAtLogin: true,
      path: packagedWindowsEnvironment.execPath,
      args: [],
      name: LOGIN_ITEM_NAME,
    });
    expect(loginItemSettingsFor(packagedWindowsEnvironment, true)?.name).toBe(LOGIN_ITEM_NAME);
  });

  it("removes autostart with openAtLogin false", () => {
    const setter = vi.fn();
    expect(applyLaunchOnStartup({ setLoginItemSettings: setter }, packagedWindowsEnvironment, false)).toBe(true);
    expect(setter).toHaveBeenCalledWith(expect.objectContaining({ openAtLogin: false }));
  });

  it("is a no-op in unpackaged dev runs", () => {
    const setter = vi.fn();
    const environment = { ...packagedWindowsEnvironment, isPackaged: false };
    expect(applyLaunchOnStartup({ setLoginItemSettings: setter }, environment, true)).toBe(false);
    expect(setter).not.toHaveBeenCalled();
    expect(loginItemSettingsFor(environment, true)).toBeUndefined();
  });

  it("is a no-op off Windows", () => {
    const setter = vi.fn();
    const environment = { ...packagedWindowsEnvironment, platform: "darwin" as const };
    expect(applyLaunchOnStartup({ setLoginItemSettings: setter }, environment, true)).toBe(false);
    expect(setter).not.toHaveBeenCalled();
    expect(loginItemSettingsFor(environment, true)).toBeUndefined();
  });

  it("swallows setter failures instead of breaking settings saves", () => {
    const setter = vi.fn(() => {
      throw new Error("registry locked");
    });
    expect(applyLaunchOnStartup({ setLoginItemSettings: setter }, packagedWindowsEnvironment, true)).toBe(false);
  });
});
