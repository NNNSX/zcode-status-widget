import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const installerNshPath = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "assets", "installer.nsh");
const installerNsh = readFileSync(installerNshPath, "utf8");

describe("NSIS uninstaller contract", () => {
  it("aborts when the main executable is missing", () => {
    expect(installerNsh).toContain("${IfNot} ${FileExists}");
    expect(installerNsh).toContain("Abort");
  });

  it("aborts when hook cleanup reports failure", () => {
    expect(installerNsh).toMatch(/ExecWait[^\r\n]*--unconfigure-hooks --silent/);
    expect(installerNsh).toContain("${If} $R0 != 0");
  });

  it("skips hook cleanup on upgrade installs", () => {
    expect(installerNsh).toContain("${IfNot} ${isUpdated}");
  });

  it("removes the autostart Run value during uninstall", () => {
    expect(installerNsh).toContain(
      'DeleteRegValue HKCU "Software\\Microsoft\\Windows\\CurrentVersion\\Run" "ZCode Status Light"',
    );
  });
});
