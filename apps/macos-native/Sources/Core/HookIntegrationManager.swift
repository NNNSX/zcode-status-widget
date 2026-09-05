import Foundation

/// Hook 集成事务管理器（对照 src/main/hook-integration-manager.ts，纯 Foundation 便于测试）。
/// 事务保证：进程内串行 → 配置文件锁（O_EXCL，80ms 重试 / 2s 超时）→ 备份 → 原子写
/// → 写后校验 → 期间未变断言；任一步失败按写入内容回滚（外部已改则不覆盖并报告）。
/// 非故意 final：测试以子类覆写 writeState/removeStateIfUnchanged/writeConfigAtomically 注入故障。
public class HookIntegrationManager {
    public static let backupDirectoryName = ".zcode-status-light-backups"
    public static let stateFileName = "integration-state.json"
    static let lockRetryIntervalMs = 80
    static let lockTimeoutMs = 2_000

    /// 跨实例串行（对照 static pendingOperations）。
    private static let operationLock = NSLock()

    public struct Options {
        public var executablePath: String
        public var statePath: String
        public var defaultConfigPath: String
        public var homeDirectory: String

        public init(
            executablePath: String,
            statePath: String,
            defaultConfigPath: String,
            homeDirectory: String = NSHomeDirectory()
        ) {
            self.executablePath = executablePath
            self.statePath = statePath
            self.defaultConfigPath = defaultConfigPath
            self.homeDirectory = homeDirectory
        }
    }

    private let executablePath: String
    private let statePath: String
    private let defaultConfigPath: String
    private let homeDirectory: String

    public init(options: Options) {
        self.executablePath = options.executablePath
        self.statePath = options.statePath
        self.defaultConfigPath = options.defaultConfigPath
        self.homeDirectory = options.homeDirectory
    }

    /// 状态文件默认位置（对照 defaultIntegrationStatePath）。
    public static func defaultStatePath(appDataPath: String) -> String {
        appDataPath + "/ZCodeStatusLight/" + stateFileName
    }

    // MARK: - 检查（manager:101-148）

    public func suggestedConfigPath() -> String {
        guard let state = readState(),
              (state.configPath as NSString).lastPathComponent.lowercased() == "config.json",
              isManagedHelperPath(state.executablePath),
              isManagedHelperPath(executablePath)
        else { return defaultConfigPath }
        return state.configPath
    }

    public func inspect(_ requestedPath: String? = nil) -> HookSetupSnapshot {
        let configPath: String
        do {
            configPath = try resolveConfigPath(requestedPath ?? suggestedConfigPath())
        } catch {
            let fallback = requestedPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? defaultConfigPath
            return snapshot(configPath: fallback, status: .invalid, message: message(for: error), isConfigured: false, requiresEnableConfirmation: false)
        }
        let databasePath = HookIntegration.sessionDatabasePath(configPath: configPath)
        guard isRegularFile(configPath) else {
            return snapshot(
                configPath: configPath,
                status: .missing,
                message: "未找到默认 Hook 配置。新系统的 ~/.zcode/v2/config.json 仅用于 provider 配置，不能写入 Hook；请先在 ZCode 中生成实际 Hook 配置，或选择实际承载 hooks 的 config.json。",
                isConfigured: false,
                requiresEnableConfirmation: false
            )
        }
        do {
            let parsed = try parseConfig(readRaw(configPath) ?? Data(), configPath: configPath)
            if HookIntegration.isProviderOnlyConfig(parsed.config) {
                return snapshot(
                    configPath: configPath,
                    status: .invalid,
                    message: "所选文件是 ZCode provider 配置，不能写入 Hook。请返回并选择实际承载 hooks 的 config.json。",
                    isConfigured: false,
                    requiresEnableConfirmation: false
                )
            }
            let hooks = try HookIntegration.validateHookConfig(parsed.config).hooks
            if (hooks?["enabled"] as? Bool) == false {
                return snapshot(
                    configPath: configPath,
                    status: .disabled,
                    message: "ZCode Hooks 已被明确关闭。只有确认后才会启用并添加状态 Hook。",
                    isConfigured: false,
                    requiresEnableConfirmation: true
                )
            }
            if isFullyConfigured(parsed.config, databasePath: databasePath) {
                return snapshot(configPath: configPath, status: .configured, message: "已配置 6 条本机状态 Hook。", isConfigured: true, requiresEnableConfirmation: false)
            }
            return snapshot(configPath: configPath, status: .ready, message: "将添加 6 条仅发送到本机回环地址的状态 Hook。", isConfigured: false, requiresEnableConfirmation: false)
        } catch {
            return snapshot(configPath: configPath, status: .invalid, message: message(for: error), isConfigured: false, requiresEnableConfirmation: false)
        }
    }

