import Foundation
import SQLite3

/// hook helper 纯逻辑（对照 apps/hook-helper/ZCodeStatusHook.cs，供可执行目标与测试共用）。
/// 截断上限（cs:18-20）：prompt/error=60、todo=80、tool_name=40、turn_id=128。
public enum HookPayload {
    public static let promptPreviewLength = 60
    public static let taskPreviewLength = 80
    public static let toolNameLength = 40
    public static let turnIdLength = 128
    public static let errorPreviewLength = 60
    /// SQLite parent 链最大层数（cs:20）。
    public static let sessionDbMaxDepth = 16
    /// stdin 上限 64KiB（cs:21）。
    public static let maxInputBytes = 64 * 1024

    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // MARK: - 字符串处理

    /// Clip（cs:477-481）：空白折叠为单空格 + trim；超长取前 length-3 + "..."。
    public static func clip(_ value: String, _ length: Int) -> String {
        let collapsed = value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > length else { return collapsed }
        return String(collapsed.prefix(max(0, length - 3))) + "..."
    }

    /// 剥离未展开的 `${...}` 模板变量（cs:73-80 Expand；C# 正则要求闭合，未闭合时保留原文）。
    public static func stripTemplateVars(_ argument: String) -> String {
        var output = ""
        var scanner = Substring(argument)
        while let start = scanner.range(of: "${") {
            let rest = scanner[start.upperBound...]
            guard let end = rest.range(of: "}") else {
                // 未闭合：从 "${" 起保留原文。
                break
            }
            output += scanner[..<start.lowerBound]
            scanner = rest[end.upperBound...]
        }
        output += scanner
        return output
    }

