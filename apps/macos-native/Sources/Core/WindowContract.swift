import Foundation
import CoreGraphics

/// 窗口几何契约（对照 src/main/window-contract.ts，纯函数、可单测）。
/// 坐标语义：AppKit 全局屏幕坐标（原点在主屏左下角，y 向上），与 NSScreen.visibleFrame、
/// NSWindow.setFrame 直接一致。Electron screen 是顶部原点，移植时 y 轴已翻转：
/// Electron 的 workArea.y+height（底部）对应 AppKit 的 visibleFrame.minY。
public enum WindowContract {
    public static let panelBorderHeight: CGFloat = 2
    public static let sessionListVerticalPadding: CGFloat = 12
    public static let sessionRowHeight: CGFloat = 18
    public static let sessionRowGap: CGFloat = 2
    /// 挂件密度二档（2026-09-05 两轮收紧，与 Windows 的 27/3/18/520 有意分叉）：
    /// 行高 18、行距 2、列表内边距 6；默认 280x32，宽 220–640 可调。
    public static let panelDefaultWidth: CGFloat = 280
    public static let panelDefaultHeight: CGFloat = 32
    public static let panelWidthRange: ClosedRange<CGFloat> = 220...640
    /// 设置窗口 328x620 上限、垂直 margin 32（2026-09-05 收紧；对照 Windows
    /// 的 356/760）。原右上角锚定 16/16 同步改为工作区居中（用户偏好，
    /// 与 window-contract.ts:38-43 有意分叉）。
    public static let settingsWidth: CGFloat = 328
    public static let settingsMaxHeight: CGFloat = 620
    public static let settingsVerticalMargin: CGFloat = 32
    /// 提醒卡片 304x122，与面板间距 12（window-contract.ts:45-48, 109-113）。
    public static let attentionWidth: CGFloat = 304
    public static let attentionHeight: CGFloat = 122
    public static let attentionPanelGap: CGFloat = 12

    /// 面板高度公式（window-contract.ts:16-24 结构一致，常量取挂件密度）：
    /// 2 + 12 + rows*18 + (rows-1)*2，夹在 [32, max(32, workAreaHeight)]。
    public static func panelHeight(rows: Int, workAreaHeight: CGFloat) -> CGFloat {
        if rows <= 0 { return panelDefaultHeight }
        let content = panelBorderHeight + sessionListVerticalPadding
            + CGFloat(rows) * sessionRowHeight
            + CGFloat(rows - 1) * sessionRowGap
        return min(max(content, panelDefaultHeight), max(panelDefaultHeight, workAreaHeight))
    }

    public static func clampedPanelWidth(_ width: CGFloat) -> CGFloat {
        (width.rounded()).clamped(to: panelWidthRange)
    }

    /// 角落锚定原点（window-manager.ts:316-323）。
    public static func panelOrigin(corner: PanelCorner, marginX: Int, marginY: Int, size: CGSize, workArea: CGRect) -> CGPoint {
        let x: CGFloat
        let y: CGFloat
        switch corner {
        case .bottomRight, .topRight:
            x = workArea.maxX - size.width - CGFloat(marginX)
        case .bottomLeft, .topLeft:
            x = workArea.minX + CGFloat(marginX)
        }
        switch corner {
        case .bottomRight, .bottomLeft:
            y = workArea.minY + CGFloat(marginY)
        case .topRight, .topLeft:
            y = workArea.maxY - size.height - CGFloat(marginY)
        }
        return clampOrigin(CGPoint(x: x, y: y), size: size, workArea: workArea)
    }

    /// 原点夹入 workArea（window-contract.ts:65-77）。
    public static func clampOrigin(_ origin: CGPoint, size: CGSize, workArea: CGRect) -> CGPoint {
        let maxX = max(workArea.minX, workArea.maxX - size.width)
        let maxY = max(workArea.minY, workArea.maxY - size.height)
        return CGPoint(
            x: max(workArea.minX, min(origin.x, maxX)),
            y: max(workArea.minY, min(origin.y, maxY))
        )
    }

