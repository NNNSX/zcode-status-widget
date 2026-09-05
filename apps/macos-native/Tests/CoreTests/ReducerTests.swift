import Foundation
@testable import Core

/// 对照 apps/desktop/tests/reducer.test.ts 移植。
final class ReducerTests: ZTestCase {
    private func containsShow(_ effects: [ReducerEffect], kind: AttentionContent.Kind, title: String) -> Bool {
        effects.contains { effect in
            if case .showAttention(let content) = effect {
                return content.kind == kind && content.title == title
            }
            return false
        }
    }

    private func containsCancel(_ effects: [ReducerEffect], sessionId: String) -> Bool {
        effects.contains { $0 == .cancelAttention(sessionId: sessionId) }
    }

    private func displays(_ reducer: SessionReducer, _ now: TimeInterval, doneTtl: Int = 5) -> [DisplaySession] {
        reducer.displaySessions(now: now, doneTtlMinutes: doneTtl, showTodoProgress: true, showDuration: true)
    }

    @objc func testClosedRoundResetsOnNewPrompt() {
        let reducer = SessionReducer()
        let start: TimeInterval = 1_000_000

        ztAssertTrue(reducer.apply(HookEvent(event: "user_prompt_submit", sessionId: "session-1", project: "ZCode_ws", projectDir: "D:/ZCode_ws", workspaceSource: "session_root", promptPreview: "实现状态机", turnId: "turn-1"), now: start).accepted)

        let waiting = reducer.apply(HookEvent(event: "permission_request", sessionId: "session-1", lastTool: "filesystem", turnId: "turn-1"), now: start + 2_000)
        ztAssertTrue(containsShow(waiting.effects, kind: .waiting, title: "请完成审批"))

        let resumed = reducer.apply(HookEvent(event: "permission_bash", sessionId: "session-1", turnId: "turn-1"), now: start + 3_000)
        ztAssertTrue(containsCancel(resumed.effects, sessionId: "session-1"))

        let completed = reducer.apply(HookEvent(event: "stop", sessionId: "session-1", turnId: "turn-1"), now: start + 5_500)
        ztAssertTrue(containsShow(completed.effects, kind: .done, title: "本轮任务完成"))
        let done = displays(reducer, start + 5_500)
        ztAssertEqual(done[0].state, SessionState.done)
        ztAssertEqual(done[0].duration, "0:05")
        ztAssertEqual(done[0].task, "实现状态机")

        ztAssertFalse(reducer.apply(HookEvent(event: "todo_update", sessionId: "session-1", todos: [TodoItem(content: "迟到事件", status: "in_progress")], turnId: "turn-1"), now: start + 6_000).accepted)

        ztAssertTrue(reducer.apply(HookEvent(event: "user_prompt_submit", sessionId: "session-1", project: "ZCode_ws", promptPreview: "下一轮", turnId: "turn-2"), now: start + 7_000).accepted)
        let working = displays(reducer, start + 7_000)
        ztAssertEqual(working[0].state, SessionState.working)
        ztAssertEqual(working[0].task, "下一轮")
        ztAssertEqual(working[0].todoProgress, "")
        ztAssertFalse(reducer.apply(HookEvent(event: "stop", sessionId: "session-1", turnId: "turn-1"), now: start + 8_000).accepted)
    }

    @objc func testApprovalWithoutTurnIdRepeatedReminders() {
        let reducer = SessionReducer()
        let now: TimeInterval = 2_500_000
        reducer.apply(HookEvent(event: "user_prompt_submit", sessionId: "legacy-approval", turnId: "turn-1"), now: now)

        let first = reducer.apply(HookEvent(event: "permission_request", sessionId: "legacy-approval", lastTool: "filesystem"), now: now + 100)
        let repeated = reducer.apply(HookEvent(event: "permission_request", sessionId: "legacy-approval", lastTool: "filesystem"), now: now + 200)
        ztAssertTrue(first.accepted && containsShow(first.effects, kind: .waiting, title: "请完成审批"))
        ztAssertTrue(repeated.accepted && containsShow(repeated.effects, kind: .waiting, title: "请完成审批"))

        let resumed = reducer.apply(HookEvent(event: "permission_bash", sessionId: "legacy-approval"), now: now + 300)
        ztAssertTrue(containsCancel(resumed.effects, sessionId: "legacy-approval"))

        let afterResume = reducer.apply(HookEvent(event: "permission_request", sessionId: "legacy-approval", lastTool: "filesystem"), now: now + 400)
        ztAssertTrue(afterResume.accepted && containsShow(afterResume.effects, kind: .waiting, title: "请完成审批"))
    }

