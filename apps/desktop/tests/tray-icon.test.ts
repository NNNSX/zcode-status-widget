import { describe, expect, it } from "vitest";
import { trayImagePath } from "../src/main/tray-icon";

describe("tray icon paths", () => {
  it("uses the source asset during development", () => {
    expect(trayImagePath({
      isPackaged: false,
      resourcesPath: "C:\\resources",
      dirname: "D:\\app\\out\\main",
    })).toBe("D:\\app\\assets\\tray.png");
  });

  it("uses the copied resource in a packaged application", () => {
    expect(trayImagePath({
      isPackaged: true,
      resourcesPath: "C:\\Program Files\\ZCode Status Light\\resources",
      dirname: "D:\\app\\out\\main",
    })).toBe("C:\\Program Files\\ZCode Status Light\\resources\\assets\\tray.png");
  });
});
