import path from "node:path";

export interface TrayImageEnvironment {
  readonly isPackaged: boolean;
  readonly resourcesPath: string;
  readonly dirname: string;
}

export const trayImagePath = (environment: TrayImageEnvironment): string => environment.isPackaged
  ? path.join(environment.resourcesPath, "assets", "tray.png")
  : path.join(environment.dirname, "..", "..", "assets", "tray.png");
