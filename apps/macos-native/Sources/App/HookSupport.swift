import Foundation
import Core

/// App 侧 Hook 集成入口（对照 hookExecutablePath 与 HookIntegrationManager 装配）。
enum HookSupport {
    /// helper 可执行路径：打包后 Contents/Resources/hook/；开发态用 .build/debug 产物。
    static func hookExecutablePath() -> String {
        let bundle = Bundle.main
        if bundle.bundlePath.hasSuffix(".app"),
           let resources = bundle.resourceURL {
            return resources.appendingPathComponent("hook/ZCodeStatusHook").path
        }
        // 开发态：本文件位于 Sources/App/，产物在 ../../../.build/debug/。
        let sourceDirectory = (#filePath as NSString).deletingLastPathComponent
        let projectRoot = (sourceDirectory as NSString).deletingLastPathComponent
            + "/../.build/debug/ZCodeStatusHook"
        return (projectRoot as NSString).standardizingPath
    }

    static func appDataPath() -> String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path
    }

    /// 默认装配：状态记录在 ~/Library/Application Support/ZCodeStatusLight/。
    static func defaultManager() -> HookIntegrationManager {
        HookIntegrationManager(options: .init(
            executablePath: hookExecutablePath(),
            statePath: HookIntegrationManager.defaultStatePath(appDataPath: appDataPath()),
            defaultConfigPath: HookIntegration.defaultZcodeConfigPath(homeDirectory: NSHomeDirectory())
        ))
    }
}
