import Foundation

/// 入站事件校验（对照 src/main/event-server.ts:17-87 sanitizeHookEvent）。
/// JSON 解析后的对象先经此校验，非法整条拒绝；语义归一化（trim/默认值）在 Reducer 中进行。
public enum EventSanitizer {
    public static let supportedEventNames: Set<String> = [
        "user_prompt_submit",
        "permission_bash",
        "permission_request",
        "todo_update",
        "tool_failure",
        "stop",
    ]

    static let maxEventStringLength = 512
    static let maxEventNameLength = 64
    static let maxTodos = 64
    static let maxTodoStatusLength = 64

    /// 校验并构造 HookEvent；任何字段违规返回 nil。
    public static func sanitize(_ json: [String: Any]) -> HookEvent? {
        guard let eventName = optionalLowercasedEvent(json["event"]) else { return nil }
        guard let sessionId = optionalString(json["session_id"]) else { return nil }
        guard let project = optionalString(json["project"]) else { return nil }
        guard let projectDir = optionalString(json["project_dir"]) else { return nil }
        guard let workspaceDir = optionalString(json["workspace_dir"]) else { return nil }
        guard let workspaceSource = optionalString(json["workspace_source"]) else { return nil }
        guard let promptPreview = optionalString(json["prompt_preview"]) else { return nil }
        guard let lastTool = optionalString(json["last_tool"]) else { return nil }
        guard let errorPreview = optionalString(json["error_preview"]) else { return nil }
        guard let currentTask = optionalString(json["current_task"]) else { return nil }
        guard let turnId = optionalString(json["turn_id"]) else { return nil }
        guard let todos = optionalTodos(json["todos"]) else { return nil }
        guard let ts = optionalTimestamp(json["ts"]) else { return nil }
        return HookEvent(
            event: eventName,
            sessionId: sessionId,
            project: project,
            projectDir: projectDir,
            workspaceDir: workspaceDir,
            workspaceSource: workspaceSource,
            promptPreview: promptPreview,
            lastTool: lastTool,
            errorPreview: errorPreview,
            todos: todos,
            currentTask: currentTask,
            turnId: turnId,
            ts: ts
        )
    }

    /// event 字段：字符串、≤64、trim+小写后在白名单内。
    private static func optionalLowercasedEvent(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        guard raw.count <= maxEventNameLength else { return nil }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard supportedEventNames.contains(name) else { return nil }
        return name
    }

    /// 可选字符串：出现则必须是 ≤512 的字符串。
    private static func optionalString(_ value: Any?) -> String?? {
        guard let value else { return .some(nil) }
        guard let string = value as? String, string.count <= maxEventStringLength else { return nil }
        return .some(string)
    }

    /// todos：可选；必须是数组且 ≤64 项；每项必须是对象，content ≤512、status ≤64。
    private static func optionalTodos(_ value: Any?) -> [TodoItem]?? {
        guard let value else { return .some(nil) }
        guard let array = value as? [Any] else { return nil }
        guard array.count <= maxTodos else { return nil }
        var items: [TodoItem] = []
        items.reserveCapacity(array.count)
        for element in array {
            guard let object = element as? [String: Any] else { return nil }
            let content: String
            if let raw = object["content"] {
                guard let string = raw as? String, string.count <= maxEventStringLength else { return nil }
                content = string
            } else {
                content = ""
            }
            let status: String
            if let raw = object["status"] {
                guard let string = raw as? String, string.count <= maxTodoStatusLength else { return nil }
                status = string
            } else {
                status = ""
            }
            items.append(TodoItem(content: content, status: status))
        }
        return .some(items)
    }

    /// ts：可选；存在则必须是有限数值（布尔不算数值，JSON 里 true/false 会桥接为 NSNumber，需排除）。
    private static func optionalTimestamp(_ value: Any?) -> Double?? {
        guard let value else { return .some(nil) }
        guard let number = value as? NSNumber else { return nil }
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite else { return nil }
        return .some(double)
    }
}
