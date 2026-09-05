import Foundation
@testable import Core

/// Hook 集成纯逻辑（对照 apps/desktop/tests/hook-integration.test.ts 的场景）。
final class HookIntegrationTests: ZTestCase {
    private let executable = "/opt/ZCodeStatusLight/hook/ZCodeStatusHook"
    private let database = "/Users/tester/.zcode/cli/db/db.sqlite"

    private func unmanagedRule() -> [String: Any] {
        [
            "matcher": "third-party",
            "hooks": [["type": "process", "command": "third-party", "args": [] as [Any], "timeoutMs": 1000]],
        ]
    }

    @objc func testManagedHookRuleShape() {
        let withMatcher = HookIntegration.managedHookRule(spec: hookRuleSpecs[1], executablePath: executable, databasePath: database)
        ztAssertEqual(withMatcher["matcher"] as? String, "^Bash$")
        let hooks = withMatcher["hooks"] as? [Any]
        ztAssertEqual(hooks?.count, 1)
        let hook = hooks?[0] as? [String: Any]
        ztAssertEqual(hook?["type"] as? String, "process")
        ztAssertEqual(hook?["command"] as? String, executable)
        ztAssertEqual(hook?["timeoutMs"] as? Int, 5000)
        ztAssertEqual((hook?["args"] as? [Any])?.count, 4)

        let withoutMatcher = HookIntegration.managedHookRule(spec: hookRuleSpecs[0], executablePath: executable, databasePath: database)
        ztAssertNil(withoutMatcher["matcher"])
    }

    @objc func testMergePreservesThirdPartyRulesAndSetsEnabled() {
        let source: [String: Any] = [
            "mcp": ["servers": ["existing": ["command": "tool"]]],
            "hooks": [
                "enabled": true,
                "events": [
                    "Stop": [unmanagedRule()],
                ] as [String: Any],
            ] as [String: Any],
        ]
        let merged = try? HookIntegration.mergeHookConfig(source: source, executablePath: executable, databasePath: database)
        ztAssertNotNil(merged)
        let hooks = merged?.config["hooks"] as? [String: Any]
        ztAssertEqual(hooks?["enabled"] as? Bool, true)
        let events = hooks?["events"] as? [String: Any]
        let stopRules = events?["Stop"] as? [Any]
        ztAssertEqual(stopRules?.count, 2, "第三方规则保留 + 1 条受管规则")
        ztAssertNotNil(merged?.config["mcp"] as? [String: Any], "未知顶层配置保留")
        ztAssertEqual(merged?.enabledWasFalse, false)
        // 6 个事件键全部有受管规则。
        for spec in hookRuleSpecs {
            let rules = events?[spec.event.rawValue] as? [Any] ?? []
            let managed = rules.filter { HookIntegration.isManagedHookRule($0, spec: spec, executablePath: executable, databasePath: database) }
            ztAssertEqual(managed.count, 1, "\(spec.event.rawValue) 恰好 1 条受管规则")
        }
    }

    @objc func testMergeKeepsStalePathRulesUntilMigration() {
        // merge 只替换当前 executable 的受管规则；旧安装路径的规则由 Manager 迁移逻辑先移除
        // （manager.mergeForCurrentExecutable），纯 merge 语义与 TS 一致：旧规则保留。
        let stale = HookIntegration.managedHookRule(spec: hookRuleSpecs[5], executablePath: "/old/path/ZCodeStatusHook", databasePath: database)
        let source: [String: Any] = ["hooks": ["enabled": true, "events": ["Stop": [stale]] as [String: Any]] as [String: Any]]
        let merged = try? HookIntegration.mergeHookConfig(source: source, executablePath: executable, databasePath: database)
        let events = (merged?.config["hooks"] as? [String: Any])?["events"] as? [String: Any]
        ztAssertEqual((events?["Stop"] as? [Any])?.count, 2, "旧路径规则保留 + 当前受管规则追加")
        let current = (events?["Stop"] as? [Any])?.filter {
            HookIntegration.isManagedHookRule($0, spec: hookRuleSpecs[5], executablePath: executable, databasePath: database)
        }
        ztAssertEqual(current?.count, 1, "当前路径恰好 1 条")
    }

    @objc func testMergeRejectedDisabledHooksWithoutConfirmation() {
        let source: [String: Any] = ["hooks": ["enabled": false, "events": [:] as [String: Any]] as [String: Any]]
        var threw = false
        _ = try? HookIntegration.mergeHookConfig(source: source, executablePath: executable, databasePath: database)
        do {
            _ = try HookIntegration.mergeHookConfig(source: source, executablePath: executable, databasePath: database)
        } catch {
            threw = true
            ztAssertTrue("\(error)".contains("已被明确关闭"), "错误文案：\(error)")
        }
        ztAssertTrue(threw)

        let enabled = try? HookIntegration.mergeHookConfig(
            source: source, executablePath: executable, databasePath: database, enableDisabledHooks: true
        )
        ztAssertEqual(enabled?.enabledWasFalse, true)
        ztAssertEqual(((enabled?.config["hooks"] as? [String: Any])?["enabled"] as? Bool), true)
    }

