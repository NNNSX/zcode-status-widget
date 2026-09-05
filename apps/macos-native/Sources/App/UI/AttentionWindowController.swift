import AppKit
import Core

/// 全局提醒窗口（对照 window-manager.ts attention 部分 + renderer attention 样式）。
/// - card：304x122 卡片（图标 + 标题 + 工作区），带阴影；
/// - edge：整屏透明覆盖，四边扫光（waiting 红系 2.6s / done 绿系 3.4s）；
/// - 点击穿透 + pop-up 层 + 250ms 重提升 + 自动关闭（generation 防旧代误关）；
/// - 同 session+placement+kind 复用窗口仅刷新内容并重设计时器。
final class AttentionWindowController: NSObject, NSWindowDelegate {
    static let reassertIntervalMs = 250

    private var attentionWindow: NSWindow?
    private var attentionSessionId: String?
    private var attentionPlacement: AttentionPlacement?
    private var attentionKind: AttentionContent.Kind?
    /// 本次提醒携带的面板帧与停靠角：帧用于选屏（卡片出现在面板所在屏，
    /// 复用刷新与显示器变化重摆位沿用），角用于贴屏幕角落定位。
    private var attentionPanelFrame: NSRect?
    private var attentionPanelCorner: PanelCorner = .bottomRight
    private var generation = 0
    private var closeTimer: Timer?
    private var reassertTimer: Timer?
    private var displayChangeObserver: Any?

    /// 复用窗口判定（wm:346-359）：session+placement+kind 一致即复用。
    func showAttention(content: AttentionContent, durationMs: Int, placement: AttentionPlacement, panelFrame: NSRect?, panelCorner: PanelCorner = .bottomRight) {
        let presentation: AttentionPresentation = placement == .edge ? .edge : .card

        let reusable = attentionWindow != nil
            && attentionSessionId == content.sessionId
            && attentionPlacement == placement
            && attentionKind == content.kind

        if reusable, let window = attentionWindow, let view = window.contentView as? AttentionContentView {
            generation += 1
            let currentGeneration = generation
            attentionPanelFrame = panelFrame
            attentionPanelCorner = panelCorner
            view.update(content: content)
            raise()
            scheduleClose(durationMs: durationMs, generation: currentGeneration)
            reposition()
            return
        }

        // closeCurrentWindow 会递增 generation；在其之后取值，避免定时器闭包里的
        // generation 比较永远失败（新建窗口泄漏不关闭）。
        closeCurrentWindow()
        let currentGeneration = generation

        let screen = Self.screen(forPanelFrame: panelFrame)
        let window = makeWindow(presentation: presentation, screen: screen)
        let view: AttentionContentView = presentation == .edge ? AttentionEdgeView(frame: .zero) : AttentionCardView(frame: .zero)
        view.update(content: content)
        window.contentView = view
        applyBounds(window: window, presentation: presentation, placement: placement, screen: screen, panelCorner: panelCorner)

        attentionWindow = window
        attentionSessionId = content.sessionId
        attentionPlacement = placement
        attentionKind = content.kind
        attentionPanelFrame = panelFrame
        attentionPanelCorner = panelCorner
        window.delegate = self

        window.orderFrontRegardless()
        view.playEnterAnimation()
        raise()
        scheduleClose(durationMs: durationMs, generation: currentGeneration)
        startReassert()
        registerDisplayChanges()
    }

    /// 主动关闭（cancel-attention 效果）；sessionId 不匹配当前则忽略（wm:440-454）。
    func closeAttention(sessionId: String?) {
        if let sessionId, let current = attentionSessionId, sessionId != current {
            return
        }
        closeCurrentWindow()
    }

    var isVisible: Bool {
        attentionWindow?.isVisible ?? false
    }

    // MARK: - 内部

    private func makeWindow(presentation: AttentionPresentation, screen: NSScreen?) -> NSWindow {
        let bounds = presentation == .edge
            ? (screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900))
            : NSRect(x: 0, y: 0, width: WindowContract.attentionWidth, height: WindowContract.attentionHeight)
        let window = NSWindow(
            contentRect: bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = presentation == .card
        window.level = .popUpMenu
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        return window
    }

    private func applyBounds(window: NSWindow, presentation: AttentionPresentation, placement: AttentionPlacement, screen: NSScreen?, panelCorner: PanelCorner) {
        guard let screen else { return }
        if presentation == .edge {
            window.setFrame(screen.frame, display: false)
            return
        }
        let workArea = screen.visibleFrame
        let origin = WindowContract.attentionOrigin(workArea: workArea, placement: placement, panelCorner: panelCorner)
        window.setFrame(
            NSRect(origin: origin, size: CGSize(width: WindowContract.attentionWidth, height: WindowContract.attentionHeight)),
            display: false
        )
    }

    /// 面板中心所在显示器，否则主屏（wm:372-373, 552-559）。
    static func screen(forPanelFrame panelFrame: NSRect?) -> NSScreen? {
        guard let panelFrame, !panelFrame.isEmpty else { return NSScreen.main }
        let center = NSPoint(x: panelFrame.midX, y: panelFrame.midY)
        return NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) } ?? NSScreen.main
    }

    private func raise() {
        attentionWindow?.level = .popUpMenu
        if attentionWindow?.isVisible == true {
            attentionWindow?.orderFrontRegardless()
        }
    }

    private func scheduleClose(durationMs: Int, generation: Int) {
        closeTimer?.invalidate()
        let clamped = max(1, durationMs)
        closeTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(clamped) / 1000, repeats: false) { [weak self] _ in
            guard let self, self.generation == generation else { return }
            self.closeCurrentWindow()
        }
    }

    /// 250ms 重提升：对抗其他窗口压层（wm:428-435, 701-707）。
    private func startReassert() {
        reassertTimer?.invalidate()
        reassertTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(Self.reassertIntervalMs) / 1000, repeats: true) { [weak self] _ in
            self?.raise()
        }
    }

    private func closeCurrentWindow() {
        generation += 1
        closeTimer?.invalidate()
        closeTimer = nil
        reassertTimer?.invalidate()
        reassertTimer = nil
        if let observer = displayChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            displayChangeObserver = nil
        }
        attentionWindow?.delegate = nil
        attentionWindow?.orderOut(nil)
        attentionWindow = nil
        attentionSessionId = nil
        attentionPlacement = nil
        attentionKind = nil
        attentionPanelFrame = nil
        attentionPanelCorner = .bottomRight
    }

    /// 显示器布局变化：重算 bounds（wm:637-654）。
    private func registerDisplayChanges() {
        displayChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reposition()
        }
    }

    private func reposition() {
        guard let window = attentionWindow,
              let placement = attentionPlacement,
              let view = window.contentView as? AttentionContentView
        else { return }
        let presentation: AttentionPresentation = placement == .edge ? .edge : .card
        // 沿用本次提醒的面板帧选屏、停靠角贴角，不再退回主屏居中（wm:637-654）。
        let screen = Self.screen(forPanelFrame: attentionPanelFrame)
        applyBounds(window: window, presentation: presentation, placement: placement, screen: screen, panelCorner: attentionPanelCorner)
        view.update(content: view.currentContent)
    }

    func windowWillClose(_ notification: Notification) {
        closeCurrentWindow()
    }
}

/// 提醒形态（对照 presentation=card|edge）。
enum AttentionPresentation {
    case card
    case edge
}

/// 提醒内容视图协议：内容刷新 + 入场动画。
protocol AttentionContentView: NSView {
    var currentContent: AttentionContent { get }
    func update(content: AttentionContent)
    func playEnterAnimation()
}