    // MARK: - 配置事务（manager:158-221）

    public func configure(_ requestedPath: String? = nil, enableDisabledHooks: Bool = false) throws -> HookSetupSnapshot {
        try Self.operationLock.withLock {
            try configureUnlocked(requestedPath, enableDisabledHooks: enableDisabledHooks)
        }
    }

    private func configureUnlocked(_ requestedPath: String?, enableDisabledHooks: Bool) throws -> HookSetupSnapshot {
        let initial = inspect(requestedPath)
        if initial.status == .missing || initial.status == .invalid {
            throw HookIntegrationError.validation(initial.message)
        }
        return try withConfigLock(initial.configPath) {
            let before = inspect(initial.configPath)
            if before.status == .missing || before.status == .invalid {
                throw HookIntegrationError.validation(before.message)
            }
            if before.status == .disabled && !enableDisabledHooks {
                throw HookIntegrationError.validation("ZCode Hooks 当前已被明确关闭；请单独确认启用后再配置。")
            }
            guard isRegularFile(executablePath) else {
                throw HookIntegrationError.validation("本机 Hook 助手文件缺失，无法修改 ZCode 配置。")
            }

            let raw = try requireRaw(before.configPath)
            let stateRaw = readRaw(statePath)
            let parsed = try parseConfig(raw, configPath: before.configPath)
            let recordedState = readState()
            let merged = try mergeForCurrentExecutable(
                parsed.config,
                databasePath: before.databasePath,
                enableDisabledHooks: enableDisabledHooks,
                state: (recordedState.map { pathKey($0.configPath) } == pathKey(before.configPath)) ? recordedState : nil
            )
            let backupPath = try backup(before.configPath, raw: raw, operation: "before-setup")
            let nextState = HookIntegrationState(
                version: 1,
                configPath: before.configPath,
                executablePath: executablePath,
                databasePath: before.databasePath,
                backupPath: backupPath,
                installedAt: ISO8601DateFormatter().string(from: Date())
            )
            var writtenConfig: Data?
            var writtenState: Data?
            do {
                try assertUnchanged(before.configPath, expected: raw, label: "配置文件")
                writtenConfig = try writeConfigAtomically(before.configPath, config: merged.config, hasBom: parsed.hasBom)
                try assertUnchanged(before.configPath, expected: writtenConfig!, label: "配置文件")
                let verified = inspect(before.configPath)
                if !verified.isConfigured {
                    throw HookIntegrationError.validation("写入后未能验证全部状态 Hook。")
                }
                try assertUnchanged(before.configPath, expected: writtenConfig!, label: "配置文件")
                try assertOptionalUnchanged(statePath, expected: stateRaw, label: "集成状态记录")
                writtenState = try writeState(nextState)
                try assertUnchanged(statePath, expected: writtenState!, label: "集成状态记录")
                try assertUnchanged(before.configPath, expected: writtenConfig!, label: "配置文件")
                return verified
            } catch {
                let recovery = recoverTransaction(
                    configPath: before.configPath,
                    configRaw: raw,
                    writtenConfig: writtenConfig,
                    stateRaw: stateRaw,
                    writtenState: writtenState
                )
                throw transactionError(error, recovery: recovery)
            }
        }
    }

    // MARK: - 取消集成事务（manager:223-273）

