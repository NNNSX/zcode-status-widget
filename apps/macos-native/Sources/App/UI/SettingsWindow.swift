import AppKit
import Core
import SwiftUI

/// 设置窗口（对照 window-manager.ts settings 部分 + renderer renderSettings）。
/// borderless、356xmin(760, workArea-32)、面板屏右上 16/16 锚定、floating 层；
/// draft 在表单内，每次变更走 preview 回调并回读规范化结果（预览-回读闭环）；
/// 关闭即取消预览（回滚到已保存值）。
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private class SettingsWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    /// borderless 窗口里 NSHostingView 默认拒绝背景拖动，必须覆写；
    /// 控件（Slider/Toggle 等 NSControl）自身仍返回 false，不受影响。
    private class DraggableHostingView<Content: View>: NSHostingView<Content> {
        override var mouseDownCanMoveWindow: Bool { true }
    }

    private var window: SettingsWindow?
    private var lastBounds = NSRect.zero

    func open(
        savedConfig: AppConfig,
        panelFrame: NSRect?,
        handlers: SettingsHandlers,
        onClosed: @escaping () -> Void
    ) {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let screen = AttentionWindowController.screen(forPanelFrame: panelFrame) ?? NSScreen.main
        let workArea = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let bounds = WindowContract.settingsBounds(workArea: workArea)

        let host = SettingsForm(
            initial: savedConfig,
            handlers: handlers
        )
        let contentView = DraggableHostingView(rootView: host)
        let newWindow = SettingsWindow(
            contentRect: bounds,
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // 透明标题栏方案：SwiftUI 表单是滚动容器，会吞掉背景 mouseDown，
        // isMovableByWindowBackground 拖不动；用系统标题栏提供原生拖动区
        // （fullSizeContentView 让内容延伸铺满，视觉仍为无边框全尺寸）。
        newWindow.titlebarAppearsTransparent = true
        newWindow.titleVisibility = .hidden
        newWindow.standardWindowButton(.closeButton)?.isHidden = true
        newWindow.standardWindowButton(.miniaturizeButton)?.isHidden = true
        newWindow.standardWindowButton(.zoomButton)?.isHidden = true
        newWindow.isOpaque = false
        newWindow.backgroundColor = .clear
        newWindow.hasShadow = true
        newWindow.isMovableByWindowBackground = true
        newWindow.level = .floating
        newWindow.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        newWindow.isReleasedWhenClosed = false
        newWindow.contentView = contentView
        newWindow.delegate = self
        window = newWindow
        lastBounds = bounds
        onClosedInternal = onClosed
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var onClosedInternal: (() -> Void)?

    func close() {
        window?.orderOut(nil)
        windowDidClose()
    }

    var isVisible: Bool {
        window?.isVisible ?? false
    }

    private func windowDidClose() {
        window?.delegate = nil
        window = nil
        onClosedInternal?()
        onClosedInternal = nil
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        windowDidClose()
    }

    /// 拖动落定 clamp 到 workArea（对照 moveSettingsDrag 的 clamp 语义）。
    func windowDidMove(_ notification: Notification) {
        guard let window else { return }
        let workArea = (AttentionWindowController.screen(forPanelFrame: window.frame) ?? NSScreen.main)?.visibleFrame
            ?? window.frame
        let clampedOrigin = WindowContract.clampOrigin(window.frame.origin, size: window.frame.size, workArea: workArea)
        if window.frame.origin != clampedOrigin {
            window.setFrameOrigin(clampedOrigin)
        }
    }

    /// 显示器布局变化：重算边界（对照 100ms 防抖后的 repositionSettings）。
    func handleDisplayLayoutChange(panelFrame: NSRect?) {
        guard let window, window.isVisible else { return }
        let workArea = (AttentionWindowController.screen(forPanelFrame: panelFrame) ?? NSScreen.main)?.visibleFrame
            ?? window.frame
        let bounds = WindowContract.settingsBounds(workArea: workArea)
        window.setFrame(bounds, display: true)
    }
}

/// 设置表单与主进程交互的回调集合（对照 preload API 面）。
/// configure/unconfigure 含确认对话框与文件事务：对话框在主线程弹出，
/// 事务在后台执行，结果经 completion 在主线程返回。
/// save 同样带 completion：落盘失败时回传错误文本，表单保持打开并提示。
struct SettingsHandlers {
    var preview: (AppConfigInput) -> AppConfig
    var save: (AppConfig, @escaping (String?) -> Void) -> Void
    var cancel: () -> Void
    var resetPosition: (AppConfig) -> AppConfig
    var refreshHookSetup: () -> HookSetupSnapshot
    var chooseHookConfig: () -> HookSetupSnapshot?
    var configureHook: (Bool, @escaping (String?) -> Void) -> Void
    var unconfigureHook: (@escaping (String?) -> Void) -> Void
    var showAttentionDemo: () -> Void
}
