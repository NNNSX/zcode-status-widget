import Foundation

/// 停靠角落（对照 src/shared/config.ts:1-3）。
public enum PanelCorner: String, Codable, CaseIterable, Sendable {
    case bottomRight = "bottom-right"
    case bottomLeft = "bottom-left"
    case topRight = "top-right"
    case topLeft = "top-left"
}

/// 全局提醒方式（对照 config.ts:2）。
public enum AttentionMode: String, Codable, CaseIterable, Sendable {
    case off
    case panelPulse = "panel-pulse"
    case cornerOverlay = "corner-overlay"
    case centerOverlay = "center-overlay"
}

/// 应用配置（对照 config.ts:6-18，12 个字段）。
public struct AppConfig: Equatable, Codable, Sendable {
    public var corner: PanelCorner
    public var marginX: Int
    public var marginY: Int
    public var displayId: String
    public var opacity: Int
    public var showIdle: Bool
    public var showTodoProgress: Bool
    public var showDuration: Bool
    public var panelWidth: Int
    public var doneTtlMinutes: Int
    public var attentionMode: AttentionMode
    public var attentionDurationMs: Int

    public init(
        corner: PanelCorner,
        marginX: Int,
        marginY: Int,
        displayId: String,
        opacity: Int,
        showIdle: Bool,
        showTodoProgress: Bool,
        showDuration: Bool,
        panelWidth: Int,
        doneTtlMinutes: Int,
        attentionMode: AttentionMode,
        attentionDurationMs: Int
    ) {
        self.corner = corner
        self.marginX = marginX
        self.marginY = marginY
        self.displayId = displayId
        self.opacity = opacity
        self.showIdle = showIdle
        self.showTodoProgress = showTodoProgress
        self.showDuration = showDuration
        self.panelWidth = panelWidth
        self.doneTtlMinutes = doneTtlMinutes
        self.attentionMode = attentionMode
        self.attentionDurationMs = attentionDurationMs
    }

    /// 默认值（对照 config.ts:27-40）。
    public static let `default` = AppConfig(
        corner: .bottomRight,
        marginX: 14,
        marginY: 52,
        displayId: "",
        opacity: 100,
        showIdle: true,
        showTodoProgress: true,
        showDuration: true,
        panelWidth: 280,
        doneTtlMinutes: 5,
        attentionMode: .centerOverlay,
        attentionDurationMs: 1800
    )
}

/// 部分配置输入（对照 preload 的 AppConfigInput；Swift 强类型使 TS 的宽松字符串校验不再必要）。
public struct AppConfigInput: Sendable {
    public var corner: PanelCorner?
    public var marginX: Int?
    public var marginY: Int?
    public var displayId: String?
    public var opacity: Int?
    public var showIdle: Bool?
    public var showTodoProgress: Bool?
    public var showDuration: Bool?
    public var panelWidth: Int?
    public var doneTtlMinutes: Int?
    public var attentionMode: AttentionMode?
    public var attentionDurationMs: Int?

    public init(
        corner: PanelCorner? = nil,
        marginX: Int? = nil,
        marginY: Int? = nil,
        displayId: String? = nil,
        opacity: Int? = nil,
        showIdle: Bool? = nil,
        showTodoProgress: Bool? = nil,
        showDuration: Bool? = nil,
        panelWidth: Int? = nil,
        doneTtlMinutes: Int? = nil,
        attentionMode: AttentionMode? = nil,
        attentionDurationMs: Int? = nil
    ) {
        self.corner = corner
        self.marginX = marginX
        self.marginY = marginY
        self.displayId = displayId
        self.opacity = opacity
        self.showIdle = showIdle
        self.showTodoProgress = showTodoProgress
        self.showDuration = showDuration
        self.panelWidth = panelWidth
        self.doneTtlMinutes = doneTtlMinutes
        self.attentionMode = attentionMode
        self.attentionDurationMs = attentionDurationMs
    }
}

/// 取值范围常量（对照 config.ts:20-25；panelWidth 下限 2026-09-05 两轮放宽到 220：
/// 挂件化密度下调，320 的旧下限不再够小）。
public enum ConfigLimits {
    public static let panelWidth = 220...640
    public static let doneTtlMinutes = 1...30
    public static let attentionDurationMs = 800...5000
    public static let opacity = 20...100
}

func clamped(_ value: Int, _ range: ClosedRange<Int>) -> Int {
    min(range.upperBound, max(range.lowerBound, value))
}

extension AppConfig {
    /// 归一化：base 叠加 input 后钳制（对照 config.ts:98-136 的 normalizeConfig 与 settings-session.ts）。
    public static func normalized(base: AppConfig = .default, input: AppConfigInput) -> AppConfig {
        var config = base
        if let corner = input.corner { config.corner = corner }
        if let marginX = input.marginX { config.marginX = max(0, marginX) }
        if let marginY = input.marginY { config.marginY = max(0, marginY) }
        if let displayId = input.displayId { config.displayId = displayId.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let opacity = input.opacity { config.opacity = clamped(opacity, ConfigLimits.opacity) }
        if let showIdle = input.showIdle { config.showIdle = showIdle }
        if let showTodoProgress = input.showTodoProgress { config.showTodoProgress = showTodoProgress }
        if let showDuration = input.showDuration { config.showDuration = showDuration }
        if let panelWidth = input.panelWidth { config.panelWidth = clamped(panelWidth, ConfigLimits.panelWidth) }
        if let doneTtlMinutes = input.doneTtlMinutes { config.doneTtlMinutes = clamped(doneTtlMinutes, ConfigLimits.doneTtlMinutes) }
        if let attentionMode = input.attentionMode { config.attentionMode = attentionMode }
        if let attentionDurationMs = input.attentionDurationMs { config.attentionDurationMs = clamped(attentionDurationMs, ConfigLimits.attentionDurationMs) }
        return config
    }

    /// 全量钳制（对照 Windows 读取 settings.json 后整体过 normalizeConfig）：
    /// 手改文件写入的越界值在加载时收敛到合法范围，而不是带进运行时
    /// （normalized(base:input:) 是增量叠加，空 input 不会重新钳 base）。
    public func normalized() -> AppConfig {
        var config = self
        config.marginX = max(0, config.marginX)
        config.marginY = max(0, config.marginY)
        config.displayId = config.displayId.trimmingCharacters(in: .whitespacesAndNewlines)
        config.opacity = clamped(config.opacity, ConfigLimits.opacity)
        config.panelWidth = clamped(config.panelWidth, ConfigLimits.panelWidth)
        config.doneTtlMinutes = clamped(config.doneTtlMinutes, ConfigLimits.doneTtlMinutes)
        config.attentionDurationMs = clamped(config.attentionDurationMs, ConfigLimits.attentionDurationMs)
        return config
    }

    /// 重置位置字段，其余保留（对照 config.ts:90-96 resetPositionConfig）。
    public func resettingPosition() -> AppConfig {
        var config = self
        config.corner = AppConfig.default.corner
        config.marginX = AppConfig.default.marginX
        config.marginY = AppConfig.default.marginY
        config.displayId = AppConfig.default.displayId
        return config
    }
}
