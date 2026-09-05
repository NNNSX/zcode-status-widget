import AppKit
import Core

/// Hook 集成确认对话框（对照 Windows 版 index.ts:92-146 的主进程确认弹窗文案）。
/// 集成默认关闭，必须经用户确认后才写 ~/.zcode/cli/config.json。
enum HookConfirmationDialog {
    /// 配置（写入）确认。返回 true 表示用户同意“备份并配置”。
    static func requestConfigure(snapshot: HookSetupSnapshot) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "确认修改此 ZCode 配置吗？"
        var detail = """
        目标配置：\(snapshot.configPath)
        将添加：\(snapshot.ruleCount) 条 process Hook 规则
        发送范围：仅 http://127.0.0.1:\(eventPort())/event，不访问外网。
        原始文件会先备份到：\((snapshot.configPath as NSString).deletingLastPathComponent)/\(HookIntegrationManager.backupDirectoryName)
        """
        if snapshot.requiresEnableConfirmation {
            detail += "\n当前 Hooks 已被明确关闭；确认后会将 hooks.enabled 设为 true。"
        }
        alert.informativeText = detail
        alert.addButton(withTitle: "备份并配置")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// 取消集成确认。
    static func requestUnconfigure(snapshot: HookSetupSnapshot) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "确认移除本应用配置的 ZCode Hook 吗？"
        alert.informativeText = """
        将仅移除：\(snapshot.ruleCount) 条本应用管理的 process Hook 规则
        不会删除 config.json，也不会修改其他 Hook、MCP、插件或 ZCode 设置。
        """
        alert.addButton(withTitle: "备份并移除")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func eventPort() -> UInt16 {
        guard let raw = ProcessInfo.processInfo.environment["ZCODE_STATUS_PORT"],
              let port = UInt16(raw), (1...65535).contains(port) else { return 57310 }
        return port
    }
}
