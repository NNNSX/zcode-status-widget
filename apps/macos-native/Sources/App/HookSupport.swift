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
        // 开发态：裸可执行与 helper 产物同在 .build/debug/。不能用 #filePath 定位源码目录——
        // 它在编译期展开为构建机的绝对路径（含用户名），会被写进发布二进制。
        return bundle.bundleURL.appendingPathComponent("ZCodeStatusHook").path
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
