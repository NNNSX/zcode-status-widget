import { app, Menu, nativeImage, Tray, type NativeImage } from "electron";
import { trayImagePath } from "./tray-icon";
import { WindowManager } from "./window-manager";

const trayImage = (): NativeImage => {
  const image = nativeImage.createFromPath(trayImagePath({
    isPackaged: app.isPackaged,
    resourcesPath: process.resourcesPath,
    dirname: __dirname,
  }));
  if (image.isEmpty()) {
    throw new Error("ZCode Status Light tray icon could not be loaded.");
  }
  return image;
};

export interface TrayActions {
  readonly togglePanel: () => void;
  readonly openSettings: () => void;
  readonly resetPosition: () => void;
  readonly showAttention: () => void;
}

export const createTray = (windows: WindowManager, actions: TrayActions): Tray => {
  const tray = new Tray(trayImage());
  tray.setToolTip("ZCode 会话状态");
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: "显示/隐藏状态面板", click: actions.togglePanel },
    { label: "打开设置", click: actions.openSettings },
    { label: "重置位置", click: actions.resetPosition },
    { label: "显示提醒演示", click: actions.showAttention },
    { type: "separator" },
    { label: "退出", click: () => app.quit() },
  ]));
  tray.on("click", actions.togglePanel);
  return tray;
};