    @objc func testBashApprovalAndToolFailures() {
        let reducer = SessionReducer()
        let now: TimeInterval = 2_000_000
        reducer.apply(HookEvent(event: "user_prompt_submit", sessionId: "bash-session", project: "terminal", turnId: "turn"), now: now)
        reducer.apply(HookEvent(event: "tool_failure", sessionId: "bash-session", errorPreview: "transient failure", turnId: "turn"), now: now + 100)
        reducer.apply(HookEvent(event: "permission_request", sessionId: "bash-session", lastTool: "Bash", turnId: "turn"), now: now + 200)
        ztAssertEqual(displays(reducer, now + 200)[0].state, SessionState.working)
    }

    @objc func testLateTimestampsAndNoBashInference() {
        let reducer = SessionReducer()
        let start: TimeInterval = 4_000_000
        reducer.apply(HookEvent(event: "user_prompt_submit", sessionId: "ordered", turnId: "first", ts: 20), now: start)
        reducer.apply(HookEvent(event: "permission_request", sessionId: "ordered", lastTool: "Bash", turnId: "first", ts: 21), now: start + 100)
        let nextRound = reducer.apply(HookEvent(event: "user_prompt_submit", sessionId: "ordered", turnId: "second", ts: 30), now: start + 200)
        let latePrompt = reducer.apply(HookEvent(event: "user_prompt_submit", sessionId: "ordered", turnId: "first", ts: 25), now: start + 300)
        let missingToolPermission = reducer.apply(HookEvent(event: "permission_request", sessionId: "ordered", turnId: "second", ts: 31), now: start + 400)

        ztAssertTrue(nextRound.accepted)
        ztAssertFalse(latePrompt.accepted)
        ztAssertTrue(containsShow(missingToolPermission.effects, kind: .waiting, title: "请完成审批"))
        ztAssertEqual(displays(reducer, start + 400)[0].state, SessionState.waiting)
    }

    @objc func testTodoUpdateResumesWaiting() {
        let reducer = SessionReducer()
        let now: TimeInterval = 5_000_000
        reducer.apply(HookEvent(event: "user_prompt_submit", sessionId: "todo-resume", turnId: "turn"), now: now)
        reducer.apply(HookEvent(event: "permission_request", sessionId: "todo-resume", turnId: "turn"), now: now + 100)
        let resumed = reducer.apply(HookEvent(event: "todo_update", sessionId: "todo-resume", todos: [], turnId: "turn"), now: now + 200)
        ztAssertTrue(containsCancel(resumed.effects, sessionId: "todo-resume"))
        ztAssertEqual(displays(reducer, now + 200)[0].state, SessionState.working)
    }

    @objc func testStopRequiresVerifiedRound() {
        let reducer = SessionReducer()
        let start: TimeInterval = 6_000_000

        ztAssertFalse(reducer.apply(HookEvent(event: "stop", sessionId: "missing"), now: start).accepted)
        ztAssertTrue(displays(reducer, start).isEmpty)

        reducer.apply(HookEvent(event: "user_prompt_submit", sessionId: "identity", turnId: "turn-a"), now: start + 100)
        ztAssertFalse(reducer.apply(HookEvent(event: "stop", sessionId: "identity"), now: start + 200).accepted)
        ztAssertEqual(displays(reducer, start + 200)[0].state, SessionState.working)

        reducer.apply(HookEvent(event: "user_prompt_submit", sessionId: "identity", promptPreview: "缺少轮次标识的新任务"), now: start + 300)
        ztAssertTrue(reducer.apply(HookEvent(event: "todo_update", sessionId: "identity", turnId: "turn-a"), now: start + 400).accepted)
        ztAssertFalse(reducer.apply(HookEvent(event: "stop", sessionId: "identity", turnId: "turn-a"), now: start + 500).accepted)
        let display = displays(reducer, start + 500)[0]
        ztAssertEqual(display.state, SessionState.working)
        ztAssertEqual(display.task, "缺少轮次标识的新任务")
    }

    @objc func testNoTurnPrompts() {
        let reducer = SessionReducer()
        let now: TimeInterval = 7_000_000
        ztAssertTrue(reducer.apply(HookEvent(event: "user_prompt_submit", sessionId: "legacy", promptPreview: "兼容任务"), now: now).accepted)
        ztAssertTrue(reducer.apply(HookEvent(event: "permission_request", sessionId: "legacy", lastTool: "filesystem"), now: now + 100).accepted)
        ztAssertEqual(displays(reducer, now + 100)[0].state, SessionState.waiting)
    }

