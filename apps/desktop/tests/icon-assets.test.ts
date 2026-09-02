import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

const assetsPath = resolve(import.meta.dirname, "..", "assets");

describe("Windows icon assets", () => {
  it("keeps a valid transparent PNG tray icon", () => {
    const data = readFileSync(resolve(assetsPath, "tray.png"));
    expect(data.subarray(0, 8)).toEqual(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
    expect(data.readUInt32BE(16)).toBe(64);
    expect(data.readUInt32BE(20)).toBe(64);
  });

  it("keeps an ICO application icon", () => {
    const data = readFileSync(resolve(assetsPath, "icon.ico"));
    expect(data.readUInt16LE(0)).toBe(0);
    expect(data.readUInt16LE(2)).toBe(1);
    expect(data.readUInt16LE(4)).toBeGreaterThan(0);
  });
});
