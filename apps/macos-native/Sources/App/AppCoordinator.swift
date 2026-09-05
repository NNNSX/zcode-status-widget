import AppKit
import Core

/// 应用协调器（对照 src/main/index.ts）：
/// 生命周期防护 + EventServer → Reducer → 面板/提醒 接线 + 设置（预览-回读闭环）+ Hook 集成。
final class AppCoordinator: NSObject, NSApplicationDelegate {
    static let eventPortEnvironmentKey = "ZCODE_STATUS_PORT"

    private var config: AppConfig = .default
    private var previewConfig: AppConfig?
    private var panelOverride: PanelVisibilityOverride?
    private var hadSessions = false
    private var consumptionScheduled = false

    private let reducer = SessionReducer()
    private let eventServer: EventServer
    private lazy var hookManager = HookSupport.defaultManager()
    private lazy var persistence = PersistenceQueue { config in
        try SettingsStore.persist(config)
    }
    private var panelController: PanelWindowController?
    private let attentionController = AttentionWindowController()
    private var settingsController: SettingsWindowController?
    private var statusBar: StatusBarController?
    private var refreshTimer: Timer?

    private var startupReady = false
    private var startupFailed = false
    private var isQuitting = false
    /// 本次会话自选的 Hook config 路径（对照 index.ts 的 selectedHookConfigPath）：
    /// 选择后 inspect/configure/unconfigure 全部沿用，configure 成功后更新为写入路径。
    private var selectedHookConfigPath: String?

    private var effectiveConfig: AppConfig {
        previewConfig ?? config
    }

    override init() {
        // ZCODE_STATUS_PORT 之前只用于报错文案，服务器本身仍监听默认端口，
        // 环境变量改端口后 helper 与服务器端口不一致（对照 index.ts 读同一变量）。
        var eventServerOptions = EventServer.Options()
        eventServerOptions.port = Self.eventPort()
        eventServer = EventServer(options: eventServerOptions)
        super.init()
    }

    // MARK: - 启动（对照 index.ts:333-390）

    func applicationDidFinishLaunching(_ notification: Notification) {
        config = SettingsStore.load()

        let panel = PanelWindowController()
        panel.onPanelPositionChanged = { [weak self] corner, marginX, marginY, displayId in
            self?.saveSettings(AppConfigInput(corner: corner, marginX: marginX, marginY: marginY, displayId: displayId))
        }
        panelController = panel
        publish()

        statusBar = StatusBarController(actions: .init(
            togglePanel: { [weak self] in self?.togglePanel() },
            openSettings: { [weak self] in self?.openSettings() },
            resetPosition: { [weak self] in self?.resetPosition() },
            showAttentionDemo: { [weak self] in self?.showAttentionDemo() },
            quit: { NSApp.terminate(nil) }
        ))

        eventServer.onEnqueued = { [weak self] in
            DispatchQueue.main.async { self?.scheduleConsumption() }
        }
        do {
            try eventServer.start()
        } catch {
            startupFailed = true
            reportStartupFailure(error)
            return
        }
        startupReady = true

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.publish()
        }
        publish()

