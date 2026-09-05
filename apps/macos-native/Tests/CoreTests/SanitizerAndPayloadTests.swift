import Foundation
import SQLite3
@testable import Core

/// 对照 event-server.test.ts 的字段校验语义。
final class EventSanitizerTests: ZTestCase {
    @objc func testValidEventPasses() {
        let event = EventSanitizer.sanitize([
            "event": "user_prompt_submit",
            "session_id": "one",
            "todos": [["content": "a", "status": "pending"]],
            "ts": 123.5,
        ])
        ztAssertEqual(event?.event, "user_prompt_submit")
        ztAssertEqual(event?.sessionId, "one")
        ztAssertEqual(event?.todos?.count, 1)
        ztAssertEqual(event?.ts, 123.5)
    }

    @objc func testUnknownTokenRejectedCaseInsensitive() {
        ztAssertNil(EventSanitizer.sanitize(["event": "unknown"]))
        ztAssertEqual(EventSanitizer.sanitize(["event": "USER_PROMPT_SUBMIT"])?.event, "user_prompt_submit")
        ztAssertEqual(EventSanitizer.sanitize(["event": " stop "])?.event, "stop")
    }

    @objc func testOversizedStringRejected() {
        ztAssertNil(EventSanitizer.sanitize(["event": "stop", "prompt_preview": String(repeating: "x", count: 513)]))
        ztAssertNotNil(EventSanitizer.sanitize(["event": "stop", "prompt_preview": String(repeating: "x", count: 512)]))
        ztAssertNil(EventSanitizer.sanitize(["event": "stop", "prompt_preview": 42]))
    }

    @objc func testOversizedTodosRejected() {
        let tooMany = (0..<65).map { _ in ["content": "x"] as [String: Any] }
        ztAssertNil(EventSanitizer.sanitize(["event": "todo_update", "todos": tooMany]))
        let ok = (0..<64).map { _ in ["content": "x"] as [String: Any] }
        ztAssertNotNil(EventSanitizer.sanitize(["event": "todo_update", "todos": ok]))
        ztAssertNil(EventSanitizer.sanitize(["event": "todo_update", "todos": [["content": "x", "status": String(repeating: "s", count: 65)]]]))
        ztAssertNil(EventSanitizer.sanitize(["event": "todo_update", "todos": ["not-an-object"]]))
        ztAssertNil(EventSanitizer.sanitize(["event": "todo_update", "todos": "nope"]))
    }

    @objc func testTimestampMustBeFiniteNumberNotBool() {
        ztAssertNil(EventSanitizer.sanitize(["event": "stop", "ts": true]))
        ztAssertNotNil(EventSanitizer.sanitize(["event": "stop", "ts": 12]))
        ztAssertNil(EventSanitizer.sanitize(["event": "stop", "ts": "12"]))
    }
}

/// helper 纯逻辑（对照 ZCodeStatusHook.cs）。
final class HookPayloadTests: ZTestCase {
    @objc func testClipCollapsesWhitespaceAndTruncates() {
        ztAssertEqual(HookPayload.clip("  a \n b\t c  ", 20), "a b c")
        let long = String(repeating: "a", count: 70)
        let clipped = HookPayload.clip(long, 60)
        ztAssertEqual(clipped.count, 60)
        ztAssertTrue(clipped.hasSuffix("..."))
        ztAssertEqual(String(clipped.dropLast(3)), String(repeating: "a", count: 57))
    }

    @objc func testStripTemplateVars() {
        ztAssertEqual(HookPayload.stripTemplateVars("${CLAUDE_SESSION_ID}"), "")
        ztAssertEqual(HookPayload.stripTemplateVars("abc${ZCODE_PROJECT_DIR}def"), "abcdef")
        ztAssertEqual(HookPayload.stripTemplateVars("abc${"), "abc${")
    }

