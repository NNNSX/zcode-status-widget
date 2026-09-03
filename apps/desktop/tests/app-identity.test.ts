import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { APP_USER_MODEL_ID } from "../src/main/app-identity";

describe("desktop application identity", () => {
  it("keeps the runtime AppUserModelId aligned with electron-builder appId", () => {
    const packagePath = path.resolve(__dirname, "../package.json");
    const packageJson = JSON.parse(readFileSync(packagePath, "utf8")) as {
      build?: { appId?: string };
    };
    expect(APP_USER_MODEL_ID).toBe(packageJson.build?.appId);
  });
});