    /// 由拖拽落定 bounds 反算停靠参数（window-contract.ts:85-100；y 轴已翻转为 AppKit 语义）。
    public static func placement(for bounds: CGRect, workArea: CGRect) -> (corner: PanelCorner, marginX: Int, marginY: Int) {
        let leftMargin = bounds.minX - workArea.minX
        let rightMargin = workArea.maxX - bounds.maxX
        let bottomMargin = bounds.minY - workArea.minY
        let topMargin = workArea.maxY - bounds.maxY
        let useRight = rightMargin <= leftMargin
        let useBottom = bottomMargin <= topMargin
        let corner: PanelCorner
        switch (useRight, useBottom) {
        case (true, true): corner = .bottomRight
        case (false, true): corner = .bottomLeft
        case (true, false): corner = .topRight
        case (false, false): corner = .topLeft
        }
        let marginX: Int
        let marginY: Int
        if useRight {
            marginX = max(0, Int(rightMargin.rounded()))
        } else {
            marginX = max(0, Int(leftMargin.rounded()))
        }
        if useBottom {
            marginY = max(0, Int(bottomMargin.rounded()))
        } else {
            marginY = max(0, Int(topMargin.rounded()))
        }
        return (corner, marginX, marginY)
    }

    /// 设置窗口 bounds：工作区居中（原对照 Windows 右上锚定，2026-09-05
    /// 按用户偏好改为居中），高度受 620 上限与工作区夹紧。
    public static func settingsBounds(workArea: CGRect) -> CGRect {
        let width = min(settingsWidth, max(1, workArea.width))
        let height = min(settingsMaxHeight, max(1, (workArea.height - settingsVerticalMargin).rounded(.down)))
        let origin = clampOrigin(
            CGPoint(
                x: workArea.midX - width / 2,
                y: workArea.midY - height / 2
            ),
            size: CGSize(width: width, height: height),
            workArea: workArea
        )
        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }

    /// 提醒卡片原点：corner 模式贴面板停靠角对应的屏幕角落（距角 12px，
    /// 与面板拖动位置无关）；center 居中；最后夹紧。
    /// 注意：此处与 Windows（window-contract.ts:102-115 贴面板左上外侧）有意
    /// 分叉——面板被拖离角落后 Windows 卡片悬在屏幕中部，"角落"名不符实
    /// （2026-09-05 用户确认改为真角落）；显示器选择仍按面板所在屏。
    public static func attentionOrigin(workArea: CGRect, placement: AttentionPlacement, panelCorner: PanelCorner) -> CGPoint {
        let size = CGSize(width: attentionWidth, height: attentionHeight)
        let raw: CGPoint
        if placement == .corner {
            let x: CGFloat
            let y: CGFloat
            switch panelCorner {
            case .bottomRight:
                x = workArea.maxX - size.width - attentionPanelGap
                y = workArea.minY + attentionPanelGap
            case .bottomLeft:
                x = workArea.minX + attentionPanelGap
                y = workArea.minY + attentionPanelGap
            case .topRight:
                x = workArea.maxX - size.width - attentionPanelGap
                y = workArea.maxY - size.height - attentionPanelGap
            case .topLeft:
                x = workArea.minX + attentionPanelGap
                y = workArea.maxY - size.height - attentionPanelGap
            }
            raw = CGPoint(x: x, y: y)
        } else {
            raw = CGPoint(
                x: workArea.minX + ((workArea.width - size.width) / 2).rounded(),
                y: workArea.minY + ((workArea.height - size.height) / 2).rounded()
            )
        }
        return clampOrigin(raw, size: size, workArea: workArea)
    }

    /// 面板显隐判定（window-contract.ts:59-63）。
    public static func shouldShowPanel(showIdle: Bool, hasSessions: Bool, override: PanelVisibilityOverride?) -> Bool {
        if override == .visible { return true }
        if override == .hidden { return false }
        return showIdle || hasSessions
    }
}

/// 面板显隐覆盖（对照 window-manager 的 override 状态机）。
public enum PanelVisibilityOverride: Equatable, Sendable {
    case visible
    case hidden
}

extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
