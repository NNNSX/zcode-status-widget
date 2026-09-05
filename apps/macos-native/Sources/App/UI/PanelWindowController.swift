import AppKit
import Core

/// 不抢焦点的状态面板窗口（对照 window-manager.ts 的 panel 部分）。
/// - nonactivating borderless NSPanel + canBecomeKey=false：点击不激活 App；
/// - floating 层级 + canJoinAllSpaces：常驻各空间；
/// - isMovableByWindowBackground：整窗拖动，落定 220ms 反算停靠参数并回调持久化。
final class PanelWindowController: NSObject, NSWindowDelegate {
    private class PanelWindow: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    static let moveDebounceMs = 0.22

    private let panel: PanelWindow
    private let contentView = PanelView(frame: .zero)
    private var moveDebounceTimer: Timer?
    private var suppressMovePersistence = false
    private var lastAppliedFrame: NSRect = .zero
    /// 用户拖动未落定（220ms 防抖窗口内）：apply 只调尺寸、保留用户位置
    /// （对照 window-manager.ts 的 userPanelMovePending，防时长刷新等
    /// 周期性 apply 把面板弹回旧锚点）。
    private var userPanelMovePending = false

    /// 拖拽落定 →（corner/marginX/marginY/displayId）持久化回调。
    var onPanelPositionChanged: ((PanelCorner, Int, Int, String) -> Void)?

    override init() {
        panel = PanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: WindowContract.panelDefaultWidth, height: WindowContract.panelDefaultHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.delegate = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = contentView
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        registerForDisplayChanges()
    }

    // MARK: - 几何与显隐（对照 applyConfig wm:303-339）

    /// 应用配置与快照：窗口几何、透明度、显隐。
    func apply(config: AppConfig, sessions: [DisplaySession], showIdle: Bool, override: PanelVisibilityOverride?) {
        // 记住最近一次应用参数：显示器布局变化防抖后据此重放（对照 wm:609-623）。
        // 之前只声明从未赋值，插拔显示器后面板一直停留在失效几何上。
        pendingConfig = (config, sessions, showIdle, override)
        let visible = sessions.isEmpty
            ? [DisplaySession(id: "idle", state: .unknown, workspace: "暂无活跃会话", task: "等待新的 ZCode 会话", todoProgress: "", duration: "")]
            : sessions
        let hasSessions = !sessions.isEmpty
        let rows = (showIdle || hasSessions) ? max(1, sessions.count) : 0

        let screen = Self.screen(forDisplayId: config.displayId) ?? NSScreen.main
        let workArea = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = WindowContract.clampedPanelWidth(CGFloat(config.panelWidth))
        let height = WindowContract.panelHeight(rows: rows, workAreaHeight: workArea.height)
        let origin = WindowContract.panelOrigin(
            corner: config.corner,
            marginX: config.marginX,
            marginY: config.marginY,
            size: CGSize(width: width, height: height),
            workArea: workArea
        )
        // 拖动落定前保留用户位置、仅应用尺寸；落定回调会以新停靠参数
        // 重新 publish，届时 origin 与用户落点精确往返，不再跳动。
        let frame = userPanelMovePending
            ? NSRect(origin: panel.frame.origin, size: CGSize(width: width, height: height))
            : NSRect(origin: origin, size: CGSize(width: width, height: height))

        suppressMovePersistence = true
        if panel.frame != frame {
            panel.setFrame(frame, display: false)
        }
        suppressMovePersistence = false
        lastAppliedFrame = frame

        panel.alphaValue = CGFloat(config.opacity) / 100
        contentView.update(sessions: visible)

        if WindowContract.shouldShowPanel(showIdle: showIdle, hasSessions: hasSessions, override: override) {
            reveal()
        } else {
            panel.orderOut(nil)
        }
    }

    /// 不抢焦点显示（对照 revealPanel：showInactive + moveTop）。
    func reveal() {
        panel.level = .floating
        panel.orderFrontRegardless()
    }

    var isVisible: Bool {
        panel.isVisible
    }

    var frame: NSRect {
        panel.frame
    }

    // MARK: - 拖拽落定持久化（对照 wm:574-607，220ms debounce）

    func windowDidMove(_ notification: Notification) {
        guard !suppressMovePersistence else { return }
        userPanelMovePending = true
        moveDebounceTimer?.invalidate()
        moveDebounceTimer = Timer.scheduledTimer(withTimeInterval: Self.moveDebounceMs, repeats: false) { [weak self] _ in
            self?.persistDroppedPosition()
        }
    }

    private func persistDroppedPosition() {
        userPanelMovePending = false
        guard let screen = Self.screen(forWindowCenter: panel.frame) ?? NSScreen.main else { return }
        let workArea = screen.visibleFrame
        let frame = panel.frame
        // 防止程序化 setFrame 误触发：与上次应用几何一致时跳过。
        if frame == lastAppliedFrame { return }
        let placement = WindowContract.placement(for: frame, workArea: workArea)
        // 落定帧记为已应用：随后的 apply 用新停靠参数算出的 origin 与其
        // 相同，不会触发 setFrame（对照 lastAppliedPanelBounds = finalBounds）。
        lastAppliedFrame = frame
        onPanelPositionChanged?(placement.corner, placement.marginX, placement.marginY, Self.displayId(of: screen))
    }

    // MARK: - 显示器工具

    static func displayId(of screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return ""
        }
        return number.stringValue
    }

    static func screen(forDisplayId displayId: String) -> NSScreen? {
        guard !displayId.isEmpty else { return nil }
        return NSScreen.screens.first { Self.displayId(of: $0) == displayId }
    }

    /// 按窗口中心点选显示器（对照 displayForBounds）。
    static func screen(forWindowCenter frame: NSRect) -> NSScreen? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) }
    }

    // MARK: - 显示器布局变化（对照 wm:609-623，100ms debounce）

    private var displayChangeObserver: Any?

    private func registerForDisplayChanges() {
        displayChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleDisplayLayoutChange()
        }
    }

    private var displayLayoutDebounce: Timer?
    private var pendingConfig: (config: AppConfig, sessions: [DisplaySession], showIdle: Bool, override: PanelVisibilityOverride?)?

    func handleDisplayLayoutChange() {
        displayLayoutDebounce?.invalidate()
        displayLayoutDebounce = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
            guard let self, let pending = self.pendingConfig else { return }
            self.apply(config: pending.config, sessions: pending.sessions, showIdle: pending.showIdle, override: pending.override)
        }
    }

    deinit {
        if let observer = displayChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
