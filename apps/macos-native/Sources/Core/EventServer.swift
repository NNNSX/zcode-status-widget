import Darwin
import Foundation

/// 回环事件服务器（对照 src/main/event-server.ts）。
/// 只绑 127.0.0.1（POSIX socket 显式 bind——Network.framework 的 NWListener
/// 无法指定监听地址，requiredLocalEndpoint 对 listener 一律 EINVAL），仅接受
/// POST /event；全部校验规则与状态码逐条照搬：404（路径/方法）、400（头/JSON/
/// 字段非法）、408（请求超时）、413（超长）、503（队列满）、204（入队成功）。
/// 所有响应 Content-Length: 0 并 Connection: close。全部可变状态（listenFd/
/// connections/eventQueue/stopped）均在 stateQueue 上访问。
public final class EventServer: @unchecked Sendable {
    public struct Options: Sendable {
        public var host: String = "127.0.0.1"
        public var port: UInt16 = 57310
        public var maxBytes = 64 * 1024
        public var maxQueue = 256
        public var maxEventsPerTick = 32
        public var requestTimeoutMs: Int = 30_000
        public var stopTimeoutMs: Int = 1_000

        public init() {}
    }

    public enum ServerError: Error, CustomStringConvertible {
        case bindFailed(String)
        public var description: String {
            switch self {
            case .bindFailed(let reason): return "事件服务器绑定失败：\(reason)"
            }
        }
    }

    private let options: Options
    private let stateQueue = DispatchQueue(label: "zcode-status-light.event-server")
    private var listenFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]
    private var eventQueue: [HookEvent] = []
    private var stopped = false

    /// 入队回调（在服务器串行队列上调用；消费方自行切线程）。
    public var onEnqueued: (@Sendable () -> Void)?

    /// 绑定成功后的地址（端口 0 时为实际分配端口）。
    public private(set) var boundPort: UInt16?

    public init(options: Options = Options()) {
        self.options = options
    }

    // MARK: - 生命周期

    public func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ServerError.bindFailed("socket(): \(Self.errnoMessage)")
        }
        // SO_REUSEADDR 对照 Node/libuv 默认：崩溃重启（TIME_WAIT 残留）可重新
        // 绑定，但不允许两个活跃 listener 抢同端口（双实例仍 EADDRINUSE）。
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = options.port.bigEndian
        var ipv4 = in_addr()
        guard inet_pton(AF_INET, options.host, &ipv4) == 1 else {
            close(fd)
            throw ServerError.bindFailed("无效监听地址：\(options.host)")
        }
        address.sin_addr = ipv4
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let message = "bind \(options.host):\(options.port)：\(Self.errnoMessage)"
            close(fd)
            throw ServerError.bindFailed(message)
        }
        guard listen(fd, SOMAXCONN) == 0 else {
            let message = "listen()：\(Self.errnoMessage)"
            close(fd)
            throw ServerError.bindFailed(message)
        }
        // 非阻塞 accept：可读事件循环里 accept 到 EAGAIN 必须立即返回。
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var bound = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &boundLength)
            }
        }
        boundPort = UInt16(bigEndian: bound.sin_port)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: stateQueue)
        source.setEventHandler { [weak self] in self?.acceptConnections() }
        source.setCancelHandler { [fd] in close(fd) }
        source.resume()
        stateQueue.sync {
            listenFd = fd
            acceptSource = source
        }
    }

    public func stop() {
        let semaphore = DispatchSemaphore(value: 0)
        stateQueue.async { [weak self] in
            guard let self else {
                semaphore.signal()
                return
            }
            self.stopped = true
            self.acceptSource?.cancel()
            self.acceptSource = nil
            self.listenFd = -1
            for (_, connection) in self.connections {
                connection.cancel()
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + .milliseconds(options.stopTimeoutMs))
    }

    private static var errnoMessage: String {
        String(cString: strerror(errno))
    }

    /// accept 到 EAGAIN 为止（可读事件只触发一次 handler，pending 队列要清空）。
    private func acceptConnections() {
        while true {
            let fd = accept(listenFd, nil, nil)
            if fd < 0 {
                return
            }
            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            let http = HTTPConnection(
                fd: fd,
                maxBytes: options.maxBytes,
                requestTimeoutMs: options.requestTimeoutMs
            ) { [weak self] payload, respond in
                guard let self else {
                    respond(503)
                    return
                }
                // 本回调已在 stateQueue 上执行（连接与 listener 同队列），直接访问状态。
                let outcome = self.enqueue(payload)
                respond(outcome.status)
                if outcome.enqueued {
                    self.onEnqueued?()
                }
            }
            connections[ObjectIdentifier(http)] = http
            http.onClosed = { [weak self, weak http] in
                guard let self, let http else { return }
                let key = ObjectIdentifier(http)
                self.stateQueue.async { [weak self] in
                    self?.connections.removeValue(forKey: key)
                }
            }
            http.start(queue: stateQueue)
        }
    }

    // MARK: - 队列

    /// 入队判定；调用方必须已在 stateQueue 上。
    private func enqueue(_ payload: [String: Any]?) -> (status: Int, enqueued: Bool) {
        if let json = payload,
           let event = EventSanitizer.sanitize(json) {
            if eventQueue.count >= options.maxQueue {
                return (503, false)
            }
            eventQueue.append(event)
            return (204, true)
        }
        return (400, false)
    }

    public var pending: Int {
        stateQueue.sync { eventQueue.count }
    }

    /// 活跃连接数（连接表大小；测试可观测，验证连接处理完全部移出）。
    var activeConnectionCount: Int {
        stateQueue.sync { connections.count }
    }

    public func drain(_ limit: Int? = nil) -> [HookEvent] {
        stateQueue.sync {
            let count = max(0, min(limit ?? options.maxEventsPerTick, eventQueue.count))
            let batch = Array(eventQueue.prefix(count))
            eventQueue.removeFirst(count)
            return batch
        }
    }
}

