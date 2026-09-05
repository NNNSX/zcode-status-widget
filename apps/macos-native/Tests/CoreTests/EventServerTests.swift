import Foundation
import Network
@testable import Core

/// 对照 apps/desktop/tests/event-server.test.ts。
final class EventServerTests: ZTestCase {
    private func request(_ url: String, _ body: String?, method: String = "POST") -> Int {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue(String(body.utf8.count), forHTTPHeaderField: "content-length")
            request.httpBody = Data(body.utf8)
        }
        var statusCode = -1
        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse { statusCode = http.statusCode }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 5)
        return statusCode
    }

    private func withServer(
        options: EventServer.Options = .init(),
        _ callback: (EventServer, String) -> Void
    ) {
        var options = options
        options.port = 0 // 随机端口，避免测试间端口冲突
        let server = EventServer(options: options)
        do {
            try server.start()
        } catch {
            ztAssertTrue(false, "server start failed: \(error)")
            return
        }
        guard let port = server.boundPort, port != 0 else {
            ztAssertTrue(false, "server did not bind")
            server.stop()
            return
        }
        defer { server.stop() }
        callback(server, "http://127.0.0.1:\(port)")
    }

    @objc func testAcceptsAndDrainsFifo() {
        withServer { server, url in
            let enqueued = DispatchSemaphore(value: 0)
            server.onEnqueued = { enqueued.signal() }
            let status = request("\(url)/event", #"{"event":"user_prompt_submit","session_id":"one"}"#)
            ztAssertEqual(enqueued.wait(timeout: .now() + 5), .success, "enqueued signal")
            ztAssertEqual(status, 204, "status")
            ztAssertEqual(server.pending, 1, "pending")
            let drained = server.drain()
            ztAssertEqual(drained.map(\.event), ["user_prompt_submit"], "drained events")
            ztAssertEqual(drained.first?.sessionId, "one", "drained session id")
            ztAssertEqual(server.pending, 0, "pending after drain")
        }
    }

    @objc func testRejectsInvalidFieldsBeforeQueueing() {
        withServer { server, url in
            ztAssertEqual(request("\(url)/event", #"{"event":"unknown"}"#), 400, "unknown event")
            ztAssertEqual(request("\(url)/event", #"{"event":"stop","prompt_preview":"\#(String(repeating: "x", count: 513))"}"#), 400, "oversized string")
            let todos = (0..<65).map { _ in #"{"content":"x"}"# }.joined(separator: ",")
            ztAssertEqual(request("\(url)/event", #"{"event":"todo_update","todos":[\#(todos)]}"#), 400, "oversized todos")
            ztAssertEqual(server.pending, 0, "pending stays 0")
        }
    }

    @objc func testHttpCompatibilityResponses() {
        withServer { _, url in
            ztAssertEqual(request("\(url)/wrong", "{}"), 404, "wrong path")
            ztAssertEqual(request("\(url)/event", "not-json"), 400, "invalid json")
            ztAssertEqual(request("\(url)/event", "[]"), 400, "array body")
            ztAssertEqual(request("\(url)/event", nil, method: "GET"), 404, "GET method")
        }
    }

    @objc func testRequestAndQueueLimits() {
        var options = EventServer.Options()
        options.maxBytes = 256
        options.maxQueue = 1
        withServer(options: options) { server, url in
            ztAssertEqual(request("\(url)/event", #"{"event":"stop"}"#), 204, "first event")
            ztAssertEqual(request("\(url)/event", #"{"event":"todo_update"}"#), 503, "queue full")
            ztAssertEqual(server.drain().map(\.event), ["stop"], "queued event kept")

            let large = #"{"event":"x","detail":"\#(String(repeating: "a", count: 257))"}"#
            ztAssertEqual(request("\(url)/event", large), 413, "oversized body")
        }
    }

    @objc func testIncompleteRequestTimesOut() {
        var options = EventServer.Options()
        options.requestTimeoutMs = 100
        withServer(options: options) { server, url in
            let status = sendIncompleteRequest("\(url)/event")
            ztAssertEqual(status, 408, "incomplete request timeout")
            ztAssertEqual(server.pending, 0, "pending stays 0")
            ztAssertEqual(request("\(url)/event", #"{"event":"todo_update"}"#), 204, "server still serving")
        }
    }

    @objc func testClientAbortIgnored() {
        withServer { server, url in
            sendAbortedRequest("\(url)/event")
            ztAssertEqual(server.pending, 0, "aborted request not queued")
            ztAssertEqual(request("\(url)/event", #"{"event":"stop"}"#), 204, "next request ok")
            ztAssertEqual(server.drain().map(\.event), ["stop"], "drain")
        }
    }

    /// 回归：consumeEvents 改为每轮 drain 上限 32 条让步主线程（对照
    /// event-server.ts MAX_EVENTS_PER_TICK），drain() 默认即该上限。
    @objc func testDrainCapsAtMaxEventsPerTick() {
        withServer { server, url in
            for i in 0..<35 {
                ztAssertEqual(
                    request("\(url)/event", #"{"event":"stop","session_id":"cap-\#(i)"}"#),
                    204, "request \(i) status")
            }
            ztAssertEqual(server.pending, 35, "all queued")
            let first = server.drain()
            ztAssertEqual(first.count, 32, "first drain caps at maxEventsPerTick")
            ztAssertEqual(server.pending, 3, "remainder pending")
            ztAssertEqual(server.drain().count, 3, "second drain takes the rest")
            ztAssertEqual(server.pending, 0, "queue empty")
        }
    }

    /// 回归：连接泄漏（2026-09-05 实测约 224 个事件后服务静默失效）。
    /// respond 的 send completion 曾以 weak 捕获连接对象，清理先于 completion
    /// 执行时 cancel 被跳过，socket 悬挂成 CLOSE_WAIT。此测试同时断言连接表
    /// 清空与进程内无 CLOSE_WAIT 残留。
    @objc func testConnectionsAreReleasedAfterResponses() {
        withServer { server, url in
            for i in 0..<30 {
                ztAssertEqual(
                    request("\(url)/event", #"{"event":"stop","session_id":"leak-\#(i)"}"#),
                    204, "request \(i) status")
            }
            // cancel 与连接表移除都是异步的，轮询到稳定。
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                let lingering = Self.closeWaitCount()
                if server.activeConnectionCount == 0 && lingering == 0 { break }
                Thread.sleep(forTimeInterval: 0.2)
            }
            ztAssertEqual(server.activeConnectionCount, 0, "connection table drained")
            ztAssertEqual(Self.closeWaitCount(), 0, "no CLOSE_WAIT sockets left behind")
        }
    }

    /// 统计本测试进程悬挂的 CLOSE_WAIT TCP socket 数（服务端与客户端连接都在本进程内）。
    private static func closeWaitCount() -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-p", "\(ProcessInfo.processInfo.processIdentifier)", "-a", "-i", "TCP", "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return 0 // lsof 不可用时跳过该断言（不影响其余测试）
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.components(separatedBy: "\n")
            .filter { $0.contains("CLOSE_WAIT") }
            .count
    }

    @objc func testSecondListenerOnOccupiedPortFails() {
        var firstOptions = EventServer.Options()
        firstOptions.port = 0 // 随机端口，避免与本机运行的 App（57310）冲突
        let first = EventServer(options: firstOptions)
        do {
            try first.start()
        } catch {
            ztAssertTrue(false, "first server start failed: \(error)")
            return
        }
        defer { first.stop() }
        guard let port = first.boundPort else {
            ztAssertTrue(false, "first server did not bind")
            return
        }

        var options = EventServer.Options()
        options.port = port
        let second = EventServer(options: options)
        var threwError = false
        do {
            try second.start()
        } catch {
            threwError = true
        }
        ztAssertTrue(threwError, "second start should throw")
        ztAssertNil(second.boundPort, "second has no port")
        ztAssertEqual(first.boundPort, port, "first still bound")
    }

    // MARK: - 原始 socket 辅助

    private func sendIncompleteRequest(_ url: String) -> Int {
        let target = URL(string: url)!
        let connection = NWConnection(
            host: NWEndpoint.Host(target.host!),
            port: NWEndpoint.Port(rawValue: UInt16(target.port ?? 80))!,
            using: .tcp
        )
        let statusCode = LockedBox<Int?>(nil)
        let done = DispatchSemaphore(value: 0)
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                let head = "POST \(target.path) HTTP/1.1\r\nHost: \(target.host!)\r\nContent-Type: application/json\r\nContent-Length: 32\r\n\r\n"
                connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
                self.receiveStatus(connection, into: statusCode) { done.signal() }
            }
        }
        connection.start(queue: .global())
        defer { connection.cancel() }
        _ = done.wait(timeout: .now() + 5)
        return statusCode.load() ?? -1
    }

    private func sendAbortedRequest(_ url: String) {
        let target = URL(string: url)!
        let connection = NWConnection(
            host: NWEndpoint.Host(target.host!),
            port: NWEndpoint.Port(rawValue: UInt16(target.port ?? 80))!,
            using: .tcp
        )
        let done = DispatchSemaphore(value: 0)
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connection.send(content: Data(#"{\"event\":"#.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                    done.signal()
                })
            }
        }
        connection.start(queue: .global())
        defer { connection.cancel() }
        _ = done.wait(timeout: .now() + 5)
    }

    private func receiveStatus(_ connection: NWConnection, into box: LockedBox<Int?>, then completion: @escaping () -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
            if let data, let text = String(data: data, encoding: .utf8), text.hasPrefix("HTTP/1.1 ") {
                let code = text.dropFirst("HTTP/1.1 ".count).prefix(3)
                box.store(Int(code))
            }
            if error != nil || box.load() != nil {
                completion()
            } else {
                self.receiveStatus(connection, into: box, then: completion)
            }
        }
    }
}

private final class LockedBox<T> {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func load() -> T {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func store(_ value: T) {
        lock.lock(); defer { lock.unlock() }
        self.value = value
    }
}
