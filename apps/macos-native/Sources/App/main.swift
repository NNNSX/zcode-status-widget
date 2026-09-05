import AppKit
import Core

// ZCode Status Light — macOS 原生版入口。
// LSUIElement=true（打包时 Info.plist）：不显示 Dock 图标，仅菜单栏托盘。
//
// CLI 模式：
//   ZCodeStatusLight --unconfigure-hooks   移除受管 Hook 规则并退出（卸载清理用，不启动界面）。

private func runUnconfigureHooksCLI() -> Int32 {
    let manager = HookSupport.defaultManager()
    do {
        let removed = try manager.unconfigure()
        if removed {
            print("已移除 ZCode 状态 Hook 规则。备份位于配置同目录的 \(HookIntegrationManager.backupDirectoryName)/ 下。")
        } else {
            print("没有找到由本程序管理的 ZCode 状态 Hook（无需清理）。")
        }
        return 0
    } catch {
        print("取消集成失败：\((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        return 1
    }
}

let arguments = CommandLine.arguments
if arguments.contains("--unconfigure-hooks") {
    exit(runUnconfigureHooksCLI())
}

let app = NSApplication.shared
let coordinator = AppCoordinator()
app.delegate = coordinator
app.setActivationPolicy(.accessory)
app.run()