        // 引导：--setup-hooks 或 Hook 未配置时自动打开设置（对照 index.ts:371-373）。
        if CommandLine.arguments.contains("--setup-hooks") || !inspectHookIntegration().isConfigured {
            openSettings()
        }
    }

    private func reportStartupFailure(_ error: Error) {
        let port = Self.eventPort()
        let message = "端口 \(port) 已被其他状态灯实例占用，请检查是否有多个实例在运行。"
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "ZCode 会话状态"
        alert.informativeText = "\(message)\n\(error.localizedDescription)"
        alert.runModal()
        settleBeforeExit { [exitCode = 1] in
            exit(Int32(exitCode))
        }
    }

    private static func eventPort() -> UInt16 {
        guard let raw = ProcessInfo.processInfo.environment[eventPortEnvironmentKey],
              let port = UInt16(raw), (1...65535).contains(port) else { return 57310 }
        return port
    }

    // MARK: - 退出（对照 index.ts:392-409）

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isQuitting else { return .terminateNow }
        isQuitting = true
        refreshTimer?.invalidate()
        statusBar?.destroy()
        settleBeforeExit {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// 退出前收尾：事件服务器停机 + 设置落盘（对照 EXIT_GRACE_PERIOD_MS 5s 上限）。
    private func settleBeforeExit(_ completion: @escaping () -> Void) {
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { [eventServer] in
            eventServer.stop()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async { [persistence] in
            // 对照 Windows 的 allSettled（不阻塞退出），但留下日志便于排查丢设置。
            do {
                try persistence.flush()
            } catch {
                NSLog("[ZCodeStatusLight] 退出前设置落盘失败：%@", String(describing: error))
            }
            group.leave()
        }
        let timeout = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { timeout.signal() }
        _ = group.wait(timeout: .now() + 5)
        completion()
    }

    // MARK: - 事件消费（对照 index.ts:199-221）

    private func scheduleConsumption() {
        guard !consumptionScheduled else { return }
        consumptionScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.consumptionScheduled = false
            self.consumeEvents()
        }
    }

    private func consumeEvents() {
        // 每轮最多 drain 32 条（maxEventsPerTick），有剩余则重排到下一个 runloop，
        // 避免事件洪峰长时间占用主线程（对照 index.ts consumeEvents + MAX_EVENTS_PER_TICK）。
        for event in eventServer.drain() {
            let result = reducer.apply(event, now: currentMilliseconds())
            if result.accepted {
                applyEffects(result.effects)
            }
        }
        if eventServer.pending > 0 {
            scheduleConsumption()
        }
        publish()
    }

    private func currentMilliseconds() -> Double {
        Date().timeIntervalSince1970 * 1000
    }

    /// 提醒效果 → 窗口（对照 index.ts:176-179 与 attention-policy）。
    private func applyEffects(_ effects: [ReducerEffect]) {
        for effect in effects {
            switch effect {
            case .cancelAttention(let sessionId):
                attentionController.closeAttention(sessionId: sessionId)
            case .showAttention(let content):
                showAttention(content: content)
            }
        }
    }

    /// 按当前配置的提醒方式显示提醒（kind none 立即关闭，对照 index.ts:176-179, 223-227）。
    private func showAttention(content: AttentionContent) {
        let request = AttentionPolicy.request(for: effectiveConfig)
        switch request.kind {
        case .none:
            attentionController.closeAttention(sessionId: nil)
        case .edge:
            attentionController.showAttention(
                content: content,
                durationMs: request.durationMs,
                placement: .edge,
                panelFrame: panelController?.frame
            )
        case .overlay(let placement):
            attentionController.showAttention(
                content: content,
                durationMs: request.durationMs,
                placement: placement,
                panelFrame: panelController?.frame,
                panelCorner: effectiveConfig.corner
            )
        }
    }

    // MARK: - 发布（对照 index.ts:161-165 + wm:293-301, 545-550）

    private func publish() {
        let config = effectiveConfig
        let sessions = reducer.displaySessions(
            now: currentMilliseconds(),
            doneTtlMinutes: config.doneTtlMinutes,
            showTodoProgress: config.showTodoProgress,
            showDuration: config.showDuration
        )
        let hasSessions = !sessions.isEmpty
        if (!hadSessions && hasSessions) || (hadSessions && !hasSessions && panelOverride == .visible) {
            panelOverride = nil
        }
        hadSessions = hasSessions
        let showIdle = config.showIdle || (panelOverride == .visible && !hasSessions)
        panelController?.apply(config: config, sessions: sessions, showIdle: showIdle, override: panelOverride)
    }

    // MARK: - 托盘动作

    /// Hook 集成检查（只读）；优先用本次会话自选的路径（index.ts:73）。
    func inspectHookIntegration(_ requestedPath: String? = nil) -> HookSetupSnapshot {
        hookManager.inspect(requestedPath ?? selectedHookConfigPath)
    }

    private func togglePanel() {
        guard let panelController else { return }
        if panelController.isVisible {
            panelOverride = .hidden
        } else {
            panelOverride = .visible
        }
        publish()
    }

    /// 显示面板（二次启动激活等场景）。
    private func showPanel() {
        guard startupReady, !isQuitting, !startupFailed else { return }
        panelOverride = .visible
        publish()
    }

    // MARK: - 设置（对照 index.ts:229-324 + settings-session.ts）

    private func openSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController()
        }
        settingsController?.open(
            savedConfig: effectiveConfig,
            panelFrame: panelController?.frame,
            handlers: settingsHandlers(),
            onClosed: { [weak self] in
                self?.discardPreviewSettings()
            }
        )
    }

    private func settingsHandlers() -> SettingsHandlers {
        SettingsHandlers(
            preview: { [weak self] input in
                self?.previewSettings(input) ?? .default
            },
            save: { [weak self] draft, completion in
                guard let self else { return completion("无法保存设置。") }
                self.saveSettingsDraft(draft) { error in
                    if error == nil {
                        self.settingsController?.close()
                    }
                    completion(error)
                }
            },
            cancel: { [weak self] in
                self?.settingsController?.close()
            },
            resetPosition: { [weak self] draft in
                self?.previewResetPosition(draft) ?? draft
            },
            refreshHookSetup: { [weak self] in
                self?.inspectHookIntegration() ?? HookSetupSnapshot(
                    configPath: "", databasePath: "", status: .invalid,
                    message: "无法执行检查。", isConfigured: false,
                    requiresEnableConfirmation: false, ruleCount: HookIntegration.ruleCount
                )
            },
            chooseHookConfig: { [weak self] in
                self?.chooseHookConfig()
            },
            configureHook: { [weak self] enable, completion in
                self?.configureHooks(enableDisabledHooks: enable, completion: completion)
                    ?? completion("无法执行配置。")
            },
            unconfigureHook: { [weak self] completion in
                self?.unconfigureHooks(completion: completion)
                    ?? completion("无法执行移除。")
            },
            showAttentionDemo: { [weak self] in
                self?.showAttentionDemo()
            }
        )
    }

    /// 预览：以 preview??saved 为基底叠增量，回读规范化结果（settings-session.ts:3-7）。
    private func previewSettings(_ input: AppConfigInput) -> AppConfig {
        let base = previewConfig ?? config
        previewConfig = AppConfig.normalized(base: base, input: input)
        closeAttentionWhenDisabled()
        publish()
        return previewConfig!
    }

    /// 保存：以 saved 为基底合并（非 preview 基底），清 preview，140ms 防抖落盘。
    /// “保存并关闭”路径同步 flush（对照 settingsRegistry.save 的 await persist），
    /// 失败回报给设置窗显示、窗口保持打开；成功才关闭。
    private func saveSettingsDraft(_ draft: AppConfig, completion: @escaping (String?) -> Void) {
        let saved = AppConfig(
            corner: draft.corner, marginX: draft.marginX, marginY: draft.marginY,
            displayId: draft.displayId, opacity: draft.opacity, showIdle: draft.showIdle,
            showTodoProgress: draft.showTodoProgress, showDuration: draft.showDuration,
            panelWidth: draft.panelWidth, doneTtlMinutes: draft.doneTtlMinutes,
            attentionMode: draft.attentionMode, attentionDurationMs: draft.attentionDurationMs
        )
        config = AppConfig.normalized(base: config, input: AppConfigInput(
            corner: saved.corner, marginX: saved.marginX, marginY: saved.marginY,
            displayId: saved.displayId, opacity: saved.opacity, showIdle: saved.showIdle,
            showTodoProgress: saved.showTodoProgress, showDuration: saved.showDuration,
            panelWidth: saved.panelWidth, doneTtlMinutes: saved.doneTtlMinutes,
            attentionMode: saved.attentionMode, attentionDurationMs: saved.attentionDurationMs
        ))
        previewConfig = nil
        closeAttentionWhenDisabled()
        persistence.schedule(config)
        publish()
        do {
            try persistence.flush()
            completion(nil)
        } catch {
            NSLog("[ZCodeStatusLight] 设置保存失败：%@", String(describing: error))
            completion("设置保存失败：\(error.localizedDescription)。请检查磁盘权限后重试。")
        }
    }

    /// 位置保存（拖拽落定）等入口。
    private func saveSettings(_ input: AppConfigInput) {
        config = AppConfig.normalized(base: config, input: input)
        previewConfig = nil
        persistence.schedule(config)
        publish()
    }

    /// 取消预览回滚到已保存值（关闭设置窗口路径）。
    private func discardPreviewSettings() {
        previewConfig = nil
        closeAttentionWhenDisabled()
        publish()
    }

    /// 重置位置：以 draft 为基底恢复默认位置字段（对照 previewResetPosition）。
    private func previewResetPosition(_ draft: AppConfig) -> AppConfig {
        let base = AppConfig.normalized(
            base: previewConfig ?? config,
            input: AppConfigInput(
                corner: draft.corner, marginX: draft.marginX, marginY: draft.marginY, displayId: draft.displayId
            )
        )
        let reset = base.resettingPosition()
        previewConfig = reset
        publish()
        return reset
    }

    /// 预览/保存后提醒被关掉 → 立即关闭当前提醒（对照 closeAttentionWhenDisabled）。
    private func closeAttentionWhenDisabled() {
        if effectiveConfig.attentionMode == .off {
            attentionController.closeAttention(sessionId: nil)
        }
    }

    private func resetPosition() {
        let reset = effectiveConfig.resettingPosition()
        saveSettings(AppConfigInput(
            corner: reset.corner,
            marginX: reset.marginX,
            marginY: reset.marginY,
            displayId: reset.displayId
        ))
    }

    private func showAttentionDemo() {
        showAttention(content: .demo)
    }

    // MARK: - Hook 集成（对照 index.ts:70-146, 295-298）

    private func chooseHookConfig() -> HookSetupSnapshot? {
        let panel = NSOpenPanel()
        panel.title = "选择 ZCode Hook config.json"
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        let suggested = selectedHookConfigPath ?? hookManager.suggestedConfigPath()
        panel.directoryURL = URL(fileURLWithPath: (suggested as NSString).deletingLastPathComponent)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        selectedHookConfigPath = url.path
        return inspectHookIntegration()
    }

    /// 配置 Hook：主线程弹确认对话框（AppKit 窗口禁止在后台线程创建），
    /// 用户确认后文件事务（锁等待最长 2s）转后台，结果经 completion 回主线程。
    /// 成功后把会话路径更新为实际写入路径（index.ts:113-114）。
    private func configureHooks(enableDisabledHooks: Bool, completion: @escaping (String?) -> Void) {
        let snapshot = inspectHookIntegration()
        guard HookConfirmationDialog.requestConfigure(snapshot: snapshot) else { return completion(nil) }
        let requestedPath = selectedHookConfigPath
        DispatchQueue.global(qos: .userInitiated).async { [hookManager] in
            let result: String?
            var verifiedPath: String?
            do {
                let verified = try hookManager.configure(requestedPath, enableDisabledHooks: enableDisabledHooks)
                verifiedPath = verified.configPath
                result = verified.isConfigured ? nil : "写入后未能验证全部状态 Hook。"
            } catch {
                result = (error as? LocalizedError)?.errorDescription ?? "配置 Hook 失败。"
            }
            DispatchQueue.main.async { [weak self] in
                if let verifiedPath {
                    self?.selectedHookConfigPath = verifiedPath
                }
                completion(result)
            }
        }
    }

    /// 取消集成：同样主线程确认、后台事务、主线程回调；成功后沿用本次路径。
    private func unconfigureHooks(completion: @escaping (String?) -> Void) {
        let snapshot = inspectHookIntegration()
        guard HookConfirmationDialog.requestUnconfigure(snapshot: snapshot) else { return completion(nil) }
        DispatchQueue.global(qos: .userInitiated).async { [hookManager] in
            let result: String?
            do {
                let removed = try hookManager.unconfigure()
                result = removed ? nil : "当前 Hook 集成记录不可用或不属于此安装实例，已拒绝移除。"
            } catch {
                result = (error as? LocalizedError)?.errorDescription ?? "移除 Hook 失败。"
            }
            DispatchQueue.main.async { [weak self] in
                if result == nil {
                    self?.selectedHookConfigPath = snapshot.configPath
                }
                completion(result)
            }
        }
    }
}
