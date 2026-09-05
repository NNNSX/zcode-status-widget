import AppKit

/// 菜单栏托盘（对照 src/main/tray.ts）。
/// 图标：自绘三颗圆点的 template image，自动适配深浅色菜单栏（对照 §4.6 要求）。
final class StatusBarController {
    struct Actions {
        var togglePanel: () -> Void
        var openSettings: () -> Void
        var resetPosition: () -> Void
        var showAttentionDemo: () -> Void
        var quit: () -> Void
    }

    private let statusItem: NSStatusItem
    private let actions: Actions

    init(actions: Actions) {
        self.actions = actions
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.statusImage()
        statusItem.button?.toolTip = "ZCode 会话状态"

        let menu = NSMenu()
        menu.addItem(withTitle: "显示/隐藏状态面板", action: #selector(togglePanelAction), keyEquivalent: "")
        menu.addItem(withTitle: "打开设置", action: #selector(openSettingsAction), keyEquivalent: ",")
        menu.addItem(withTitle: "重置位置", action: #selector(resetPositionAction), keyEquivalent: "")
        menu.addItem(withTitle: "显示提醒演示", action: #selector(showAttentionAction), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(quitAction), keyEquivalent: "q")
        for item in menu.items {
            item.target = self
        }
        statusItem.menu = menu
    }

    @objc private func togglePanelAction() { actions.togglePanel() }
    @objc private func openSettingsAction() { actions.openSettings() }
    @objc private func resetPositionAction() { actions.resetPosition() }
    @objc private func showAttentionAction() { actions.showAttentionDemo() }
    @objc private func quitAction() { actions.quit() }

    func destroy() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    /// 三色灯托盘图（红/黄/绿，与面板灯同色）+ 胶囊形外框。不用 template——
    /// template 会被系统按菜单栏深浅单色化；三色在深浅菜单栏上都有足够对比度，
    /// 且与 Windows 版彩色托盘一致。三个小尺寸点曾与系统"缩略"类图标混淆，
    /// 改为更醒目的大圆点；外框把三灯围成一个整体，进一步与菜单栏原生
    /// 圆点类图标区分。框用中性灰（非纯白/纯黑）：浅色与深色菜单栏下均可见。
    private static func statusImage() -> NSImage {
        let dot: CGFloat = 5
        let gap: CGFloat = 3.5
        let padding: CGFloat = 3          // 框内侧到灯的水平/垂直留白
        let lineWidth: CGFloat = 1
        let frameHeight: CGFloat = dot + padding * 2
        let size = NSSize(width: 3 * dot + 2 * gap + (padding + lineWidth) * 2, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()

        // 胶囊外框（全圆角），0.5pt 偏移让 1pt 线落在像素中心。
        let frameRect = NSRect(
            x: lineWidth / 2,
            y: (size.height - frameHeight) / 2,
            width: size.width - lineWidth,
            height: frameHeight
        )
        let frameColor = NSColor(calibratedWhite: 0.58, alpha: 0.9)
        frameColor.setStroke()
        let frame = NSBezierPath(roundedRect: frameRect, xRadius: frameHeight / 2, yRadius: frameHeight / 2)
        frame.lineWidth = lineWidth
        frame.stroke()

        let colors: [NSColor] = [
            NSColor(red: 229/255, green: 72/255, blue: 77/255, alpha: 1),   // #e5484d 红
            NSColor(red: 242/255, green: 193/255, blue: 78/255, alpha: 1),  // #f2c14e 黄
            NSColor(red: 70/255, green: 184/255, blue: 129/255, alpha: 1),  // #46b881 绿
        ]
        var x: CGFloat = padding + lineWidth
        for color in colors {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: (size.height - dot) / 2, width: dot, height: dot)).fill()
            x += dot + gap
        }
        image.unlockFocus()
        return image
    }
}
