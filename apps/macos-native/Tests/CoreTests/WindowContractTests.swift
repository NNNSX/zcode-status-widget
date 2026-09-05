import Foundation
import CoreGraphics
@testable import Core

/// 对照 apps/desktop/tests/window-contract.test.ts。
final class WindowContractTests: ZTestCase {
    @objc func testPanelWidthClamping() {
        ztAssertEqual(WindowContract.clampedPanelWidth(100), 220)
        ztAssertEqual(WindowContract.clampedPanelWidth(520.4), 520)
        ztAssertEqual(WindowContract.clampedPanelWidth(999), 640)
    }

    @objc func testPanelHeightFitsRows() {
        // 挂件密度二档：2 + 12 + rows*18 + (rows-1)*2。
        ztAssertEqual(WindowContract.panelHeight(rows: 1, workAreaHeight: 1080), 32)
        ztAssertEqual(WindowContract.panelHeight(rows: 3, workAreaHeight: 1080), 72)
        ztAssertEqual(WindowContract.panelHeight(rows: 4, workAreaHeight: 1080), 92)
        ztAssertEqual(WindowContract.panelHeight(rows: 20, workAreaHeight: 240), 240)
    }

    @objc func testSettingsHeightUsesWorkArea() {
        ztAssertEqual(WindowContract.settingsBounds(workArea: CGRect(x: 0, y: 0, width: 1920, height: 1080)).height, 620)
        ztAssertEqual(WindowContract.settingsBounds(workArea: CGRect(x: 0, y: 0, width: 1920, height: 760)).height, 620)
        ztAssertEqual(WindowContract.settingsBounds(workArea: CGRect(x: 0, y: 0, width: 1920, height: 500)).height, 468)
    }

    @objc func testSettingsBoundsCentersInWorkArea() {
        // 居中（2026-09-05 与 Windows 右上锚定分叉）：宽 328、高 min(620, 600-32)=568，
        // x = -1200+600-164 = -764，y = 300-284 = 16（夹紧后不变）。
        let bounds = WindowContract.settingsBounds(workArea: CGRect(x: -1200, y: 0, width: 1200, height: 600))
        ztAssertEqual(bounds, CGRect(x: -764, y: 16, width: 328, height: 568))
    }

    @objc func testShouldShowPanelOverrides() {
        ztAssertFalse(WindowContract.shouldShowPanel(showIdle: false, hasSessions: false, override: nil))
        ztAssertTrue(WindowContract.shouldShowPanel(showIdle: false, hasSessions: false, override: .visible))
        ztAssertFalse(WindowContract.shouldShowPanel(showIdle: true, hasSessions: false, override: .hidden))
        ztAssertTrue(WindowContract.shouldShowPanel(showIdle: false, hasSessions: true, override: nil))
    }

    @objc func testClampOriginInsideWorkArea() {
        let workArea = CGRect(x: 100, y: 200, width: 500, height: 400)
        let clamped = WindowContract.clampOrigin(
            CGPoint(x: 900, y: -10),
            size: CGSize(width: 300, height: 120),
            workArea: workArea
        )
        ztAssertEqual(clamped, CGPoint(x: 300, y: 200))
    }

    @objc func testAttentionCornerOriginPinsToScreenCorner() {
        // 卡片贴停靠角对应的屏幕角落（距角 12px），与面板拖动位置无关
        // （2026-09-05 与 Windows 分叉：旧语义贴面板左上，面板拖离角落后卡片悬在屏幕中部）。
        let workArea = CGRect(x: 100, y: 200, width: 500, height: 400)
        // 卡片 304x122；右下角：x = 600-304-12 = 284，y = 200+12 = 212。
        ztAssertEqual(
            WindowContract.attentionOrigin(workArea: workArea, placement: .corner, panelCorner: .bottomRight),
            CGPoint(x: 284, y: 212), "bottomRight 贴右下角"
        )
        ztAssertEqual(
            WindowContract.attentionOrigin(workArea: workArea, placement: .corner, panelCorner: .bottomLeft),
            CGPoint(x: 112, y: 212), "bottomLeft 贴左下角"
        )
        ztAssertEqual(
            WindowContract.attentionOrigin(workArea: workArea, placement: .corner, panelCorner: .topRight),
            CGPoint(x: 284, y: 600 - 122 - 12), "topRight 贴右上角"
        )
        ztAssertEqual(
            WindowContract.attentionOrigin(workArea: workArea, placement: .corner, panelCorner: .topLeft),
            CGPoint(x: 112, y: 466), "topLeft 贴左上角"
        )
    }

    @objc func testAttentionCenterOrigin() {
        let origin = WindowContract.attentionOrigin(
            workArea: CGRect(x: 100, y: 200, width: 500, height: 400),
            placement: .center,
            panelCorner: .bottomRight
        )
        ztAssertEqual(origin, CGPoint(x: 100 + 98, y: 200 + 139), "居中（500/2-304/2=98, 400/2-122/2=139）")
    }

