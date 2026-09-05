import Foundation

/// Hook 集成纯逻辑（对照 src/main/hook-integration.ts；文件读写事务在 App 层 Manager）。
/// 数据域为 JSONSerialization 的 [String: Any]；键缺失与显式 null 的区分对照 TS 的 undefined 语义。

public struct HookRuleSpec: Sendable, Equatable {
    public enum HookEvent: String, Sendable {
        case userPromptSubmit = "UserPromptSubmit"
        case permissionRequest = "PermissionRequest"
        case postToolUse = "PostToolUse"
        case postToolUseFailure = "PostToolUseFailure"
        case stop = "Stop"
    }

    public enum HookToken: String, Sendable {
        case userPromptSubmit = "user_prompt_submit"
        case permissionBash = "permission_bash"
        case permissionRequest = "permission_request"
        case todoUpdate = "todo_update"
        case toolFailure = "tool_failure"
        case stop = "stop"
    }

    public let event: HookEvent
    public let matcher: String?
    public let token: HookToken

    public init(event: HookEvent, matcher: String? = nil, token: HookToken) {
        self.event = event
        self.matcher = matcher
        self.token = token
    }
}

/// 6 条规则（hook-integration.ts:9-16）。
public let hookRuleSpecs: [HookRuleSpec] = [
    HookRuleSpec(event: .userPromptSubmit, token: .userPromptSubmit),
    HookRuleSpec(event: .permissionRequest, matcher: "^Bash$", token: .permissionBash),
    HookRuleSpec(event: .permissionRequest, matcher: "^(?!Bash$).+", token: .permissionRequest),
    HookRuleSpec(event: .postToolUse, matcher: "TodoWrite", token: .todoUpdate),
    HookRuleSpec(event: .postToolUseFailure, token: .toolFailure),
    HookRuleSpec(event: .stop, token: .stop),
]

/// 集成状态记录（hook-integration.ts:38-45）。
public struct HookIntegrationState: Sendable, Equatable {
    public let version: Int
    public let configPath: String
    public let executablePath: String
    public let databasePath: String
    public let backupPath: String
    public let installedAt: String

    public init(version: Int, configPath: String, executablePath: String, databasePath: String, backupPath: String, installedAt: String) {
        self.version = version
        self.configPath = configPath
        self.executablePath = executablePath
        self.databasePath = databasePath
        self.backupPath = backupPath
        self.installedAt = installedAt
    }
}

/// 集成检查状态（shared/hook-setup.ts）。
public enum HookSetupStatus: String, Sendable {
    case configured
    case disabled
    case invalid
    case missing
    case ready
}

/// 集成检查快照（shared/hook-setup.ts）。
public struct HookSetupSnapshot: Sendable, Equatable {
    public let configPath: String
    public let databasePath: String
    public let status: HookSetupStatus
    public let message: String
    public let isConfigured: Bool
    public let requiresEnableConfirmation: Bool
    public let ruleCount: Int

    public init(
        configPath: String,
        databasePath: String,
        status: HookSetupStatus,
        message: String,
        isConfigured: Bool,
        requiresEnableConfirmation: Bool,
        ruleCount: Int
    ) {
        self.configPath = configPath
        self.databasePath = databasePath
        self.status = status
        self.message = message
        self.isConfigured = isConfigured
        self.requiresEnableConfirmation = requiresEnableConfirmation
        self.ruleCount = ruleCount
    }
}

public struct HookIntegration {
    public static let hookHelperFileName = "zcodestatushook"
    public static let ruleCount = hookRuleSpecs.count

    public static func defaultZcodeConfigPath(homeDirectory: String) -> String {
        homeDirectory + "/.zcode/cli/config.json"
    }

    public static func providerConfigPath(homeDirectory: String) -> String {
        homeDirectory + "/.zcode/v2/config.json"
    }

    /// db 与 config 同目录下的 db/db.sqlite（hook-integration.ts:68-70）。
    public static func sessionDatabasePath(configPath: String) -> String {
        (configPath as NSString).deletingLastPathComponent + "/db/db.sqlite"
    }

    /// provider-only 配置识别（hook-integration.ts:55-66）：有 provider 对象且没有 hooks。
    public static func isProviderOnlyConfig(_ source: [String: Any]) -> Bool {
        guard source["provider"] as? [String: Any] != nil else { return false }
        return source["hooks"] == nil
    }

    /// 受管规则对象（hook-integration.ts:72-80）。
    public static func managedHookRule(spec: HookRuleSpec, executablePath: String, databasePath: String) -> [String: Any] {
        let hook: [String: Any] = [
            "type": "process",
            "command": executablePath,
            "args": [spec.token.rawValue, "${CLAUDE_SESSION_ID}", "${ZCODE_PROJECT_DIR}", databasePath] as [Any],
            "timeoutMs": 5000,
        ]
        if let matcher = spec.matcher {
            return ["matcher": matcher, "hooks": [hook]]
        }
        return ["hooks": [hook]]
    }

