import type { AppConfig } from "../shared/config";

export type PersistConfig = (config: AppConfig) => Promise<void>;

export class ConfigPersistenceQueue {
  private pending: AppConfig | undefined;
  private timer: ReturnType<typeof setTimeout> | undefined;
  private flushing: Promise<void> | undefined;
  private lastError: unknown;

  public constructor(
    private readonly persist: PersistConfig,
    private readonly delayMs = 140,
  ) {}

  public schedule(config: AppConfig): void {
    this.pending = config;
    if (this.timer) {
      clearTimeout(this.timer);
    }
    this.timer = setTimeout(() => {
      this.timer = undefined;
      void this.flush().catch(() => undefined);
    }, this.delayMs);
  }

  public flush(): Promise<void> {
    if (this.timer) {
      clearTimeout(this.timer);
      this.timer = undefined;
    }
    if (!this.flushing) {
      this.flushing = this.drain()
        .catch((error: unknown) => {
          this.lastError = error;
          throw error;
        })
        .finally(() => {
          this.flushing = undefined;
        });
    }
    return this.flushing;
  }

  public getLastError(): unknown {
    return this.lastError;
  }

  private async drain(): Promise<void> {
    const failures: unknown[] = [];
    while (this.pending) {
      const candidate = this.pending;
      this.pending = undefined;
      try {
        await this.persist(candidate);
      } catch (error) {
        failures.push(error);
      }
    }
    if (failures.length > 0) {
      throw new AggregateError(failures, "一个或多个配置保存操作失败。");
    }
  }
}