    @objc func testPlacementForDroppedBounds() {
        // AppKit 坐标：bounds.y 是窗口底边（距屏幕底）。
        let workArea = CGRect(x: -600, y: 50, width: 1600, height: 900)
        let bottomRight = WindowContract.placement(
            for: CGRect(x: 880, y: 66, width: 100, height: 120),
            workArea: workArea
        )
        ztAssertEqual(bottomRight.corner, PanelCorner.bottomRight)
        ztAssertEqual(bottomRight.marginX, 20)
        ztAssertEqual(bottomRight.marginY, 16)

        let topLeft = WindowContract.placement(
            for: CGRect(x: -570, y: 812, width: 100, height: 120),
            workArea: workArea
        )
        ztAssertEqual(topLeft.corner, PanelCorner.topLeft)
        ztAssertEqual(topLeft.marginX, 30)
        ztAssertEqual(topLeft.marginY, 18)
    }

    @objc func testPanelOriginFourCorners() {
        let workArea = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = CGSize(width: 380, height: 47)
        ztAssertEqual(WindowContract.panelOrigin(corner: .bottomRight, marginX: 14, marginY: 52, size: size, workArea: workArea), CGPoint(x: 606, y: 52))
        ztAssertEqual(WindowContract.panelOrigin(corner: .topLeft, marginX: 14, marginY: 52, size: size, workArea: workArea), CGPoint(x: 14, y: 701))
        ztAssertEqual(WindowContract.panelOrigin(corner: .bottomLeft, marginX: 14, marginY: 52, size: size, workArea: workArea), CGPoint(x: 14, y: 52))
        ztAssertEqual(WindowContract.panelOrigin(corner: .topRight, marginX: 14, marginY: 52, size: size, workArea: workArea), CGPoint(x: 606, y: 701))
    }

    @objc func testAttentionPolicyModes() {
        var config = AppConfig.default
        config.attentionMode = .off
        ztAssertEqual(AttentionPolicy.request(for: config).kind, AttentionRequestKind.none)
        config.attentionMode = .panelPulse
        ztAssertEqual(AttentionPolicy.request(for: config).kind, AttentionRequestKind.edge)
        config.attentionMode = .cornerOverlay
        ztAssertEqual(AttentionPolicy.request(for: config).kind, AttentionRequestKind.overlay(placement: .corner))
        config.attentionMode = .centerOverlay
        ztAssertEqual(AttentionPolicy.request(for: config).kind, AttentionRequestKind.overlay(placement: .center))
        ztAssertEqual(AttentionPolicy.request(for: config).durationMs, 1800)
    }
}

/// 时长格式化（对照 reducer.ts:79-85）。
final class FormatDurationTests: ZTestCase {
    @objc func testFormats() {
        ztAssertEqual(formatDuration(milliseconds: 0), "0:00")
        ztAssertEqual(formatDuration(milliseconds: 59_400), "0:59")
        ztAssertEqual(formatDuration(milliseconds: 65_000), "1:05")
        ztAssertEqual(formatDuration(milliseconds: 3_599_999), "59:59")
        ztAssertEqual(formatDuration(milliseconds: 3_600_000), "1:00:00")
        ztAssertEqual(formatDuration(milliseconds: 5_500), "0:05")
    }

    /// 回归：负时长（时钟回拨/NTP 校时）钳到 0（对照 Math.max(0, …)）。
    @objc func testNegativeClampsToZero() {
        ztAssertEqual(formatDuration(milliseconds: -1), "0:00")
        ztAssertEqual(formatDuration(milliseconds: -65_000), "0:00")
    }
}

/// 手改 settings.json 越界值的加载钳制（对照 Windows load 后过 normalizeConfig）。
final class AppConfigClampedTests: ZTestCase {
    @objc func testOutOfRangeValuesAreClampedOnLoad() {
        var raw = AppConfig.default
        raw.marginX = -40
        raw.marginY = -1
        raw.opacity = 5
        raw.panelWidth = 9_999
        raw.doneTtlMinutes = 0
        raw.attentionDurationMs = 100
        raw.displayId = "  2  \n"
        let normalized = raw.normalized()
        ztAssertEqual(normalized.marginX, 0, "marginX 下限 0")
        ztAssertEqual(normalized.marginY, 0, "marginY 下限 0")
        ztAssertEqual(normalized.opacity, 20, "opacity 钳到下限")
        ztAssertEqual(normalized.panelWidth, 640, "panelWidth 钳到上限")
        ztAssertEqual(normalized.doneTtlMinutes, 1, "doneTtl 钳到下限")
        ztAssertEqual(normalized.attentionDurationMs, 800, "attentionDuration 钳到下限")
        ztAssertEqual(normalized.displayId, "2", "displayId 去空白")
    }

    @objc func testInBoundsValuesPassThrough() {
        let inBounds = AppConfig.default
        ztAssertEqual(inBounds.normalized(), inBounds, "合法值不变")
    }
}
