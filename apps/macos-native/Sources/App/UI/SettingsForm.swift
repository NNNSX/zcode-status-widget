import AppKit
import Core
import SwiftUI

/// 设置表单（对照 renderer/main.ts renderSettings：全部设置项 + Hook 区块 + 底部操作条）。
/// draft 本地先行合并，preview 回读规范化值覆盖 draft（丢弃过期响应由串行主线程保证）。
struct SettingsForm: View {
    @State private var draft: AppConfig
    @State private var hookSnapshot: HookSetupSnapshot?
    @State private var hookError: String?
    @State private var hookBusy = false
    @State private var hookChecked = false
    @State private var saveError: String?

    private let handlers: SettingsHandlers

    init(initial: AppConfig, handlers: SettingsHandlers) {
        _draft = State(initialValue: initial)
        self.handlers = handlers
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Group {
                        widthSection
                        cornerSection
                        togglesSection
                        opacitySection
                        doneTtlSection
                    }
                    Group {
                        attentionModeSection
                        attentionDurationSection
                    }
                    hookSection
                }
                .padding(12)
            }
            Divider().overlay(Palette.border)
            footer
        }
        .frame(minWidth: 328, maxWidth: 328, maxHeight: .infinity, alignment: .top)
        .background(Palette.surface)
        .onAppear {
            refreshHook()
        }
    }

    // MARK: - 区块

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text("ZCode Status Light")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Palette.eyebrowText)
                Text("显示设置")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.titleText)
            }
            Spacer()
            Button(action: { handlers.cancel() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.muted)
            }
            .buttonStyle(.plain)
            .help("关闭设置")
            .accessibilityLabel("关闭设置")
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 8, trailing: 12))
    }

    private var widthSection: some View {
        LabeledSlider(
            label: "面板宽度",
            value: Binding(
                get: { Double(draft.panelWidth) },
                set: { preview(AppConfigInput(panelWidth: Int($0))) }
            ),
            bounds: 220...640,
            step: 20,
            format: { "\(Int($0)) px" }
        )
    }

    private var cornerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("停靠位置")
            HStack(spacing: 6) {
                ForEach(Array(cornerOptions.enumerated()), id: \.offset) { _, option in
                    SegmentedButton(
                        title: option.title,
                        selected: draft.corner == option.value
                    ) {
                        preview(AppConfigInput(corner: option.value))
                    }
                }
            }
        }
    }

    private var togglesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ToggleRow(title: "显示 Todo 进度", isOn: Binding(
                get: { draft.showTodoProgress },
                set: { preview(AppConfigInput(showTodoProgress: $0)) }
            ))
            ToggleRow(title: "显示时间", isOn: Binding(
                get: { draft.showDuration },
                set: { preview(AppConfigInput(showDuration: $0)) }
            ))
            ToggleRow(title: "无会话时显示空闲状态", isOn: Binding(
                get: { draft.showIdle },
                set: { preview(AppConfigInput(showIdle: $0)) }
            ))
        }
    }

    private var opacitySection: some View {
        LabeledSlider(
            label: "面板透明度",
            value: Binding(
                get: { Double(draft.opacity) },
                set: { preview(AppConfigInput(opacity: Int($0))) }
            ),
            bounds: 20...100,
            step: 5,
            format: { "\(Int($0))%" }
        )
    }

    private var doneTtlSection: some View {
        LabeledSlider(
            label: "完成保留时间",
            value: Binding(
                get: { Double(draft.doneTtlMinutes) },
                set: { preview(AppConfigInput(doneTtlMinutes: Int($0))) }
            ),
            bounds: 1...30,
            step: 1,
            format: { "\(Int($0)) 分钟" }
        )
    }

    private var attentionModeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("全局提醒方式")
                Spacer()
                Text(attentionDetail)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.muted)
            }
            HStack(spacing: 6) {
                ForEach(attentionOptions, id: \.value) { option in
                    SegmentedButton(
                        title: option.title,
                        selected: draft.attentionMode == option.value
                    ) {
                        preview(AppConfigInput(attentionMode: option.value))
                    }
                }
            }
        }
    }

    private var attentionDetail: String {
        switch draft.attentionMode {
        case .off: return "不显示全局提醒"
        case .panelPulse: return "沿屏幕边缘提示"
        case .cornerOverlay: return "在屏幕角落提示"
        case .centerOverlay: return "在屏幕中央提示"
        }
    }

    private var attentionDurationSection: some View {
        LabeledSlider(
            label: "提醒展示时长",
            value: Binding(
                get: { Double(draft.attentionDurationMs) },
                set: { preview(AppConfigInput(attentionDurationMs: Int($0))) }
            ),
            bounds: 800...5000,
            step: 100,
            format: { "\(Int($0)) 毫秒" }
        )
    }

    private var hookSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("连接 ZCode Hook")
                Spacer()
                Text("仅本机回环")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.muted)
            }
            if let hookSnapshot {
                Text(hookSnapshot.message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(hookStatusColor(hookSnapshot.status))
                    .fixedSize(horizontal: false, vertical: true)
                Text(hookSnapshot.configPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(2)
                    .truncationMode(.middle)
            } else if !hookChecked {
                Text("正在检查默认 Hook 配置...")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.muted)
            }
            if let hookError {
                Text(hookError)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.hookInvalid)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Button("选择 Hook config.json") {
                    if let snapshot = handlers.chooseHookConfig() {
                        hookSnapshot = snapshot
                    }
                }
                .buttonStyle(QuietButtonStyle())
                Button(hookActionButtonTitle) {
                    runHookAction()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(hookButtonDisabled || hookBusy)
                Button("移除 Hook") {
                    runHookRemoval()
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(!(hookSnapshot?.isConfigured ?? false) || hookBusy)
            }
        }
        .padding(10)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.border))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("连接 ZCode Hook")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let saveError {
                Text(saveError)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.hookInvalid)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Button("重置位置") {
                    draft = handlers.resetPosition(draft)
                }
                .buttonStyle(QuietButtonStyle())
                Button {
                    handlers.showAttentionDemo()
                } label: {
                    Image(systemName: "bell.badge")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.titleText)
                }
                .buttonStyle(QuietButtonStyle())
                .help("预览提醒")
                .accessibilityLabel("预览提醒")
                Spacer()
                Button("保存并关闭") {
                    saveError = nil
                    handlers.save(draft) { error in
                        saveError = error
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
    }

    // MARK: - Hook 区块状态机（对照 renderSettings hook 部分）

    private var hookActionButtonTitle: String {
        if hookBusy { return hookSnapshot?.isConfigured == true ? "正在配置..." : "正在配置..." }
        guard let hookSnapshot else { return "配置 Hook" }
        if hookSnapshot.isConfigured { return "Hook 已配置" }
        if hookSnapshot.requiresEnableConfirmation { return "确认启用并配置 Hook" }
        return "配置 \(hookSnapshot.ruleCount) 条 Hook"
    }

    private var hookButtonDisabled: Bool {
        guard let hookSnapshot else { return true }
        return hookSnapshot.status == .missing || hookSnapshot.status == .invalid || hookSnapshot.isConfigured
    }

    private func hookStatusColor(_ status: HookSetupStatus) -> Color {
        switch status {
        case .configured: return Palette.hookConfigured
        case .disabled, .invalid: return Palette.hookInvalid
        case .missing: return Palette.hookMissing
        case .ready: return Palette.hookReady
        }
    }

    private func refreshHook() {
        hookSnapshot = handlers.refreshHookSetup()
        hookChecked = true
        // 不在此清 hookError：configure/unconfigure 的 completion 会先设置错误再
        // 刷新快照，这里清空会把刚上报的错误立即抹掉，用户永远看不到失败原因。
    }

    private func runHookAction() {
        guard let snapshot = hookSnapshot else { return }
        let enable = snapshot.requiresEnableConfirmation
        hookBusy = true
        hookError = nil
        handlers.configureHook(enable) { error in
            hookBusy = false
            hookError = error
            refreshHook()
        }
    }

    private func runHookRemoval() {
        hookBusy = true
        hookError = nil
        handlers.unconfigureHook { error in
            hookBusy = false
            hookError = error
            refreshHook()
        }
    }

    // MARK: - 预览闭环

    private func preview(_ input: AppConfigInput) {
        // 本地先行合并（对照 draft = {...draft, ...input}），再回读规范化值。
        draft = AppConfig.normalized(base: draft, input: input)
        draft = handlers.preview(input)
    }

    private var cornerOptions: [(title: String, value: PanelCorner)] {
        [("右下", .bottomRight), ("左下", .bottomLeft), ("右上", .topRight), ("左上", .topLeft)]
    }

    private var attentionOptions: [(title: String, value: AttentionMode)] {
        [("关闭", .off), ("边缘", .panelPulse), ("角落", .cornerOverlay), ("中央", .centerOverlay)]
    }
}