    /// FirstString（cs:455-470）：按 key 顺序取第一个"存在且字符串化后 trim 非空"的值。
    public static func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let raw = object[key] else { continue }
            let string = scalarString(raw)
            if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return string
            }
        }
        return nil
    }

    /// Convert.ToString 等价：仅标量可字符串化（string/number/bool），容器返回 nil。
    private static func scalarString(_ value: Any) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    /// 工作区显示名（cs:430-446）：去尾部分隔符（/ 与 \）取最后一段；空 → "ZCode"。
    public static func workspaceName(fromDirectory directory: String) -> String {
        let normalized = directory
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let name = normalized.split(separator: "/").last.map(String.init) ?? ""
        return name.isEmpty ? "ZCode" : name
    }

    // MARK: - 输入 JSON 提取

    public static func extractPrompt(from data: [String: Any]) -> String {
        clip(firstString(in: data, keys: ["prompt", "user_prompt", "message"]) ?? "", promptPreviewLength)
    }

    public static func extractToolName(from data: [String: Any]) -> String {
        clip(firstString(in: data, keys: ["tool_name", "toolName"]) ?? "", toolNameLength)
    }

    /// ExtractError（cs:369-386）：tool_response 为对象 → error/message/stderr；
    /// tool_response 为字符串 → 直接用；否则取顶层 error/message。
    public static func extractError(from data: [String: Any]) -> String {
        let response = data["tool_response"]
        if let object = response as? [String: Any],
           let message = firstString(in: object, keys: ["error", "message", "stderr"]),
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return clip(message, errorPreviewLength)
        }
        if let string = response as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return clip(string, errorPreviewLength)
        }
        if let message = firstString(in: data, keys: ["error", "message"]) {
            return clip(message, errorPreviewLength)
        }
        return ""
    }

    /// ExtractTurnId（cs:345-367）：顶层 → tool_input → message 三层。
    public static func extractTurnId(from data: [String: Any]) -> String {
        if let top = firstString(in: data, keys: ["turn_id", "turnId"]),
           !top.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return clip(top, turnIdLength)
        }
        for holderKey in ["tool_input", "message"] {
            if let holder = data[holderKey] as? [String: Any],
               let value = firstString(in: holder, keys: ["turn_id", "turnId"]),
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return clip(value, turnIdLength)
            }
        }
        return ""
    }

    /// ExtractTodos（cs:294-333）：holder 顺序 tool_input → 顶层 → message；
    /// 每层找 todos 键（数组且非字符串），元素须为对象，content 截 80、status 默认 "pending"。
    public static func extractTodos(from data: [String: Any]) -> [[String: String]] {
        var holders: [[String: Any]] = []
        if let toolInput = data["tool_input"] as? [String: Any] {
            holders.append(toolInput)
        }
        holders.append(data)
        if let message = data["message"] as? [String: Any] {
            holders.append(message)
        }
        for holder in holders {
            guard let raw = holder["todos"] else { continue }
            guard let array = raw as? [Any] else { continue }
            var todos: [[String: String]] = []
            todos.reserveCapacity(array.count)
            for element in array {
                guard let object = element as? [String: Any] else { continue }
                let content = clip(firstString(in: object, keys: ["content", "activeForm", "subject"]) ?? "", taskPreviewLength)
                let status = firstString(in: object, keys: ["status"]) ?? "pending"
                todos.append(["content": content, "status": status])
            }
            return todos
        }
        return []
    }

    /// currentTask（cs:171-184）：第一个 status == "in_progress"（精确比较）的 todo content。
    public static func extractCurrentTask(from todos: [[String: String]]) -> String {
        for todo in todos where todo["status"] == "in_progress" {
            return todo["content"] ?? ""
        }
        return ""
    }

    // MARK: - payload 构造（cs:160-202）

    /// displayDirectory = workspaceDir 非空 ? workspaceDir : projectDir（cs:168）。
    public static func buildPayload(
        token: String,
        sessionId: String,
        projectDirectory: String,
        workspaceDirectory: String?,
        data: [String: Any]
    ) -> [String: Any] {
        let displayDirectory = !(workspaceDirectory ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? workspaceDirectory!
            : projectDirectory
        let todos = extractTodos(from: data)
        var payload: [String: Any] = [
            "event": token.lowercased(),
            "session_id": sessionId,
            "project": workspaceName(fromDirectory: displayDirectory),
            "project_dir": projectDirectory,
            "workspace_source": !(workspaceDirectory ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "session_root" : "event_dir",
            "prompt_preview": extractPrompt(from: data),
            "last_tool": extractToolName(from: data),
            "error_preview": extractError(from: data),
            "todos": todos,
            "current_task": extractCurrentTask(from: todos),
            "turn_id": extractTurnId(from: data),
            "ts": Date().timeIntervalSince1970,
        ]
        if let workspaceDirectory, !workspaceDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["workspace_dir"] = workspaceDirectory
        }
        return payload
    }

    // MARK: - SQLite 只读溯源（cs:204-292）

    /// 沿 parent 链上溯 ≤16 层取根工作区；任何失败返回 nil（对应 C# 空串）。
    /// 只读打开，绝不写库。
    public static func rootWorkspaceDirectory(sessionId: String, databasePath: String) -> String? {
        guard !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard !databasePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard FileManager.default.fileExists(atPath: databasePath) else { return nil }

        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            if database != nil { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT directory, parent_id FROM session WHERE id = ?", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var currentId = sessionId
        var seen = Set<String>()
        var rootDirectory: String?
        var depth = 0
        while depth < sessionDbMaxDepth {
            depth += 1
            if currentId.isEmpty || seen.contains(currentId) { return nil }
            seen.insert(currentId)
            guard sqlite3_reset(statement) == SQLITE_OK,
                  sqlite3_clear_bindings(statement) == SQLITE_OK,
                  sqlite3_bind_text(statement, 1, currentId, -1, transientDestructor) == SQLITE_OK else {
                return nil
            }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            let directory = columnText(statement, 0)
            if !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rootDirectory = directory.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let parentId = columnText(statement, 1)
            if parentId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return rootDirectory
            }
            currentId = parentId
        }
        return nil
    }

    private static func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: text)
    }

    // MARK: - stdin 解码（cs:82-158）

    /// 严格 UTF-8 解码、容忍 BOM；数据非法返回 nil（整个事件放弃发送）。
    public static func decodeInput(_ bytes: Data) -> [String: Any]? {
        var data = bytes
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            data = data.dropFirst(3)
        }
        guard data.allSatisfy({ _ in true }), let text = String(data: data, encoding: .utf8) else { return nil }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        return object
    }
}