    @discardableResult
    public func unconfigure() throws -> Bool {
        try Self.operationLock.withLock {
            try unconfigureUnlocked()
        }
    }

    private func unconfigureUnlocked() throws -> Bool {
        guard let initialState = readState(),
              pathKey(initialState.executablePath) == pathKey(executablePath),
              isRegularFile(initialState.configPath)
        else { return false }
        return try withConfigLock(initialState.configPath) {
            guard let state = readState(),
                  pathKey(state.executablePath) == pathKey(executablePath),
                  isRegularFile(state.configPath)
            else { return false }
            let raw = try requireRaw(state.configPath)
            guard let stateRaw = readRaw(statePath) else { return false }
            let parsed = try parseConfig(raw, configPath: state.configPath)
            let source = parsed.config
            let next = try HookIntegration.removeManagedHookRules(
                source: source,
                executablePath: state.executablePath,
                databasePath: state.databasePath
            )
            var writtenConfig: Data?
            do {
                if !sameJSON(next, source) {
                    _ = try backup(state.configPath, raw: raw, operation: "before-unconfigure")
                    try assertUnchanged(state.configPath, expected: raw, label: "配置文件")
                    writtenConfig = try writeConfigAtomically(state.configPath, config: next, hasBom: parsed.hasBom)
                    try assertUnchanged(state.configPath, expected: writtenConfig!, label: "配置文件")
                    if countManagedRules(raw: readRaw(state.configPath) ?? Data(), configPath: state.configPath, executablePath: state.executablePath, databasePath: state.databasePath) != 0 {
                        throw HookIntegrationError.validation("写入后仍检测到本程序管理的状态 Hook。")
                    }
                    try assertUnchanged(state.configPath, expected: writtenConfig!, label: "配置文件")
                }
                try removeStateIfUnchanged(stateRaw)
                return true
            } catch {
                let recovery = recoverTransaction(
                    configPath: state.configPath,
                    configRaw: raw,
                    writtenConfig: writtenConfig,
                    stateRaw: stateRaw,
                    writtenState: nil
                )
                throw transactionError(error, recovery: recovery)
            }
        }
    }

    // MARK: - 合并辅助（manager:275-326）

    private func mergeForCurrentExecutable(
        _ source: [String: Any],
        databasePath: String,
        enableDisabledHooks: Bool,
        state: HookIntegrationState?
    ) throws -> (config: [String: Any], enabledWasFalse: Bool) {
        var migrated = source
        if let state,
           isManagedHelperPath(state.executablePath),
           isManagedHelperPath(executablePath),
           pathKey(state.executablePath) != pathKey(executablePath) {
            migrated = try HookIntegration.removeManagedHookRules(
                source: source,
                executablePath: state.executablePath,
                databasePath: state.databasePath
            )
        }
        return try HookIntegration.mergeHookConfig(
            source: migrated,
            executablePath: executablePath,
            databasePath: databasePath,
            enableDisabledHooks: enableDisabledHooks
        )
    }

    private func isManagedHelperPath(_ candidate: String) -> Bool {
        (candidate as NSString).lastPathComponent.lowercased() == HookIntegration.hookHelperFileName
    }

    func isFullyConfigured(_ config: [String: Any], databasePath: String) -> Bool {
        hookRuleSpecs.allSatisfy { managedRuleOccurrences(config, spec: $0, databasePath: databasePath) == 1 }
    }

    private func managedRuleOccurrences(
        _ config: [String: Any],
        spec: HookRuleSpec,
        databasePath: String,
        executablePath: String? = nil
    ) -> Int {
        let events = (try? HookIntegration.validateHookConfig(config))?.events
        let rules = (events?[spec.event.rawValue] as? [Any]) ?? []
        return rules.filter {
            HookIntegration.isManagedHookRule($0, spec: spec, executablePath: executablePath ?? self.executablePath, databasePath: databasePath)
        }.count
    }