    @objc func testWorkspaceNameLastPathComponent() {
        ztAssertEqual(HookPayload.workspaceName(fromDirectory: "/Users/x/work/ZCode_ws"), "ZCode_ws")
        ztAssertEqual(HookPayload.workspaceName(fromDirectory: "D:\\a\\b\\"), "b")
        ztAssertEqual(HookPayload.workspaceName(fromDirectory: "  "), "ZCode")
    }

    @objc func testTodoHolderOrder() {
        let topOnly: [String: Any] = ["todos": [["content": "top", "status": "pending"]]]
        ztAssertEqual(HookPayload.extractTodos(from: topOnly), [["content": "top", "status": "pending"]])

        let nested: [String: Any] = [
            "todos": [["content": "ignored", "status": "pending"]],
            "tool_input": ["todos": [["activeForm": "from-tool-input"]]],
        ]
        let extracted = HookPayload.extractTodos(from: nested)
        ztAssertEqual(extracted.first?["content"], "from-tool-input")
        ztAssertEqual(extracted.first?["status"], "pending")

        let messageHolder: [String: Any] = ["message": ["todos": [["subject": "from-message", "status": "completed"]]]]
        ztAssertEqual(HookPayload.extractTodos(from: messageHolder).first?["content"], "from-message")

        ztAssertTrue(HookPayload.extractTodos(from: ["todos": "not-array"]).isEmpty)
    }

    @objc func testCurrentTaskFirstInProgress() {
        let todos: [[String: String]] = [
            ["content": "done-item", "status": "completed"],
            ["content": "active-item", "status": "in_progress"],
            ["content": "later", "status": "in_progress"],
        ]
        ztAssertEqual(HookPayload.extractCurrentTask(from: todos), "active-item")
        ztAssertEqual(HookPayload.extractCurrentTask(from: []), "")
    }

    @objc func testTurnIdThreeLayersAndClamp() {
        ztAssertEqual(HookPayload.extractTurnId(from: ["turn_id": "top"]), "top")
        ztAssertEqual(HookPayload.extractTurnId(from: ["turnId": "camel"]), "camel")
        ztAssertEqual(HookPayload.extractTurnId(from: ["tool_input": ["turn_id": "nested"]]), "nested")
        ztAssertEqual(HookPayload.extractTurnId(from: ["message": ["turnId": "deep"]]), "deep")
        let long = String(repeating: "t", count: 200)
        ztAssertEqual(HookPayload.extractTurnId(from: ["turn_id": long]).count, 128)
    }

    @objc func testErrorExtractionToolResponseFirst() {
        ztAssertEqual(HookPayload.extractError(from: ["tool_response": ["error": "boom"]]), "boom")
        ztAssertEqual(HookPayload.extractError(from: ["tool_response": ["stderr": "stderr-msg"]]), "stderr-msg")
        ztAssertEqual(HookPayload.extractError(from: ["tool_response": "raw-string"]), "raw-string")
        ztAssertEqual(HookPayload.extractError(from: ["error": "top-level"]), "top-level")
        ztAssertEqual(HookPayload.extractError(from: [:]), "")
    }

    @objc func testPayloadShape() {
        let payload = HookPayload.buildPayload(
            token: "STOP",
            sessionId: "sess-1",
            projectDirectory: "/tmp/proj",
            workspaceDirectory: "/tmp/root",
            data: ["prompt": "hello"]
        )
        ztAssertEqual(payload["event"] as? String, "stop")
        ztAssertEqual(payload["session_id"] as? String, "sess-1")
        ztAssertEqual(payload["project"] as? String, "root")
        ztAssertEqual(payload["workspace_source"] as? String, "session_root")
        ztAssertEqual(payload["workspace_dir"] as? String, "/tmp/root")
        ztAssertEqual(payload["prompt_preview"] as? String, "hello")
        if let ts = payload["ts"] as? Double {
            ztAssertGreaterThan(ts, 1_700_000_000, "payload ts")
        } else {
            ztAssertTrue(false, "payload ts missing")
        }

        let eventDir = HookPayload.buildPayload(
            token: "stop",
            sessionId: "sess-1",
            projectDirectory: "/tmp/proj",
            workspaceDirectory: nil,
            data: [:]
        )
        ztAssertEqual(eventDir["workspace_source"] as? String, "event_dir")
        ztAssertNil(eventDir["workspace_dir"])
        ztAssertEqual(eventDir["project"] as? String, "proj")
    }

