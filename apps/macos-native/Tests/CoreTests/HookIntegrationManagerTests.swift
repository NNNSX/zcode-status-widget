import Foundation
@testable import Core

/// Hook 集成事务（对照 apps/desktop/tests/hook-integration-manager.test.ts；monkey patch 用子类覆写替代）。
final class HookIntegrationManagerTests: ZTestCase {
    private struct Fixture {
        let root: String
        let configPath: String
        let executablePath: String
        let statePath: String
    }

    private func makeFixture() -> Fixture {
        let root = NSTemporaryDirectory() + "zcode-status-hook-test-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let fixture = Fixture(
            root: root,
            configPath: root + "/config.json",
            executablePath: root + "/ZCodeStatusHook",
            statePath: root + "/app-data/integration-state.json"
        )
        FileManager.default.createFile(atPath: fixture.executablePath, contents: Data("helper".utf8))
        return fixture
    }

    private func manager(_ fixture: Fixture) -> HookIntegrationManager {
        HookIntegrationManager(options: .init(
            executablePath: fixture.executablePath,
            statePath: fixture.statePath,
            defaultConfigPath: fixture.configPath,
            homeDirectory: "/Users/tester"
        ))
    }

    private func writeJSON(_ object: Any, to path: String) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        FileManager.default.createFile(atPath: path, contents: data)
    }

    private func readJSON(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func readRaw(_ path: String) -> Data? {
        FileManager.default.contents(atPath: path)
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    // MARK: - 配置事务

    @objc func testConfigureBacksUpAndMergesOnlyItsRules() {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let source: [String: Any] = [
            "mcp": ["servers": ["existing": ["command": "tool"]]],
            "plugins": ["enabled": ["existing"]],
            "hooks": [
                "enabled": true,
                "events": [
                    "UserPromptSubmit": [["hooks": [["type": "process", "command": "third-party", "args": [] as [Any], "timeoutMs": 1000]]]],
                    "Stop": [["matcher": "third-party", "hooks": [["type": "process", "command": "third-party", "args": [] as [Any], "timeoutMs": 1000]]]],
                ] as [String: Any],
            ] as [String: Any],
        ]
        writeJSON(source, to: fixture.configPath)

        let result = try? manager(fixture).configure()
        ztAssertEqual(result?.status, .configured)
        ztAssertEqual(result?.isConfigured, true)
        ztAssertEqual(result?.ruleCount, 6)

        let written = readJSON(fixture.configPath)
        ztAssertNotNil((written?["mcp"] as? [String: Any])?["servers"], "mcp 保留")
        ztAssertNotNil((written?["plugins"] as? [String: Any])?["enabled"], "plugins 保留")
        let events = ((written?["hooks"] as? [String: Any])?["events"] as? [String: Any])
        ztAssertEqual((events?["UserPromptSubmit"] as? [Any])?.count, 2)
        ztAssertEqual((events?["Stop"] as? [Any])?.count, 2)

        let backupDirectory = fixture.root + "/" + HookIntegrationManager.backupDirectoryName
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: backupDirectory)) ?? []
        ztAssertEqual(backups.count, 1, "恰好一个备份")
        let state = readJSON(fixture.statePath)
        ztAssertEqual(state?["configPath"] as? String, fixture.configPath)
    }

    @objc func testDisabledHooksRequireExplicitConfirmation() {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let source: [String: Any] = ["hooks": ["enabled": false, "events": [:] as [String: Any]] as [String: Any], "mcp": ["retained": true]]
        writeJSON(source, to: fixture.configPath)
        let before = readRaw(fixture.configPath)

        var threw = false
        do {
            _ = try manager(fixture).configure()
        } catch {
            threw = "\("\(error)")".contains("单独确认")
        }
        ztAssertTrue(threw, "未确认时拒绝")
        ztAssertEqual(readRaw(fixture.configPath), before, "配置未被修改")

        let configured = try? manager(fixture).configure(nil, enableDisabledHooks: true)
        ztAssertEqual(configured?.status, .configured)
        let written = readJSON(fixture.configPath)
        ztAssertEqual(((written?["hooks"] as? [String: Any])?["enabled"] as? Bool), true)
        ztAssertNotNil((written?["mcp"] as? [String: Any])?["retained"], "mcp 保留")
    }

    @objc func testUnconfigureRemovesOnlyManagedRules() {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        writeJSON([
            "hooks": [
                "enabled": true,
                "events": ["Stop": [["hooks": [["type": "process", "command": "third-party", "args": [] as [Any], "timeoutMs": 1000]]]]] as [String: Any],
            ] as [String: Any],
        ], to: fixture.configPath)

        _ = try? manager(fixture).configure()
        let removed = (try? manager(fixture).unconfigure()) ?? false
        ztAssertEqual(removed, true)
        let events = ((readJSON(fixture.configPath)?["hooks"] as? [String: Any])?["events"] as? [String: Any])
        ztAssertEqual((events?["Stop"] as? [Any])?.count, 1, "第三方规则保留")

        let again = (try? manager(fixture).unconfigure()) ?? true
        ztAssertEqual(again, false, "无状态时二次取消返回 false")
    }

    @objc func testSuggestedPathRemembersCustomConfig() {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let customDirectory = fixture.root + "/custom profile"
        try? FileManager.default.createDirectory(atPath: customDirectory, withIntermediateDirectories: true)
        let customConfigPath = customDirectory + "/config.json"
        writeJSON(["hooks": ["enabled": true, "events": [:] as [String: Any]] as [String: Any]], to: fixture.configPath)
        writeJSON(["hooks": ["enabled": true, "events": [:] as [String: Any]] as [String: Any]], to: customConfigPath)

        _ = try? manager(fixture).configure(customConfigPath)

        let restarted = manager(fixture).inspect()
        ztAssertEqual(restarted.configPath, customConfigPath, "重启后沿用记录的自定义路径")
        ztAssertEqual(restarted.status, .configured)
        ztAssertEqual(restarted.isConfigured, true)
    }

    @objc func testSuggestedPathIgnoresOtherHelper() {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let customDirectory = fixture.root + "/custom profile"
        try? FileManager.default.createDirectory(atPath: customDirectory, withIntermediateDirectories: true)
        let customConfigPath = customDirectory + "/config.json"
        writeJSON(["hooks": ["enabled": true, "events": [:] as [String: Any]] as [String: Any]], to: fixture.configPath)
        writeJSON(["hooks": ["enabled": true, "events": [:] as [String: Any]] as [String: Any]], to: customConfigPath)
        _ = try? manager(fixture).configure(customConfigPath)

        let otherExecutable = fixture.root + "/other-helper"
        FileManager.default.createFile(atPath: otherExecutable, contents: Data("helper".utf8))
        let restarted = HookIntegrationManager(options: .init(
            executablePath: otherExecutable,
            statePath: fixture.statePath,
            defaultConfigPath: fixture.configPath,
            homeDirectory: "/Users/tester"
        ))
        let snapshot = restarted.inspect()
        ztAssertEqual(snapshot.configPath, fixture.configPath, "非受管 helper 不恢复自定义路径")
        ztAssertEqual(snapshot.status, .ready)
        ztAssertEqual(snapshot.isConfigured, false)
    }

    @objc func testMigratesRulesToNewExecutablePath() {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        writeJSON(["hooks": ["enabled": true, "events": [:] as [String: Any]] as [String: Any]], to: fixture.configPath)
        _ = try? manager(fixture).configure()

        let nextDirectory = fixture.root + "/next-install"
        try? FileManager.default.createDirectory(atPath: nextDirectory, withIntermediateDirectories: true)
        let nextExecutable = nextDirectory + "/ZCodeStatusHook"
        FileManager.default.createFile(atPath: nextExecutable, contents: Data("helper".utf8))
        let upgraded = HookIntegrationManager(options: .init(
            executablePath: nextExecutable,
            statePath: fixture.statePath,
            defaultConfigPath: fixture.configPath,
            homeDirectory: "/Users/tester"
        ))

        ztAssertEqual(upgraded.inspect().status, .ready, "旧路径规则不算已配置")
        do {
            _ = try upgraded.configure()
        } catch {
            ztAssertTrue(false, "upgraded configure threw: \(error)")
        }
        let raw = String(data: readRaw(fixture.configPath) ?? Data(), encoding: .utf8) ?? ""
        ztAssertTrue(raw.contains(nextExecutable), "新路径写入")
        ztAssertFalse(raw.contains(fixture.executablePath), "旧路径移除")
        let removed = (try? upgraded.unconfigure()) ?? false
        ztAssertEqual(removed, true)
    }

    @objc func testDisabledStateWhenFullyConfigured() {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        writeJSON(["hooks": ["enabled": true, "events": [:] as [String: Any]] as [String: Any]], to: fixture.configPath)
        _ = try? manager(fixture).configure()
        var configured = readJSON(fixture.configPath) ?? [:]
        var hooks = (configured["hooks"] as? [String: Any]) ?? [:]
        hooks["enabled"] = false
        configured["hooks"] = hooks
        writeJSON(configured, to: fixture.configPath)

        let snapshot = manager(fixture).inspect()
        ztAssertEqual(snapshot.status, .disabled)
        ztAssertEqual(snapshot.isConfigured, false)
        ztAssertEqual(snapshot.requiresEnableConfirmation, true)
    }

    @objc func testDuplicateRulesDeduplicatedOnConfigure() {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        writeJSON(["hooks": ["enabled": true, "events": [:] as [String: Any]] as [String: Any]], to: fixture.configPath)
        _ = try? manager(fixture).configure()

        var configured = readJSON(fixture.configPath) ?? [:]
        var hooks = (configured["hooks"] as? [String: Any]) ?? [:]
        var events = (hooks["events"] as? [String: Any]) ?? [:]
        var stopRules = (events["Stop"] as? [Any]) ?? []
        stopRules.append(stopRules[0])
        events["Stop"] = stopRules
        hooks["events"] = events
        configured["hooks"] = hooks
        writeJSON(configured, to: fixture.configPath)

        let snapshot = manager(fixture).inspect()
        ztAssertEqual(snapshot.status, .ready, "重复规则不算已配置")
        ztAssertEqual(snapshot.isConfigured, false)

        _ = try? manager(fixture).configure()
        let rewritten = ((readJSON(fixture.configPath)?["hooks"] as? [String: Any])?["events"] as? [String: Any])
        ztAssertEqual((rewritten?["Stop"] as? [Any])?.count, 1, "配置后去重为 1")
    }

    @objc func testPreservesUtf8Bom() {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        var payload = Data([0xEF, 0xBB, 0xBF])
        payload.append(try! JSONSerialization.data(withJSONObject: ["hooks": ["enabled": true, "events": [:] as [String: Any]] as [String: Any]]))
        FileManager.default.createFile(atPath: fixture.configPath, contents: payload)

        _ = try? manager(fixture).configure()
        ztAssertEqual(Array(readRaw(fixture.configPath)?.prefix(3) ?? Data()), [0xEF, 0xBB, 0xBF], "configure 后 BOM 保留")
        _ = try? manager(fixture).unconfigure()
        ztAssertEqual(Array(readRaw(fixture.configPath)?.prefix(3) ?? Data()), [0xEF, 0xBB, 0xBF], "unconfigure 后 BOM 保留")
    }

    @objc func testInvalidStructureUnmodified() {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let source: [String: Any] = ["hooks": ["enabled": true, "events": ["Stop": ["invalid": true] as [String: Any]] as [String: Any]] as [String: Any]]
        writeJSON(source, to: fixture.configPath)
        let before = readRaw(fixture.configPath)

        ztAssertEqual(manager(fixture).inspect().status, .invalid)
        var threw = false
        do {
            _ = try manager(fixture).configure()
        } catch {
            threw = "\("\(error)")".contains("必须是数组")
        }
        ztAssertTrue(threw)
        ztAssertEqual(readRaw(fixture.configPath), before, "非法结构不修改文件")
    }

    @objc func testLockTimeoutFailsBounded() {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        writeJSON(["hooks": ["enabled": true, "events": [:] as [String: Any]] as [String: Any]], to: fixture.configPath)
        let before = readRaw(fixture.configPath)
        FileManager.default.createFile(atPath: fixture.root + "/.zcode-status-light.lock", contents: Data("locked".utf8))

        var threw = false
        do {
            _ = try manager(fixture).configure()
        } catch {
            threw = "\("\(error)")".contains("正在被其他状态灯操作修改")
        }
        ztAssertTrue(threw, "锁被占时有限等待后失败")
        ztAssertEqual(readRaw(fixture.configPath), before)
    }

    @objc func testMissingConfigDoesNotCreateFile() {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        var threw = false
        do {
            _ = try manager(fixture).configure()
        } catch {
            threw = "\("\(error)")".contains("未找到默认 Hook 配置")
        }
        ztAssertTrue(threw)
        ztAssertFalse(exists(fixture.configPath), "不创建配置文件")
    }

    @objc func testProviderOnlyConfigRejected() {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let source = ["provider": ["endpoint": "https://provider.example"]]
        writeJSON(source, to: fixture.configPath)
        let before = readRaw(fixture.configPath)

        let snapshot = manager(fixture).inspect()
        ztAssertEqual(snapshot.status, .invalid)
        ztAssertTrue(snapshot.message.contains("provider 配置"))
        var threw = false
        do {
            _ = try manager(fixture).configure()
        } catch {
            threw = "\("\(error)")".contains("provider 配置")
        }
        ztAssertTrue(threw)
        ztAssertEqual(readRaw(fixture.configPath), before)
    }

    @objc func testProviderCanonicalPathRejected() {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let providerPath = "/Users/tester/.zcode/v2/config.json"
        let snapshot = manager(fixture).inspect(providerPath)
        ztAssertEqual(snapshot.status, .invalid)
        ztAssertTrue(snapshot.message.contains("provider 配置"))
        var threw = false
        do {
            _ = try manager(fixture).configure(providerPath)
        } catch {
            threw = "\("\(error)")".contains("provider 配置")
        }
        ztAssertTrue(threw)
    }

    // MARK: - 失败恢复（子类注入，对照 TS monkey patch 用例）

    private final class FailingStateManager: HookIntegrationManager {
        let failure: () -> Void
        init(fixture: Fixture, failure: @escaping () -> Void) {
            self.failure = failure
            super.init(options: .init(
                executablePath: fixture.executablePath,
                statePath: fixture.statePath,
                defaultConfigPath: fixture.configPath,
                homeDirectory: "/Users/tester"
            ))
        }

        override func writeState(_ state: HookIntegrationState) throws -> Data {
            failure()
            throw HookIntegrationError.validation("state write failed")
        }
    }

    @objc func testStateWriteFailureRestoresConfig() {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let sourceJSON = try! JSONSerialization.data(withJSONObject: ["hooks": ["enabled": true, "events": [:] as [String: Any]] as [String: Any], "retained": "value"])
        FileManager.default.createFile(atPath: fixture.configPath, contents: sourceJSON)

        let failing = FailingStateManager(fixture: fixture, failure: {})
        var threw = false
        do {
            _ = try failing.configure()
        } catch {
            threw = "\("\(error)")".contains("state write failed")
        }
        ztAssertTrue(threw)
        ztAssertEqual(readRaw(fixture.configPath), sourceJSON, "配置还原为原始内容")
        ztAssertFalse(exists(fixture.statePath), "状态文件不存在")
    }

    @objc func testExternalConfigChangeNotOverwritten() {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        writeJSON(["hooks": ["enabled": true, "events": [:] as [String: Any]] as [String: Any]], to: fixture.configPath)

        let externalJSON = try! JSONSerialization.data(withJSONObject: ["external": true])
        let failing = FailingStateManager(fixture: fixture) { [configPath = fixture.configPath] in
            FileManager.default.createFile(atPath: configPath, contents: externalJSON)
        }
        var message = ""
        do {
            _ = try failing.configure()
        } catch {
            message = "\(error)"
        }
        ztAssertTrue(message.contains("配置文件已被外部修改，未覆盖"), "错误信息：\(message)")
        ztAssertEqual(readRaw(fixture.configPath), externalJSON, "外部修改内容保留")
    }

    private final class FailingStateRemover: HookIntegrationManager {
        init(fixture: Fixture) {
            super.init(options: .init(
                executablePath: fixture.executablePath,
                statePath: fixture.statePath,
                defaultConfigPath: fixture.configPath,
                homeDirectory: "/Users/tester"
            ))
        }

        override func removeStateIfUnchanged(_ expected: Data) throws {
            throw HookIntegrationError.validation("state removal failed")
        }
    }

    @objc func testStateRemovalFailureRestoresManagedRules() {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        writeJSON(["hooks": ["enabled": true, "events": [:] as [String: Any]] as [String: Any]], to: fixture.configPath)
        _ = try? manager(fixture).configure()
        let configuredRaw = readRaw(fixture.configPath)

        let failing = FailingStateRemover(fixture: fixture)
        var threw = false
        do {
            _ = try failing.unconfigure()
        } catch {
            threw = "\("\(error)")".contains("state removal failed")
        }
        ztAssertTrue(threw)
        ztAssertEqual(readRaw(fixture.configPath), configuredRaw, "受管规则还原")
        ztAssertEqual(readJSON(fixture.statePath)?["configPath"] as? String, fixture.configPath, "状态记录保留")
    }

    private final class RuleInjectingManager: HookIntegrationManager {
        let injected: [String: Any]
        init(fixture: Fixture, injected: [String: Any]) {
            self.injected = injected
            super.init(options: .init(
                executablePath: fixture.executablePath,
                statePath: fixture.statePath,
                defaultConfigPath: fixture.configPath,
                homeDirectory: "/Users/tester"
            ))
        }

        override func writeConfigAtomically(_ configPath: String, config: [String: Any], hasBom: Bool) throws -> Data {
            var mutated = config
            var hooks = (mutated["hooks"] as? [String: Any]) ?? [:]
            var events = (hooks["events"] as? [String: Any]) ?? [:]
            events["Stop"] = ((events["Stop"] as? [Any]) ?? []) + [injected]
            hooks["events"] = events
            mutated["hooks"] = hooks
            return try super.writeConfigAtomically(configPath, config: mutated, hasBom: hasBom)
        }
    }

    @objc func testUnconfigureVerificationRestoresConfig() {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        writeJSON(["hooks": ["enabled": true, "events": [:] as [String: Any]] as [String: Any]], to: fixture.configPath)
        _ = try? manager(fixture).configure()
        let configuredRaw = readRaw(fixture.configPath)
        let configured = (try? JSONSerialization.jsonObject(with: configuredRaw ?? Data())) as? [String: Any]
        let stopRules = ((((configured?["hooks"] as? [String: Any])?["events"] as? [String: Any])?["Stop"] as? [Any]) ?? [])
        let retainedRule = stopRules.first as? [String: Any] ?? [:]

        let injecting = RuleInjectingManager(fixture: fixture, injected: retainedRule)
        var threw = false
        do {
            _ = try injecting.unconfigure()
        } catch {
            threw = "\("\(error)")".contains("仍检测到本程序管理的状态 Hook")
        }
        ztAssertTrue(threw)
        ztAssertEqual(readRaw(fixture.configPath), configuredRaw, "写后校验失败时还原")
        ztAssertEqual(readJSON(fixture.statePath)?["configPath"] as? String, fixture.configPath, "状态记录保留")
    }
}