    @objc func testRemoveManagedRulesKeepsThirdParty() {
        let source = try? HookIntegration.mergeHookConfig(
            source: ["hooks": ["enabled": true, "events": ["Stop": [unmanagedRule()]] as [String: Any]] as [String: Any]],
            executablePath: executable,
            databasePath: database
        )
        let removed = try? HookIntegration.removeManagedHookRules(source: source!.config, executablePath: executable, databasePath: database)
        let events = ((removed?["hooks"] as? [String: Any])?["events"] as? [String: Any])
        ztAssertEqual((events?["Stop"] as? [Any])?.count, 1, "第三方规则保留")
        ztAssertEqual(((events?["Stop"] as? [Any])?[0] as? [String: Any])?["matcher"] as? String, "third-party")
    }

    @objc func testRemoveWithoutHooksReturnsSource() {
        let source: [String: Any] = ["mcp": ["kept": true]]
        let removed = try? HookIntegration.removeManagedHookRules(source: source, executablePath: executable, databasePath: database)
        ztAssertEqual((removed?["mcp"] as? [String: Any])?.count, 1)
    }

    @objc func testIsManagedRuleStrictMatching() {
        let spec = hookRuleSpecs[1] // PermissionRequest ^Bash$
        let rule = HookIntegration.managedHookRule(spec: spec, executablePath: executable, databasePath: database)
        ztAssertTrue(HookIntegration.isManagedHookRule(rule, spec: spec, executablePath: executable, databasePath: database), "base")
        // 路径大小写与尾斜杠归一化后仍匹配。
        ztAssertTrue(HookIntegration.isManagedHookRule(rule, spec: spec, executablePath: executable + "/", databasePath: database + "/"), "trailing slash")
        ztAssertTrue(HookIntegration.isManagedHookRule(rule, spec: spec, executablePath: executable.uppercased(), databasePath: database), "uppercased")
        // matcher 不同 / timeout 不同 / args 缺项 → 非受管。
        ztAssertFalse(HookIntegration.isManagedHookRule(rule, spec: hookRuleSpecs[2], executablePath: executable, databasePath: database), "matcher mismatch")
        var mutated = rule
        mutated["matcher"] = "^Sh+$"
        ztAssertFalse(HookIntegration.isManagedHookRule(mutated, spec: spec, executablePath: executable, databasePath: database), "mutated matcher")
        // spec 无 matcher 时，规则带显式 matcher 键 → 非受管。
        let noMatcherSpec = hookRuleSpecs[0]
        ztAssertFalse(HookIntegration.isManagedHookRule(rule, spec: noMatcherSpec, executablePath: executable, databasePath: database), "no-matcher spec vs matcher rule")
        // timeoutMs 差异。
        var timeoutRule = HookIntegration.managedHookRule(spec: spec, executablePath: executable, databasePath: database)
        var hook = (timeoutRule["hooks"] as? [Any])?[0] as? [String: Any] ?? [:]
        hook["timeoutMs"] = 3000
        timeoutRule["hooks"] = [hook]
        ztAssertFalse(HookIntegration.isManagedHookRule(timeoutRule, spec: spec, executablePath: executable, databasePath: database), "timeout mismatch")
    }

    @objc func testValidateHookConfigRejectsMalformedShapes() {
        var threw = false
        do { _ = try HookIntegration.validateHookConfig(["hooks": "not-object"]) } catch { threw = true }
        ztAssertTrue(threw, "hooks 非对象")
        threw = false
        do { _ = try HookIntegration.validateHookConfig(["hooks": ["events": [1, 2] as [Any]] as [String: Any]]) } catch { threw = true }
        ztAssertTrue(threw, "hooks.events 非对象")
        threw = false
        do { _ = try HookIntegration.validateHookConfig(["hooks": ["events": ["Stop": ["invalid": true] as [String: Any]] as [String: Any]] as [String: Any]]) } catch {
            threw = "\("\(error)")".contains("必须是数组")
        }
        ztAssertTrue(threw, "事件规则非数组")
    }

    @objc func testProviderOnlyConfigDetection() {
        ztAssertTrue(HookIntegration.isProviderOnlyConfig(["provider": ["endpoint": "https://x"]]))
        ztAssertFalse(HookIntegration.isProviderOnlyConfig(["provider": ["endpoint": "https://x"], "hooks": [:] as [String: Any]]))
        ztAssertFalse(HookIntegration.isProviderOnlyConfig(["hooks": [:] as [String: Any]]))
        ztAssertFalse(HookIntegration.isProviderOnlyConfig(["mcp": [:] as [String: Any]]))
    }

    @objc func testPathHelpers() {
        ztAssertEqual(
            HookIntegration.defaultZcodeConfigPath(homeDirectory: "/Users/tester"),
            "/Users/tester/.zcode/cli/config.json"
        )
        ztAssertEqual(
            HookIntegration.sessionDatabasePath(configPath: "/Users/tester/.zcode/cli/config.json"),
            "/Users/tester/.zcode/cli/db/db.sqlite"
        )
        ztAssertEqual(HookIntegration.normalizePath("/A//b/"), "/a/b")
        ztAssertEqual(HookIntegration.normalizePath("C:\\Tools\\Hook\\"), "c:/tools/hook")
    }
}
