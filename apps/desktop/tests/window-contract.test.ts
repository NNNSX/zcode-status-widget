import { describe, expect, it } from "vitest";
import {
  attentionOrigin,
  attentionWindowContract,
  clampOrigin,
  clampPanelWidth,
  panelHeightForRows,
  panelWindowContract,
  placementForBounds,
  rendererUrl,
  settingsBoundsForWorkArea,
  settingsHeightForWorkArea,
  settingsWindowContract,
  shouldShowPanel,
} from "../src/main/window-contract";

describe("window contracts", () => {
  it("keeps the panel focusless and outside the taskbar", () => {
    expect(panelWindowContract).toMatchObject({
      frame: false,
      transparent: true,
      alwaysOnTop: true,
      focusable: false,
      skipTaskbar: true,
    });
  });

  it("keeps attention transparent, focusless, and outside the taskbar", () => {
    expect(attentionWindowContract).toMatchObject({
      frame: false,
      transparent: true,
      alwaysOnTop: true,
      focusable: false,
      skipTaskbar: true,
    });
    expect(settingsWindowContract.focusable).toBe(true);
  });

  it("keeps the panel width inside visual layout bounds", () => {
    expect(clampPanelWidth(100)).toBe(320);
    expect(clampPanelWidth(520.4)).toBe(520);
    expect(clampPanelWidth(999)).toBe(640);
  });

  it("fits the panel tightly to session rows and caps it to its work area", () => {
    expect(panelHeightForRows(1)).toBe(47);
    expect(panelHeightForRows(3)).toBe(107);
    expect(panelHeightForRows(4)).toBe(137);
    expect(panelHeightForRows(20, 240)).toBe(240);
  });

  it("uses the available work area for settings height", () => {
    expect(settingsHeightForWorkArea(1080)).toBe(760);
    expect(settingsHeightForWorkArea(760)).toBe(728);
    expect(settingsHeightForWorkArea(500)).toBe(468);
  });

  it("uses the panel display work area for complete settings bounds", () => {
    expect(settingsBoundsForWorkArea({ x: -1200, y: 0, width: 1200, height: 600 })).toEqual({
      x: -372,
      y: 16,
      width: 356,
      height: 568,
    });
  });

  it("keeps explicit panel recovery separate from automatic idle visibility", () => {
    expect(shouldShowPanel(false, false, undefined)).toBe(false);
    expect(shouldShowPanel(false, false, "visible")).toBe(true);
    expect(shouldShowPanel(true, false, "hidden")).toBe(false);
    expect(shouldShowPanel(false, true, undefined)).toBe(true);
  });

  it("clamps panel and reminder origins inside every edge of a work area", () => {
    const workArea = { x: 100, y: 200, width: 500, height: 400 };
    expect(clampOrigin(workArea, { width: 300, height: 120 }, 900, -10)).toEqual({ x: 300, y: 200 });
    expect(attentionOrigin(
      workArea,
      { width: 304, height: 122 },
      "corner",
      { x: 570, y: 470, width: 380, height: 174 },
    )).toEqual({ x: 254, y: 336 });
  });
  it("turns a dropped panel position into the nearest corner and margins", () => {
    const workArea = { x: -600, y: 50, width: 1600, height: 900 };
    expect(placementForBounds(workArea, { x: 880, y: 814, width: 100, height: 120 })).toEqual({
      corner: "bottom-right",
      marginX: 20,
      marginY: 16,
    });
    expect(placementForBounds(workArea, { x: -570, y: 68, width: 100, height: 120 })).toEqual({
      corner: "top-left",
      marginX: 30,
      marginY: 18,
    });
  });

  it("adds the renderer surface without replacing the development origin", () => {
    expect(rendererUrl("http://127.0.0.1:5174", "attention"))
      .toBe("http://127.0.0.1:5174/?surface=attention");
    expect(rendererUrl("http://127.0.0.1:5174", "attention", "edge"))
      .toBe("http://127.0.0.1:5174/?surface=attention&presentation=edge");
  });
});
