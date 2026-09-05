import Foundation

/// 会话状态（对照 src/shared/protocol.ts:1）。
public enum SessionState: String, Codable, Sendable {
    case working
    case waiting
    case done
    case unknown
}

/// 入站 todo 项（sanitizer 校验通过后）。
public struct TodoItem: Equatable, Sendable {
    public var content: String
    public var status: String

    public init(content: String, status: String) {
        self.content = content
        self.status = status
    }
}

/// hook helper POST 的载荷（字段均可缺省，归一化在 Reducer 中进行）。
public struct HookEvent: Equatable, Sendable {
    public var event: String
    public var sessionId: String?
    public var project: String?
    public var projectDir: String?
    public var workspaceDir: String?
    public var workspaceSource: String?
    public var promptPreview: String?
    public var lastTool: String?
    public var errorPreview: String?
    public var todos: [TodoItem]?
    public var currentTask: String?
    public var turnId: String?
    public var ts: Double?

    public init(
        event: String,
        sessionId: String? = nil,
        project: String? = nil,
        projectDir: String? = nil,
        workspaceDir: String? = nil,
        workspaceSource: String? = nil,
        promptPreview: String? = nil,
        lastTool: String? = nil,
        errorPreview: String? = nil,
        todos: [TodoItem]? = nil,
        currentTask: String? = nil,
        turnId: String? = nil,
        ts: Double? = nil
    ) {
        self.event = event
        self.sessionId = sessionId
        self.project = project
        self.projectDir = projectDir
        self.workspaceDir = workspaceDir
        self.workspaceSource = workspaceSource
        self.promptPreview = promptPreview
        self.lastTool = lastTool
        self.errorPreview = errorPreview
        self.todos = todos
        self.currentTask = currentTask
        self.turnId = turnId
        self.ts = ts
    }
}

/// 面板单行展示模型（对照 protocol.ts:29-36）。
public struct DisplaySession: Equatable, Sendable {
    public var id: String
    public var state: SessionState
    public var workspace: String
    public var task: String
    public var todoProgress: String
    public var duration: String

    public init(id: String, state: SessionState, workspace: String, task: String, todoProgress: String, duration: String) {
        self.id = id
        self.state = state
        self.workspace = workspace
        self.task = task
        self.todoProgress = todoProgress
        self.duration = duration
    }
}

/// 面板快照（对照 protocol.ts:38-41）。
public struct PanelSnapshot: Equatable, Sendable {
    public var sessions: [DisplaySession]
    public var showIdle: Bool

    public init(sessions: [DisplaySession], showIdle: Bool) {
        self.sessions = sessions
        self.showIdle = showIdle
    }
}

/// 提醒内容（对照 protocol.ts:43-49）。
public struct AttentionContent: Equatable, Sendable {
    public enum Kind: String, Sendable { case waiting, done }

    public var sessionId: String
    public var kind: Kind
    public var title: String
    public var workspace: String
    public var summary: String

    public init(sessionId: String, kind: Kind, title: String, workspace: String, summary: String) {
        self.sessionId = sessionId
        self.kind = kind
        self.title = title
        self.workspace = workspace
        self.summary = summary
    }

    public static let demo = AttentionContent(
        sessionId: "demo",
        kind: .waiting,
        title: "请完成审批",
        workspace: "ZCode",
        summary: ""
    )
}

/// reducer 副作用（对照 protocol.ts:51-55）。
public enum ReducerEffect: Equatable, Sendable {
    case cancelAttention(sessionId: String)
    case showAttention(AttentionContent)
}

/// apply 结果。
public struct ApplyResult: Sendable {
    public let accepted: Bool
    public let effects: [ReducerEffect]

    public static let rejected = ApplyResult(accepted: false, effects: [])
    public static func accepted(_ effects: [ReducerEffect]) -> ApplyResult {
        ApplyResult(accepted: true, effects: effects)
    }
}

/// 状态中文标签（对照 src/shared/ui-model.ts:5-10）。
public func stateLabel(_ state: SessionState) -> String {
    switch state {
    case .working: return "执行中"
    case .waiting: return "等待确认"
    case .done: return "已完成"
    case .unknown: return "暂无活跃会话"
    }
}

/// 时长格式化（对照 reducer.ts:79-85）：秒 <3600 → "M:SS"，否则 "H:MM:SS"。
/// 下限 0 防时钟回拨/NTP 校时导致负时长显示成 "-0:xx"（Math.max(0, …)）。
public func formatDuration(milliseconds: Double) -> String {
    let totalSeconds = max(0, Int((milliseconds / 1000).rounded(.down)))
    let seconds = totalSeconds % 60
    let minutes = (totalSeconds / 60) % 60
    let hours = totalSeconds / 3600
    if totalSeconds < 3600 {
        return "\(minutes):\(String(format: "%02d", seconds))"
    }
    return "\(hours):\(String(format: "%02d", minutes)):\(String(format: "%02d", seconds))"
}
