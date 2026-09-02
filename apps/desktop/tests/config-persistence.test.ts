import { describe, expect, it, vi } from "vitest";
import { ConfigPersistenceQueue } from "../src/main/config-persistence";
import { normalizeConfig } from "../src/shared/config";

describe("configuration persistence queue", () => {
  it("persists only the newest configuration from a burst of updates", async () => {
    vi.useFakeTimers();
    const saved: number[] = [];
    const queue = new ConfigPersistenceQueue(async (config) => {
      saved.push(config.opacity);
    }, 100);

    queue.schedule(normalizeConfig({ opacity: 40 }));
    queue.schedule(normalizeConfig({ opacity: 65 }));
    queue.schedule(normalizeConfig({ opacity: 85 }));
    await vi.advanceTimersByTimeAsync(100);
    await queue.flush();

    expect(saved).toEqual([85]);
    vi.useRealTimers();
  });

  it("serializes a newer update behind an active persistence operation", async () => {
    let releaseFirst: (() => void) | undefined;
    const persisted: number[] = [];
    const queue = new ConfigPersistenceQueue(async (config) => {
      persisted.push(config.panelWidth);
      if (config.panelWidth === 400) {
        await new Promise<void>((resolve) => { releaseFirst = resolve; });
      }
    }, 0);

    queue.schedule(normalizeConfig({ panelWidth: 400 }));
    const first = queue.flush();
    await Promise.resolve();
    queue.schedule(normalizeConfig({ panelWidth: 500 }));
    releaseFirst?.();
    await first;

    expect(persisted).toEqual([400, 500]);
  });
});