    func countManagedRules(
        raw: Data,
        configPath: String,
        executablePath: String? = nil,
        databasePath: String? = nil
    ) -> Int {
        let resolvedDatabase = databasePath ?? HookIntegration.sessionDatabasePath(configPath: configPath)
        guard let parsed = try? parseConfig(raw, configPath: configPath) else { return 0 }
        return hookRuleSpecs.reduce(0) { total, spec in
            total + managedRuleOccurrences(parsed.config, spec: spec, databasePath: resolvedDatabase, executablePath: executablePath)
        }
    }

    // MARK: - 文件锁（manager:345-366）

    private func withConfigLock<T>(_ configPath: String, _ operation: () throws -> T) throws -> T {
        let lockPath = (configPath as NSString).deletingLastPathComponent + "/.zcode-status-light.lock"
        let deadline = Date().addingTimeInterval(TimeInterval(Self.lockTimeoutMs) / 1000)
        var descriptor: Int32 = -1
        while descriptor < 0 {
            descriptor = open(lockPath, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if descriptor < 0 {
                if errno != EEXIST || Date() >= deadline {
                    throw HookIntegrationError.validation("ZCode 配置正在被其他状态灯操作修改；请稍后重试。")
                }
                Thread.sleep(forTimeInterval: TimeInterval(Self.lockRetryIntervalMs) / 1000)
            }
        }
        defer {
            close(descriptor)
            unlink(lockPath)
        }
        return try operation()
    }

    // MARK: - 字节级防护（manager:368-415）

    private func assertUnchanged(_ targetPath: String, expected: Data, label: String) throws {
        let current = try requireRaw(targetPath)
        if current != expected {
            throw HookIntegrationError.validation("\(label)在操作期间被其他程序修改，已停止写入。")
        }
    }

    private func assertOptionalUnchanged(_ targetPath: String, expected: Data?, label: String) throws {
        let current = readRaw(targetPath)
        if let expected {
            guard let current, current == expected else {
                throw HookIntegrationError.validation("\(label)在操作期间被其他程序修改，已停止写入。")
            }
        } else if current != nil {
            throw HookIntegrationError.validation("\(label)在操作期间被其他程序修改，已停止写入。")
        }
    }

    /// 回滚结果三态：restored=已还原或无需动；untouched=外部已改不覆盖；
    /// restoreFailed=回滚写入失败（之前无条件返回成功，失败被吞成谎报）。
    private enum RecoveryOutcome {
        case restored
        case untouched
        case restoreFailed
    }

    /// 仅当目标仍是自己写入的内容时回滚；外部已改则不覆盖（manager:394-415）。
    private func restoreRawIfUnchanged(_ targetPath: String, previous: Data?, written: Data) -> RecoveryOutcome {
        let current = readRaw(targetPath)
        if let previous, let current, current == previous { return .restored }
        if previous == nil && current == nil { return .restored }
        guard let current, current == written else { return .untouched }
        if let previous {
            return restoreRaw(targetPath, raw: previous) ? .restored : .restoreFailed
        }
        return unlink(targetPath) == 0 ? .restored : .restoreFailed
    }

    private func recoverTransaction(
        configPath: String,
        configRaw: Data,
        writtenConfig: Data?,
        stateRaw: Data?,
        writtenState: Data?
    ) -> [String] {
        var issues: [String] = []
        if let writtenState {
            switch restoreRawIfUnchanged(statePath, previous: stateRaw, written: writtenState) {
            case .restored:
                break
            case .untouched:
                issues.append("集成状态记录已被外部修改，未覆盖")
            case .restoreFailed:
                issues.append("集成状态记录回滚失败，请手动删除：\(statePath)")
            }
        }
        if let writtenConfig {
            switch restoreRawIfUnchanged(configPath, previous: configRaw, written: writtenConfig) {
            case .restored:
                break
            case .untouched:
                issues.append("配置文件已被外部修改，未覆盖")
            case .restoreFailed:
                issues.append("配置文件回滚失败，请从备份目录手动恢复：\((configPath as NSString).deletingLastPathComponent)/\(Self.backupDirectoryName)")
            }
        }
        return issues
    }

    private func transactionError(_ error: Error, recovery: [String]) -> Error {
        let message = self.message(for: error)
        return recovery.isEmpty
            ? HookIntegrationError.validation(message)
            : HookIntegrationError.validation("\(message) \(recovery.joined(separator: "；"))。")
    }

    /// 状态删除（manager:451-453）；子类可覆写以注入异常。
    func removeStateIfUnchanged(_ expected: Data) throws {
        try assertUnchanged(statePath, expected: expected, label: "集成状态记录")
        unlink(statePath)
    }

    // MARK: - 路径与状态（manager:451-551）

    private func resolveConfigPath(_ requestedPath: String?) throws -> String {
        let candidate = requestedPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? defaultConfigPath
        if (candidate as NSString).lastPathComponent.lowercased() != "config.json" {
            throw HookIntegrationError.validation("只能选择 ZCode 的 config.json 文件。")
        }
        if pathKey(candidate) == pathKey(HookIntegration.providerConfigPath(homeDirectory: homeDirectory)) {
            throw HookIntegrationError.validation("~/.zcode/v2/config.json 是 ZCode provider 配置，不能写入 Hook。请选择实际承载 hooks 的 config.json。")
        }
        return candidate
    }

    private func snapshot(
        configPath: String,
        status: HookSetupStatus,
        message: String,
        isConfigured: Bool,
        requiresEnableConfirmation: Bool
    ) -> HookSetupSnapshot {
        HookSetupSnapshot(
            configPath: configPath,
            databasePath: HookIntegration.sessionDatabasePath(configPath: configPath),
            status: status,
            message: message,
            isConfigured: isConfigured,
            requiresEnableConfirmation: requiresEnableConfirmation,
            ruleCount: HookIntegration.ruleCount
        )
    }

    // MARK: - 文件原语（manager:487-521）

    private func backup(_ configPath: String, raw: Data, operation: String) throws -> String {
        let directory = (configPath as NSString).deletingLastPathComponent + "/" + Self.backupDirectoryName
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds] // 对照 toISOString 的毫秒精度
        let timestamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let backupPath = directory + "/config-\(operation)-\(timestamp).json"
        try writeExclusive(backupPath, data: raw)
        return backupPath
    }

