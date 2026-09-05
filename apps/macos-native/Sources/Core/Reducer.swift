import Foundation

/// 会话状态机（对照 src/shared/reducer.ts，逐条移植）。
/// 线程模型：与 TS 版一致为单线程串行消费（EventServer 队列逐条 drain），
/// 本类不做内部加锁；UI 读取快照也必须发生在消费线程或经序列化调度。
public final class SessionReducer {
    /// 任何会话 30 分钟无更新即删除（reducer.ts:10）。
    public static let anySessionTtlMs: Double = 30 * 60 * 1000
    /// 最大会话数（reducer.ts:11）。
    public static let maxSessions = 128
    /// ts 秒/毫秒启发式阈值：<10e9 视为秒（reducer.ts:58）。
    private static let secondsTimestampThreshold = 10_000_000_000.0

    public private(set) var sessions: [String: SessionRecord] = [:]

    public init() {}

    // MARK: - 归一化辅助（reducer.ts:50-77）

    private static func stringValue(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// ts：<10e9 按秒转毫秒；非法或负数 → nil（reducer.ts:54-59）。
    static func normalizedTimestamp(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        if value < secondsTimestampThreshold {
            return (value * 1000).rounded(.towardZero)
        }
        return value.rounded(.towardZero)
    }

    /// 会话键：session_id || project_dir || project || "default"（reducer.ts:61-64）。
    static func sessionKey(_ event: HookEvent) -> String {
        let id = stringValue(event.sessionId)
        if !id.isEmpty { return id }
        let dir = stringValue(event.projectDir)
        if !dir.isEmpty { return dir }
        let project = stringValue(event.project)
        if !project.isEmpty { return project }
        return "default"
    }

    /// todos 归一：非对象项跳过；status 空默认 "pending"（reducer.ts:66-77）。
    static func normalizedTodos(_ todos: [TodoItem]?) -> [TodoItem] {
        guard let todos else { return [] }
        return todos.map { item in
            TodoItem(content: stringValue(item.content), status: stringValue(item.status).isEmpty ? "pending" : stringValue(item.status))
        }
    }

    // MARK: - apply 主流程（reducer.ts:97-217）

    @discardableResult
    public func apply(_ event: HookEvent, now: TimeInterval) -> ApplyResult {
        let name = event.event.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // 前置 1：token 不在白名单（reducer.ts:100-102；sanitizer 已保证，此处防御）。
        guard EventSanitizer.supportedEventNames.contains(name) else { return .rejected }

        let timestamp = Self.normalizedTimestamp(event.ts)
        let turnId = Self.stringValue(event.turnId)
        let key = Self.sessionKey(event)
        let existing = sessions[key]

        // 前置 2：同回合重复 prompt 去重（reducer.ts:107-109）。
        if name == "user_prompt_submit" {
            if let existing, !turnId.isEmpty, existing.activeTurnId == turnId, !existing.roundClosed {
                return .rejected
            }
            // 前置 3：prompt 时间戳必须严格递增（reducer.ts:110-112）。
            if let timestamp, let last = existing?.lastEventTimestamp, timestamp <= last {
                return .rejected
            }
        }

        // 前置 4：Stop 的 turn_id 校验（reducer.ts:113-124）。
        if name == "stop" {
            guard let existing else { return .rejected }
            guard !existing.roundClosed else { return .rejected }
            guard !existing.activeTurnId.isEmpty else { return .rejected }
            guard !turnId.isEmpty else { return .rejected }
            guard turnId == existing.activeTurnId else { return .rejected }
        }

        // 前置 5：会话不存在则创建（容量满且无可驱逐 → 拒绝，reducer.ts:125-128）。
        guard let session = existing ?? createSession(key: key, now: now) else { return .rejected }

        // 前置 6：全局时间戳单调，严格小于才拒（reducer.ts:129-131）。
        if let timestamp, let last = session.lastEventTimestamp, timestamp < last {
            return .rejected
        }

        // 回合身份规则（reducer.ts:133-151）。
        if name == "user_prompt_submit" {
            session.activeTurnId = turnId
            session.roundIdentityLocked = true
            session.roundClosed = false
        } else {
            if !session.activeTurnId.isEmpty, !turnId.isEmpty, turnId != session.activeTurnId {
                return .rejected
            }
            if session.activeTurnId.isEmpty, !turnId.isEmpty, !session.roundIdentityLocked {
                session.activeTurnId = turnId
            }
            if session.roundClosed {
                return .rejected
            }
        }

        if let timestamp {
            session.lastEventTimestamp = timestamp
        }
        session.updatedAt = now
        updateWorkspace(of: session, event: event)

        let lastTool = Self.stringValue(event.lastTool)
        if !lastTool.isEmpty {
            session.lastTool = lastTool
        }
        let errorPreview = Self.stringValue(event.errorPreview)
        if !errorPreview.isEmpty {
            session.lastError = errorPreview
        }

        let previousState = session.state
        var effects: [ReducerEffect] = []

        switch name {
        case "user_prompt_submit":
            session.state = .working
            effects.append(.cancelAttention(sessionId: session.key))
            session.roundStartedAt = now
            session.completedDurationMs = nil
            session.promptPreview = Self.stringValue(event.promptPreview)
            session.todos = []
            session.currentTask = ""
            session.errorCount = 0
            session.lastError = ""
            session.lastTool = ""
        case "todo_update":
            if session.state == .done || session.state == .unknown || session.state == .waiting {
                session.state = .working
            }
            session.todos = Self.normalizedTodos(event.todos)
            session.currentTask = Self.stringValue(event.currentTask)
        case "permission_bash":
            session.state = .working
        case "permission_request":
            // TS 用本次事件的 lastTool（事件缺字段时为空串），不用 session.lastTool 旧值。
            session.state = lastTool.lowercased() == "bash" ? .working : .waiting
        case "tool_failure":
            session.errorCount += 1
        case "stop":
            session.state = .done
            session.completedDurationMs = max(0, now - session.roundStartedAt)
            session.roundClosed = true
        default:
            break
        }

        if session.state != previousState {
            session.stateSince = now
        }

        // 副作用判定（reducer.ts:203-215）。
        if session.state == .working, previousState == .waiting {
            effects.append(.cancelAttention(sessionId: session.key))
        }
        let stateChanged = session.state != previousState
        if (stateChanged && (session.state == .waiting || session.state == .done))
            || (name == "permission_request" && session.state == .waiting && lastTool.lowercased() != "bash") {
            effects.append(.showAttention(attentionContent(for: session)))
        }

        return .accepted(effects)
    }

    // MARK: - 容量与淘汰（reducer.ts:240-283）

    private func evictInactiveSessions(now: TimeInterval) {
        sessions = sessions.filter { _, session in
            now - session.updatedAt <= Self.anySessionTtlMs
        }
    }

    private func createSession(key: String, now: TimeInterval) -> SessionRecord? {
        evictInactiveSessions(now: now)
        if sessions.count >= Self.maxSessions {
            guard let victimKey = sessions
                .filter({ $0.value.state == .done || $0.value.state == .unknown })
                .min(by: { $0.value.updatedAt < $1.value.updatedAt })?
                .key
            else { return nil }
            sessions.removeValue(forKey: victimKey)
        }
        guard sessions.count < Self.maxSessions else { return nil }
        let record = SessionRecord(key: key, createdAt: now, updatedAt: now)
        sessions[key] = record
        return record
    }

    // MARK: - 可见性与展示（reducer.ts:219-238, 332-356）

    /// 过期清理（顺带删除）+ 按 updatedAt 降序。
    @discardableResult
    public func visibleSessions(now: TimeInterval, doneTtlMinutes: Int) -> [SessionRecord] {
        let doneTtlMs = Double(doneTtlMinutes) * 60 * 1000
        sessions = sessions.filter { _, session in
            let age = now - session.updatedAt
            if age > Self.anySessionTtlMs { return false }
            if session.state == .done, age > doneTtlMs { return false }
            return true
        }
        return sessions.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func displaySessions(
        now: TimeInterval,
        doneTtlMinutes: Int,
        showTodoProgress: Bool,
        showDuration: Bool
    ) -> [DisplaySession] {
        visibleSessions(now: now, doneTtlMinutes: doneTtlMinutes).map { session in
            toDisplaySession(session, now: now, showTodoProgress: showTodoProgress, showDuration: showDuration)
        }
    }

    private func toDisplaySession(_ session: SessionRecord, now: TimeInterval, showTodoProgress: Bool, showDuration: Bool) -> DisplaySession {
        let task = !session.currentTask.isEmpty
            ? session.currentTask
            : (!session.promptPreview.isEmpty ? session.promptPreview : stateLabel(session.state))
        let todoProgress: String
        if showTodoProgress, !session.todos.isEmpty {
            todoProgress = "\(session.todos.filter { $0.status == "completed" }.count)/\(session.todos.count)"
        } else {
            todoProgress = ""
        }
        let duration: String
        if showDuration {
            switch session.state {
            case .done:
                duration = session.completedDurationMs.map { formatDuration(milliseconds: $0) } ?? ""
            case .working, .waiting:
                duration = formatDuration(milliseconds: now - session.stateSince)
            case .unknown:
                duration = ""
            }
        } else {
            duration = ""
        }
        return DisplaySession(
            id: session.key,
            state: session.state,
            workspace: !session.label.isEmpty ? session.label : (!session.workspaceName.isEmpty ? session.workspaceName : "ZCode"),
            task: task,
            todoProgress: todoProgress,
            duration: duration
        )
    }

    // MARK: - 工作区命名与去重（reducer.ts:292-315）

    private func updateWorkspace(of session: SessionRecord, event: HookEvent) {
        let source = Self.stringValue(event.workspaceSource) == "session_root" ? "session_root" : "event_dir"
        let canUpdate = session.workspaceName.isEmpty
            || (source == "session_root" && session.workspaceSource != "session_root")
        let project = Self.stringValue(event.project)
        if !canUpdate || project.isEmpty || (project == "ZCode" && Self.stringValue(event.projectDir).isEmpty) {
            return
        }
        session.workspaceName = project
        session.workspaceSource = source
        if session.label.isEmpty || source == "session_root" {
            var labels = Set(sessions.values.filter { $0.key != session.key }.map(\.label))
            var label = project
            var suffix = 2
            while labels.contains(label) {
                label = "\(project)·\(suffix)"
                suffix += 1
            }
            session.label = label
            labels.insert(label)
        }
    }

    // MARK: - 提醒内容（reducer.ts:317-330）

    private func attentionContent(for session: SessionRecord) -> AttentionContent {
        let completed = session.todos.filter { $0.status == "completed" }.count
        let progress = session.todos.isEmpty ? "" : "\(completed)/\(session.todos.count)"
        let summary = !progress.isEmpty
            ? progress
            : (session.state == .done ? session.completedDurationMs.map { formatDuration(milliseconds: $0) } ?? "" : "")
        return AttentionContent(
            sessionId: session.key,
            kind: session.state == .waiting ? .waiting : .done,
            title: session.state == .waiting ? "请完成审批" : "本轮任务完成",
            workspace: !session.label.isEmpty ? session.label : (!session.workspaceName.isEmpty ? session.workspaceName : "ZCode"),
            summary: summary
        )
    }
}

/// 会话记录（对照 reducer.ts:22-43）。引用类型，apply 中原地更新。
public final class SessionRecord {
    public let key: String
    public let createdAt: TimeInterval
    public var updatedAt: TimeInterval
    public var state: SessionState = .unknown
    public var stateSince: TimeInterval
    public var workspaceName: String = ""
    public var workspaceSource: String = ""
    public var label: String = ""
    public var promptPreview: String = ""
    public var currentTask: String = ""
    public var todos: [TodoItem] = []
    public var roundStartedAt: TimeInterval
    public var lastEventTimestamp: Double?
    public var completedDurationMs: Double?
    public var activeTurnId: String = ""
    public var roundIdentityLocked = false
    public var roundClosed = false
    public var errorCount = 0
    public var lastError: String = ""
    public var lastTool: String = ""

    init(key: String, createdAt: TimeInterval, updatedAt: TimeInterval) {
        self.key = key
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.stateSince = createdAt
        self.roundStartedAt = createdAt
    }
}