// MARK: - 复用控件

private struct SectionLabel: View {
    let title: String
    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Palette.labelText)
    }
}

private struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let bounds: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SectionLabel(label)
                Spacer()
                Text(format(value))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Palette.muted)
            }
            Slider(value: $value, in: bounds, step: step)
                .tint(Palette.accent)
        }
    }
}

private struct SegmentedButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(selected ? Palette.accentText : Palette.muted)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? Palette.accentSoft : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Palette.labelText)
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Palette.toggleOn)
        }
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color(red: 0.07, green: 0.13, blue: 0.09))
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .frame(minWidth: 56)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(
                    configuration.isPressed
                        ? Palette.primary.opacity(0.8)
                        : Palette.primary
                )
            )
    }
}

private struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11))
            .foregroundStyle(Palette.muted)
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(
                    configuration.isPressed ? Color.white.opacity(0.08) : Color.white.opacity(0.04)
                )
            )
    }
}

// MARK: - 配色（对照 styles.css 通用面）

private enum Palette {
    static let surface = Color(red: 25/255, green: 29/255, blue: 35/255).opacity(0.96)
    static let border = Color.white.opacity(0.14)
    static let titleText = Color(red: 0.93, green: 0.95, blue: 0.97)
    static let eyebrowText = Color(red: 0.62, green: 0.65, blue: 0.71)
    static let labelText = Color(red: 0.80, green: 0.84, blue: 0.89)
    static let muted = Color(red: 0.71, green: 0.76, blue: 0.83)
    static let accent = Color(red: 242/255, green: 193/255, blue: 78/255)          // #f2c14e
    static let accentSoft = Color(red: 242/255, green: 193/255, blue: 78/255).opacity(0.18)
    static let accentText = Color(red: 0.96, green: 0.97, blue: 0.98)
    static let toggleOn = Color(red: 73/255, green: 108/255, blue: 90/255)         // #496c5a
    static let primary = Color(red: 167/255, green: 215/255, blue: 177/255)        // #a7d7b1
    static let hookConfigured = Color(red: 134/255, green: 217/255, blue: 164/255) // #86d9a4
    static let hookInvalid = Color(red: 1.0, green: 157/255, blue: 161/255)        // #ff9da1
    static let hookMissing = Color(red: 229/255, green: 193/255, blue: 106/255)    // #e5c16a
    static let hookReady = Color(red: 182/255, green: 193/255, blue: 208/255)      // #b6c1d0
}