    /// 原子写配置：2 空格缩进 + 结尾换行；保留 BOM（manager:496-511）。
    /// 子类可覆写以注入异常（对照 TS 测试的 monkey patch）。
    func writeConfigAtomically(_ configPath: String, config: [String: Any], hasBom: Bool) throws -> Data {
        let temporary = temporaryPath(configPath, suffix: "tmp")
        let encoded = try Self.encodedJSON(config, hasBom: hasBom)
        try writeExclusive(temporary, data: encoded)
        defer { unlink(temporary) }
        try rename(temporary, to: configPath)
        return encoded
    }

    static func encodedJSON(_ config: [String: Any], hasBom: Bool) throws -> Data {
        // withoutEscapingSlashes：新版 JSONSerialization 默认转义 "/"（\/var\/…），
        // 语义等价但可读性差且与手写配置 diff 噪音大；显式关闭。
        let body = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        var data = hasBom ? Data([0xEF, 0xBB, 0xBF]) : Data()
        data.append(body)
        data.append(0x0A)
        return data
    }

    /// 回滚写回原文（临时文件 + 原子替换）；失败如实返回 false，由调用方上报。
    private func restoreRaw(_ configPath: String, raw: Data) -> Bool {
        let temporary = temporaryPath(configPath, suffix: "restore")
        do {
            try writeExclusive(temporary, data: raw)
            defer { unlink(temporary) }
            try rename(temporary, to: configPath)
            return true
        } catch {
            return false
        }
    }