    /// 路径归一化比较键（manager:30）：折叠分隔符、去尾、小写；保留绝对路径前导斜杠。
    public static func normalizePath(_ value: String) -> String {
        let trimmed = value.replacingOccurrences(of: "\\", with: "/")
        let isAbsolute = trimmed.hasPrefix("/")
        let segments = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        let joined = segments.joined(separator: "/")
        return (isAbsolute ? "/" + joined : joined).lowercased()
    }

    static func recordValue(_ value: Any?) -> [String: Any]? {
        guard let value, value is [String: Any] else { return nil }
        return value as? [String: Any]
    }

    public struct ValidatedHookConfig {
        public let config: [String: Any]
        public let hooks: [String: Any]?
        public let events: [String: Any]?
    }

    /// 结构校验（hook-integration.ts:96-115），中文错误文案照搬。
    public static func validateHookConfig(_ source: [String: Any]) throws -> ValidatedHookConfig {
        let hooks = recordValue(source["hooks"])
        if source["hooks"] != nil && hooks == nil {
            throw HookIntegrationError.validation("ZCode 配置中的 hooks 必须是对象。")
        }
        var events: [String: Any]?
        if let hooks {
            events = recordValue(hooks["events"])
            if hooks["events"] != nil && events == nil {
                throw HookIntegrationError.validation("ZCode 配置中的 hooks.events 必须是对象。")
            }
            for (event, rules) in events ?? [:] {
                guard rules is [Any] else {
                    throw HookIntegrationError.validation("ZCode 配置中的 hooks.events.\(event) 必须是数组。")
                }
            }
        }
        return ValidatedHookConfig(config: source, hooks: hooks, events: events)
    }

    /// 受管规则判定（hook-integration.ts:117-149）。
    /// matcher 语义：spec 无 matcher 时规则不得含 matcher 键（JSON 无 undefined，存在即非 undefined）。
    public static func isManagedHookRule(
        _ candidate: Any?,
        spec: HookRuleSpec,
        executablePath: String,
        databasePath: String
    ) -> Bool {
        guard let rule = recordValue(candidate) else { return false }
        if let matcher = spec.matcher {
            guard rule["matcher"] as? String == matcher else { return false }
        } else {
            if rule.keys.contains("matcher") { return false }
        }
        guard let hooks = rule["hooks"] as? [Any], hooks.count == 1 else { return false }
        guard let hook = recordValue(hooks[0]) else { return false }
        guard hook["type"] as? String == "process",
              normalizePath(hook["command"] as? String ?? "") == normalizePath(executablePath),
              (hook["timeoutMs"] as? Int) == 5000,
              let args = hook["args"] as? [Any],
              args.count == 4
        else { return false }
        return args[0] as? String == spec.token.rawValue
            && args[1] as? String == "${CLAUDE_SESSION_ID}"
            && args[2] as? String == "${ZCODE_PROJECT_DIR}"
            && normalizePath(args[3] as? String ?? "") == normalizePath(databasePath)
    }

    /// 合并受管规则（hook-integration.ts:151-185）。
    public static func mergeHookConfig(
        source: [String: Any],
        executablePath: String,
        databasePath: String,
        enableDisabledHooks: Bool = false
    ) throws -> (config: [String: Any], enabledWasFalse: Bool) {
        let validated = try validateHookConfig(source)
        var hooks = validated.hooks ?? [:]
        let enabledWasFalse = (hooks["enabled"] as? Bool) == false
        if enabledWasFalse && !enableDisabledHooks {
            throw HookIntegrationError.validation("ZCode Hooks 当前已被明确关闭；请先确认是否启用。")
        }
        var nextEvents = validated.events ?? [:]
        for spec in hookRuleSpecs {
            let current = (nextEvents[spec.event.rawValue] as? [Any]) ?? []
            nextEvents[spec.event.rawValue] = current.filter {
                !isManagedHookRule($0, spec: spec, executablePath: executablePath, databasePath: databasePath)
            } + [managedHookRule(spec: spec, executablePath: executablePath, databasePath: databasePath)]
        }
        // enabled：缺失或 false（已确认启用）→ true；其他原值保留。
        if hooks["enabled"] == nil || (hooks["enabled"] as? Bool) == false {
            hooks["enabled"] = true
        }
        hooks["events"] = nextEvents
        var nextConfig = validated.config
        nextConfig["hooks"] = hooks
        return (nextConfig, enabledWasFalse)
    }

    /// 移除受管规则（hook-integration.ts:187-206）；无 hooks/events 时原样返回。
    public static func removeManagedHookRules(
        source: [String: Any],
        executablePath: String,
        databasePath: String
    ) throws -> [String: Any] {
        let validated = try validateHookConfig(source)
        guard var hooks = validated.hooks, var events = validated.events else {
            return validated.config
        }
        for spec in hookRuleSpecs {
            let current = (events[spec.event.rawValue] as? [Any]) ?? []
            events[spec.event.rawValue] = current.filter {
                !isManagedHookRule($0, spec: spec, executablePath: executablePath, databasePath: databasePath)
            }
        }
        hooks["events"] = events
        var nextConfig = validated.config
        nextConfig["hooks"] = hooks
        return nextConfig
    }
}

public enum HookIntegrationError: Error, LocalizedError {
    case validation(String)

    public var errorDescription: String? {
        switch self {
        case .validation(let message):
            return message
        }
    }
}