    @objc func testRootWorkspaceAndDoneTtl() {
        let reducer = SessionReducer()
        let now: TimeInterval = 3_000_000
        reducer.apply(HookEvent(event: "user_prompt_submit", sessionId: "workspace-session", project: "temporary-folder", projectDir: "D:/temporary-folder", workspaceSource: "event_dir", turnId: "turn"), now: now)
        reducer.apply(HookEvent(
            event: "todo_update",
            sessionId: "workspace-session",
            project: "ZCode_ws",
            projectDir: "D:/ZCode_ws",
            workspaceSource: "session_root",
            todos: [TodoItem(content: "实施", status: "completed"), TodoItem(content: "验证", status: "pending")],
            turnId: "turn"
        ), now: now + 100)
        reducer.apply(HookEvent(event: "stop", sessionId: "workspace-session", turnId: "turn"), now: now + 1_000)

        let display = displays(reducer, now + 1_000)[0]
        ztAssertEqual(display.workspace, "ZCode_ws")
        ztAssertEqual(display.todoProgress, "1/2")
        ztAssertEqual(display.duration, "0:01")
        ztAssertTrue(displays(reducer, now + 61_001, doneTtl: 1).isEmpty)
    }

    @objc func testWorkspaceLabelDeduplication() {
        let reducer = SessionReducer()
        let now: TimeInterval = 8_000_000
        reducer.apply(HookEvent(event: "user_prompt_submit", sessionId: "s1", project: "proj", projectDir: "/w/proj", turnId: "t1"), now: now)
        reducer.apply(HookEvent(event: "user_prompt_submit", sessionId: "s2", project: "proj", projectDir: "/other/proj", turnId: "t2"), now: now + 10)
        let sessions = reducer.displaySessions(now: now + 10, doneTtlMinutes: 5, showTodoProgress: false, showDuration: false)
        let workspaces = Set(sessions.map(\.workspace))
        ztAssertEqual(workspaces.count, 2)
        ztAssertTrue(workspaces.contains("proj"))
        ztAssertTrue(workspaces.contains("proj·2"))
    }
}

/// 对照 reducer.test.ts 的 configuration normalization 部分。
final class ConfigNormalizationTests: ZTestCase {
    @objc func testResetPositionOnlyResetsLocation() {
        let config = AppConfig.normalized(input: AppConfigInput(
            corner: .topLeft,
            marginX: 90,
            marginY: 120,
            opacity: 65,
            showDuration: false,
            panelWidth: 560,
            doneTtlMinutes: 12,
            attentionMode: .cornerOverlay
        ))
        let reset = config.resettingPosition()
        ztAssertEqual(reset.corner, PanelCorner.bottomRight)
        ztAssertEqual(reset.marginX, 14)
        ztAssertEqual(reset.marginY, 52)
        ztAssertEqual(reset.displayId, "")
        ztAssertEqual(reset.opacity, 65)
        ztAssertEqual(reset.panelWidth, 560)
        ztAssertEqual(reset.showDuration, false)
        ztAssertEqual(reset.doneTtlMinutes, 12)
        ztAssertEqual(reset.attentionMode, AttentionMode.cornerOverlay)
    }

    @objc func testOutOfBoundsValuesClamp() {
        let config = AppConfig.normalized(input: AppConfigInput(
            opacity: 120,
            showDuration: false,
            panelWidth: 100,
            doneTtlMinutes: 99,
            attentionDurationMs: 10
        ))
        ztAssertEqual(config.opacity, 100)
        ztAssertEqual(config.panelWidth, 220)
        ztAssertEqual(config.doneTtlMinutes, 30)
        ztAssertEqual(config.attentionDurationMs, 800)
        ztAssertEqual(config.showDuration, false)
        ztAssertEqual(config.corner, PanelCorner.bottomRight)
    }

    @objc func testMarginsNonNegativeAndDisplayIdTrimmed() {
        let config = AppConfig.normalized(input: AppConfigInput(marginX: -5, marginY: 0, displayId: " 42 "))
        ztAssertEqual(config.marginX, 0)
        ztAssertEqual(config.marginY, 0)
        ztAssertEqual(config.displayId, "42")
    }

    @objc func testSettingsJsonRoundTrip() {
        let config = AppConfig.normalized(input: AppConfigInput(opacity: 75, attentionMode: .panelPulse))
        do {
            let data = try JSONEncoder().encode(config)
            let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
            ztAssertEqual(decoded, config, "settings json round trip")
        } catch {
            ztAssertTrue(false, "settings json round trip failed: \(error)")
        }
    }
}