/// 单连接上的最小 HTTP/1.1 解析（POSIX 非阻塞 socket 传输）。
/// 请求行 + Content-Length 头 + 精确长度的 body；不支持 chunked。
private final class HTTPConnection: @unchecked Sendable {
    private let fd: Int32
    private let maxBytes: Int
    private let requestTimeoutMs: Int
    private let handler: (@Sendable ([String: Any]?, @escaping (Int) -> Void) -> Void)

    private var buffer = Data()
    private var parsedHeader = false
    private var method = ""
    private var path = ""
    private var contentLength: Int?
    private var timeoutTimer: DispatchSourceTimer?
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var outgoing = Data()
    private var finished = false
    private var socketClosed = false
    private let closeLock = NSLock()
    /// 服务器串行队列（读写/超时/写事件全部同队列，天然互斥）。
    private var serverQueue: DispatchQueue?

    var onClosed: (@Sendable () -> Void)?

    init(
        fd: Int32,
        maxBytes: Int,
        requestTimeoutMs: Int,
        handler: @escaping @Sendable ([String: Any]?, @escaping (Int) -> Void) -> Void
    ) {
        self.fd = fd
        self.maxBytes = maxBytes
        self.requestTimeoutMs = requestTimeoutMs
        self.handler = handler
    }

    func start(queue: DispatchQueue) {
        serverQueue = queue
        scheduleTimeout(queue: queue)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.resume()
        readSource = source
    }

    func cancel() {
        finishWithoutResponse()
    }

