import Foundation

/// 设置持久化队列（对照 src/main/config-persistence.ts）。
/// 140ms 滑动 debounce、单槽只保留最新、串行 drain、失败聚合记录（无自动重试）。
/// 所有状态只触摸内部串行队列；timer 到期与 flush() 都在该队列上 drain，天然互斥。
public final class PersistenceQueue {
    public static let defaultDelayMs = 140

    private let delayMs: Int
    private let persist: (AppConfig) throws -> Void
    private let queue = DispatchQueue(label: "ZCodeStatusLight.settings.persistence")
    private var pending: AppConfig?
    private var timer: DispatchSourceTimer?
    private var lastErrorValue: Error?

    public init(delayMs: Int = PersistenceQueue.defaultDelayMs, persist: @escaping (AppConfig) throws -> Void) {
        self.delayMs = delayMs
        self.persist = persist
    }

    public var lastError: Error? {
        queue.sync { lastErrorValue }
    }

    /// 调度一次保存：覆盖旧 pending，重置 debounce 计时（config-persistence.ts:16-24）。
    public func schedule(_ config: AppConfig) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pending = config
            self.timer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + .milliseconds(self.delayMs))
            timer.setEventHandler { [weak self] in
                // 防抖到期：错误吞掉（对照 void flush().catch(() => undefined)，失败已记入 lastError）。
                try? self?.drainLocked()
            }
            timer.resume()
            self.timer = timer
        }
    }

    /// 立即落盘并等待完成（保存按钮 / 退出收尾用）。聚合失败向上抛；pending 清空。
    public func flush() throws {
        try queue.sync { [self] in
            timer?.cancel()
            timer = nil
            try drainLocked()
        }
    }

    /// 排空 pending：逐条串行 persist；失败聚合为一个错误（ts:49-62）。
    /// 只能在 self.queue 上调用（timer handler 与 flush 的 sync 闭包）。
    private func drainLocked() throws {
        var failures: [Error] = []
        while let candidate = pending {
            pending = nil
            do {
                try persist(candidate)
            } catch {
                failures.append(error)
            }
        }
        if !failures.isEmpty {
            let aggregate = PersistenceQueueError.aggregate(failures)
            lastErrorValue = aggregate
            // 防抖路径无调用方可回报（对照 void flush().catch(() => undefined) 的吞错），
            // 但 macOS 无 devtools 控制台，落一条系统日志是唯一的失败痕迹。
            NSLog("[ZCodeStatusLight] 设置防抖落盘失败：%@", String(describing: aggregate))
            throw aggregate
        }
    }
}

public enum PersistenceQueueError: Error, LocalizedError {
    case aggregate([Error])

    public var errorDescription: String? {
        switch self {
        case .aggregate(let failures):
            return "一个或多个配置保存操作失败。（\(failures.count) 次）"
        }
    }
}