    @objc func testDecodeInputBomEmptyInvalid() {
        ztAssertEqual(HookPayload.decodeInput(Data("{\"a\":1}".utf8))?["a"] as? Int, 1)
        ztAssertEqual(HookPayload.decodeInput(Data([0xEF, 0xBB, 0xBF]) + Data("{\"a\":1}".utf8))?["a"] as? Int, 1)
        ztAssertNotNil(HookPayload.decodeInput(Data("   ".utf8)))
        ztAssertNil(HookPayload.decodeInput(Data("[]".utf8)))
        ztAssertNil(HookPayload.decodeInput(Data([0xFF, 0xFE, 0x00])))
        ztAssertNil(HookPayload.decodeInput(Data("not json".utf8)))
    }

    @objc func testSqliteAncestry() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hook-payload-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            ztAssertTrue(false, "temp dir failed: \(error)")
            return
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let databasePath = directory.appendingPathComponent("db.sqlite").path

        do {
            try execute(databasePath) { db in
                sqlite3_exec(db, "CREATE TABLE session (id TEXT PRIMARY KEY, directory TEXT NOT NULL, parent_id TEXT)", nil, nil, nil)
                sqlite3_exec(db, "INSERT INTO session (id, parent_id, directory) VALUES ('child', 'mid', '/w/mid/child'), ('mid', 'root', '/w/root'), ('root', NULL, '/w/root-project')", nil, nil, nil)
            }
        } catch {
            ztAssertTrue(false, "seed db failed: \(error)")
            return
        }

        ztAssertEqual(HookPayload.rootWorkspaceDirectory(sessionId: "child", databasePath: databasePath), "/w/root-project", "child ancestry")
        ztAssertEqual(HookPayload.rootWorkspaceDirectory(sessionId: "root", databasePath: databasePath), "/w/root-project", "root ancestry")
        ztAssertNil(HookPayload.rootWorkspaceDirectory(sessionId: "missing", databasePath: databasePath), "missing session")
        ztAssertNil(HookPayload.rootWorkspaceDirectory(sessionId: "child", databasePath: "/nonexistent.sqlite"), "missing database")

        do {
            try execute(databasePath) { db in
                sqlite3_exec(db, "INSERT INTO session (id, parent_id, directory) VALUES ('a', 'b', '/w/a'), ('b', 'a', '/w/b')", nil, nil, nil)
            }
        } catch {
            ztAssertTrue(false, "cycle seed failed: \(error)")
            return
        }
        ztAssertNil(HookPayload.rootWorkspaceDirectory(sessionId: "a", databasePath: databasePath), "cycle detection")

        do {
            try execute(databasePath) { db in
                var insert = "INSERT INTO session (id, parent_id, directory) VALUES ('d0', NULL, '/w/deep')"
                for index in 1...20 {
                    insert += ", ('d\(index)', 'd\(index - 1)', '/w/d\(index)')"
                }
                sqlite3_exec(db, insert, nil, nil, nil)
            }
        } catch {
            ztAssertTrue(false, "deep chain seed failed: \(error)")
            return
        }
        ztAssertNil(HookPayload.rootWorkspaceDirectory(sessionId: "d20", databasePath: databasePath), "chain over 16 levels")
        ztAssertEqual(HookPayload.rootWorkspaceDirectory(sessionId: "d15", databasePath: databasePath), "/w/deep", "chain within 16 levels")
    }

    private func execute(_ path: String, _ body: (OpaquePointer) -> Void) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(db) }
        body(db)
    }
}
