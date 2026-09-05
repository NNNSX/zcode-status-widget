import Foundation
import Core

/// 设置持久化（mac 对应 settings-file 方案，交接文档 §4.2）：
/// 读写 ~/Library/Application Support/ZCodeStatusLight/settings.json，原子写。
struct SettingsStore {
    static var settingsURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZCodeStatusLight", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    /// 读取；缺失/非法 → 默认配置（对照 SettingsRegistry.load 的容错语义）。
    /// 非法时记录日志：外部损坏此前完全静默，排障无从下手。
    static func load() -> AppConfig {
        let url = settingsURL
        do {
            let data = try Data(contentsOf: url)
            do {
                let config = try JSONDecoder().decode(AppConfig.self, from: data)
                // 全量钳制（对照 Windows load 后过 normalizeConfig）：手改文件
                // 的越界值收敛到合法范围（normalized 叠加空 input 不会钳 base）。
                return config.normalized()
            } catch {
                NSLog("[ZCodeStatusLight] settings.json 解析失败（%@），已回退默认配置：%@",
                      url.path, String(describing: error))
                return .default
            }
        } catch {
            // 文件不存在属正常（首次运行）；读失败（权限等）才提示。
            if (error as NSError).code != NSFileReadNoSuchFileError {
                NSLog("[ZCodeStatusLight] settings.json 读取失败（%@）：%@",
                      url.path, String(describing: error))
            }
            return .default
        }
    }

    /// 原子写：临时文件 → rename（对照 manager 的原子写策略）。
    static func persist(_ config: AppConfig) throws {
        let url = settingsURL
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        let temporary = directory.appendingPathComponent(".settings.\(ProcessInfo.processInfo.processIdentifier).tmp")
        try data.write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary, backupItemName: nil, options: [])
    }
}
