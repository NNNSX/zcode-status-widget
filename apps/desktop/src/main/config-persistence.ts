import type { AppConfig } from "../shared/config";

export type PersistConfig = (config: AppConfig) => Promise<void>;

export class ConfigPersistenceQueue {
  private pending: AppConfig | undefined;
  private timer: ReturnType<typeof setTimeout> | undefined;
  private flushing: Promise<void> | undefined;

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
      void this.flush();
    }, this.delayMs);
  }

  public flush(): Promise<void> {
    if (this.timer) {
      clearTimeout(this.timer);
      this.timer = undefined;
    }
    if (!this.flushing) {
      this.flushing = this.drain().finally(() => {
        this.flushing = undefined;
      });
    }
    return this.flushing;
  }

  private async drain(): Promise<void> {
    while (this.pending) {
      const candidate = this.pending;
      this.pending = undefined;
      await this.persist(candidate);
    }
  }
}