    private func scheduleTimeout(queue: DispatchQueue) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(requestTimeoutMs))
        timer.setEventHandler { [weak self] in
            guard let self, !self.finished else { return }
            self.respond(status: 408)
        }
        timer.resume()
        timeoutTimer = timer
    }

    private func readAvailable() {
        guard !finished else { return }
        var chunk = [UInt8](repeating: 0, count: maxBytes + 4096)
        let received = read(fd, &chunk, chunk.count)
        if received > 0 {
            buffer.append(contentsOf: chunk[0..<received])
            process()
        } else if received == 0 {
            // 客户端提前断开：关闭并移出连接表，不写状态码（静默结束）。
            finishWithoutResponse()
        } else if errno != EAGAIN && errno != EWOULDBLOCK {
            finishWithoutResponse()
        }
    }

    private func process() {
        guard !finished else { return }
        if !parsedHeader {
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > maxBytes {
                    respond(status: 413)
                }
                return
            }
            let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
            guard let headerText = String(data: headerData, encoding: .utf8) else {
                respond(status: 400)
                return
            }
            let lines = headerText.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else {
                respond(status: 400)
                return
            }
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2 else {
                respond(status: 400)
                return
            }
            method = String(parts[0]).uppercased()
            path = String(parts[1])
            // 仅 POST /event（event-server.ts:191-195，方法/路径检查先于 Content-Length）。
            guard method == "POST", path == "/event" else {
                respond(status: 404)
                return
            }
            contentLength = headerContentLength(lines: lines)
            if let length = contentLength, length >= 0, length <= maxBytes {
                // 合法
            } else if let declaredLength = contentLength, declaredLength > maxBytes {
                respond(status: 413)
                return
            } else {
                // 缺失或负数 → 400。
                respond(status: 400)
                return
            }
            parsedHeader = true
            buffer.removeSubrange(buffer.startIndex..<headerEnd.upperBound)
        }
        guard let length = contentLength else { return }
        if buffer.count > maxBytes {
            respond(status: 413)
            return
        }
        guard buffer.count >= length else { return }
        let body = buffer.prefix(length)
        let payload: [String: Any]?
        if let json = try? JSONSerialization.jsonObject(with: Data(body)) {
            payload = json as? [String: Any]
        } else {
            payload = nil
        }
        timeoutTimer?.cancel()
        handler(payload) { [weak self] status in
            self?.respond(status: status)
        }
    }

    private func headerContentLength(lines: [String]) -> Int? {
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let raw = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                guard let value = Int(raw), raw.allSatisfy({ $0.isNumber }) else { return nil }
                return value
            }
        }
        return nil
    }

    private func respond(status: Int) {
        guard beginFinish() else { return }
        timeoutTimer?.cancel()
        let reason: String
        switch status {
        case 204: reason = "No Content"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 408: reason = "Request Timeout"
        case 413: reason = "Payload Too Large"
        case 503: reason = "Service Unavailable"
        default: reason = "Error"
        }
        outgoing = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        flushOutgoing()
    }

    /// 对端断开/外部停止：不写任何响应，直接收尾。
    private func finishWithoutResponse() {
        guard beginFinish() else { return }
        timeoutTimer?.cancel()
        closeSocketOnce()
        teardown()
    }

    private func flushOutgoing() {
        while !outgoing.isEmpty {
            let sent = outgoing.withUnsafeBytes { buffer in
                send(fd, buffer.baseAddress, buffer.count, 0)
            }
            if sent > 0 {
                outgoing.removeFirst(sent)
                continue
            }
            if sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                // 发送缓冲满：挂可写事件继续；全部发出后才关 socket。
                let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: serverQueue ?? .global())
                source.setEventHandler { [weak self] in
                    self?.writeSource?.cancel()
                    self?.writeSource = nil
                    self?.flushOutgoing()
                }
                source.resume()
                writeSource = source
                return
            }
            // 发送失败（对端已重置等）：直接收尾。
            closeSocketOnce()
            teardown()
            return
        }
        // 数据已入内核发送缓冲，close 由内核继续投递（Connection: close）。
        closeSocketOnce()
        teardown()
    }

    /// 首次收尾返回 true；保证 respond/断开/超时/停止只走一条路径。
    private func beginFinish() -> Bool {
        closeLock.lock()
        let alreadyFinished = finished
        finished = true
        closeLock.unlock()
        return !alreadyFinished
    }

    private func closeSocketOnce() {
        closeLock.lock()
        let alreadyClosed = socketClosed
        socketClosed = true
        closeLock.unlock()
        guard !alreadyClosed else { return }
        writeSource?.cancel()
        writeSource = nil
        readSource?.cancel()
        readSource = nil
        close(fd)
    }

    private func teardown() {
        timeoutTimer?.cancel()
        onClosed?()
    }
}
