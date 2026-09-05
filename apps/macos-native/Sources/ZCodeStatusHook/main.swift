import Foundation
import Core

// ZCodeStatusHook — macOS hook helper（对照 apps/hook-helper/ZCodeStatusHook.cs）。
// 行为总则：stdout 恒无输出；任何异常静默吞掉退出；绝不阻塞 ZCode。

setvbuf(stdout, nil, _IONBF, 0)

private func expand(_ arguments: [String], _ index: Int) -> String {
    guard index >= 0, index < arguments.count else { return "" }
    let raw = arguments[index]
    guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
    return HookPayload.stripTemplateVars(raw).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func eventPort() -> UInt16 {
    guard let raw = ProcessInfo.processInfo.environment["ZCODE_STATUS_PORT"],
          let port = UInt16(raw), (1...65535).contains(port) else { return 57310 }
    return port
}

private func send(payload: [String: Any], port: UInt16) {
    guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
    var request = URLRequest(
        url: URL(string: "http://127.0.0.1:\(port)/event")!,
        cachePolicy: .reloadIgnoringLocalCacheData,
        timeoutInterval: 0.5
    )
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = body

    for attempt in 0..<2 {
        if attempt > 0 {
            Thread.sleep(forTimeInterval: 0.15)
        }
        if postSynchronously(request) { return }
    }
}

private func postSynchronously(_ request: URLRequest) -> Bool {
    var result = false
    let semaphore = DispatchSemaphore(value: 0)
    let task = URLSession.shared.dataTask(with: request) { _, response, _ in
        if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
            result = true
        }
        semaphore.signal()
    }
    task.resume()
    let waitResult = semaphore.wait(timeout: .now() + 5.0)
    if waitResult == .timedOut {
        task.cancel()
    }
    return result
}

private func main() {
    let arguments = CommandLine.arguments
    let token = (arguments.count > 1 ? arguments[1] : "").lowercased()
    let sessionId = expand(arguments, 2)
    var projectDirectory = expand(arguments, 3)
    let databasePath = expand(arguments, 4)

    if projectDirectory.isEmpty {
        let environment = ProcessInfo.processInfo.environment
        projectDirectory = environment["ZCODE_PROJECT_DIR"] ?? environment["CLAUDE_PROJECT_DIR"] ?? ""
    }

    var data: [String: Any] = [:]
    if isatty(fileno(stdin)) == 0 {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard input.count <= HookPayload.maxInputBytes else { return }
        guard let decoded = HookPayload.decodeInput(input) else { return }
        data = decoded
    }

    let workspaceDirectory = HookPayload.rootWorkspaceDirectory(
        sessionId: sessionId,
        databasePath: databasePath
    )
    let payload = HookPayload.buildPayload(
        token: token,
        sessionId: sessionId,
        projectDirectory: projectDirectory,
        workspaceDirectory: workspaceDirectory,
        data: data
    )
    send(payload: payload, port: eventPort())
}

// 一切异常吞掉（cs:67-70）。
main()
