import Foundation
@testable import Core

/// 持久化队列（对照 config-persistence 队列语义）。
final class PersistenceQueueTests: ZTestCase {
    @objc func testDebounceKeepsOnlyLatest() {
        let gate = DispatchQueue(label: "test")
        var saved: [AppConfig] = []
        let queue = PersistenceQueue { saved.append($0) }

        var config = AppConfig.default
        config.opacity = 80
        queue.schedule(config)
        config.opacity = 60
        queue.schedule(config)
        config.opacity = 40
        queue.schedule(config)

        // 未到 debounce 窗口：尚未落盘。
        gate.sync { ztAssertEqual(saved.count, 0, "no persist before debounce") }

        try? queue.flush()
        ztAssertEqual(saved.count, 1, "only latest survives")
        ztAssertEqual(saved.first?.opacity, 40)
    }

    @objc func testFlushPersistsImmediately() {
        var saved: [AppConfig] = []
        let queue = PersistenceQueue { saved.append($0) }
        queue.schedule(AppConfig.default)
        try? queue.flush()
        ztAssertEqual(saved.count, 1, "flush bypasses debounce")
        ztAssertNil(queue.lastError)
    }

    @objc func testFailuresAggregatedAndLatestKeptDraining() {
        var saved: [AppConfig] = []
        var attempts = 0
        let queue = PersistenceQueue(delayMs: 10) { config -> Void in
            attempts += 1
            if attempts == 1 {
                throw HookIntegrationError.validation("disk full")
            }
            saved.append(config)
        }
        var config = AppConfig.default
        config.opacity = 70
        queue.schedule(config)
        // 等待第一个（失败的）drain 完成。
        Thread.sleep(forTimeInterval: 0.3)

        ztAssertEqual(attempts, 1)
        ztAssertNotNil(queue.lastError, "failure recorded")

        config.opacity = 90
        queue.schedule(config)
        try? queue.flush()
        ztAssertEqual(attempts, 2, "later schedules still drain")
        ztAssertEqual(saved.count, 1)
        ztAssertEqual(saved.first?.opacity, 90)
    }

    @objc func testFlushWithoutPendingIsNoop() {
        var saved: [AppConfig] = []
        let queue = PersistenceQueue { saved.append($0) }
        try? queue.flush()
        ztAssertEqual(saved.count, 0)
    }
}