    /// 状态写入（manager:553-564）；子类可覆写以注入异常。
    func writeState(_ state: HookIntegrationState) throws -> Data {
        try FileManager.default.createDirectory(
            atPath: (statePath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let temporary = temporaryPath(statePath, suffix: "tmp")
        let object: [String: Any] = [
            "version": state.version,
            "configPath": state.configPath,
            "executablePath": state.executablePath,
            "databasePath": state.databasePath,
            "backupPath": state.backupPath,
            "installedAt": state.installedAt,
        ]
        let written = try Self.encodedJSON(object, hasBom: false)
        try writeExclusive(temporary, data: written)
        defer { unlink(temporary) }
        try rename(temporary, to: statePath)
        return written
    }

    private func readState() -> HookIntegrationState? {
        guard isRegularFile(statePath), let raw = readRaw(statePath) else { return nil }
        guard let value = (try? JSONSerialization.jsonObject(with: stripBom(raw))) as? [String: Any] else { return nil }
        guard (value["version"] as? Int) == 1,
              let configPath = value["configPath"] as? String,
              let executablePath = value["executablePath"] as? String,
              let databasePath = value["databasePath"] as? String,
              let backupPath = value["backupPath"] as? String,
              let installedAt = value["installedAt"] as? String
        else { return nil }
        return HookIntegrationState(
            version: 1,
            configPath: configPath,
            executablePath: executablePath,
            databasePath: databasePath,
            backupPath: backupPath,
            installedAt: installedAt
        )
    }

    // MARK: - 底层工具

    private func pathKey(_ value: String) -> String {
        HookIntegration.normalizePath(value)
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "无法读取 ZCode 配置。"
    }

    private func isRegularFile(_ candidate: String) -> Bool {
        FileManager.default.fileExists(atPath: candidate)
    }

    private func readRaw(_ path: String) -> Data? {
        FileManager.default.contents(atPath: path)
    }

    private func requireRaw(_ path: String) throws -> Data {
        guard let raw = readRaw(path) else {
            throw HookIntegrationError.validation("无法读取 ZCode 配置：\(path)")
        }
        return raw
    }

    private func stripBom(_ data: Data) -> Data {
        data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data
    }

    /// 解析配置：严格 UTF-8 + BOM 检测（manager:41-50）。
    private func parseConfig(_ bytes: Data, configPath: String) throws -> (config: [String: Any], hasBom: Bool) {
        let hasBom = bytes.starts(with: [0xEF, 0xBB, 0xBF])
        let payload = hasBom ? bytes.dropFirst(3) : bytes[...]
        guard let parsed = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else {
            throw HookIntegrationError.validation("ZCode 配置不是有效 JSON：\(configPath)")
        }
        _ = try HookIntegration.validateHookConfig(parsed)
        return (parsed, hasBom)
    }

    /// 结构等价比较（对照 JSON.stringify 比较；sortedKeys 保证确定性）。
    private func sameJSON(_ left: [String: Any], _ right: [String: Any]) -> Bool {
        guard let leftData = try? JSONSerialization.data(withJSONObject: left, options: [.sortedKeys, .withoutEscapingSlashes]),
              let rightData = try? JSONSerialization.data(withJSONObject: right, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return false }
        return leftData == rightData
    }

    private func temporaryPath(_ targetPath: String, suffix: String) -> String {
        let directory = (targetPath as NSString).deletingLastPathComponent
        let name = (targetPath as NSString).lastPathComponent
        return directory + "/.\(name).\(ProcessInfo.processInfo.processIdentifier).\(Int(Date().timeIntervalSince1970 * 1000)).\(suffix)"
    }

    private func writeExclusive(_ path: String, data: Data) throws {
        let descriptor = open(path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        guard descriptor >= 0 else {
            throw HookIntegrationError.validation("无法创建临时文件：\(path)")
        }
        defer { close(descriptor) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < data.count {
                let written = write(descriptor, buffer.baseAddress! + offset, data.count - offset)
                if written <= 0 {
                    throw HookIntegrationError.validation("写入文件失败：\(path)")
                }
                offset += written
            }
        }
    }

    private func rename(_ from: String, to: String) throws {
        if Foundation.rename(from, to) != 0 {
            throw HookIntegrationError.validation("替换文件失败：\(to)")
        }
    }
}
