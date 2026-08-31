# -*- coding: utf-8 -*-
"""会话排序 / 状态时长 / hook 重试 的回归测试。

需要独占场景：先停掉运行中的悬浮窗 exe（本测试创建 Widget 但不占端口）。
用法: python test_session_display.py
"""
import os
import sys
import threading
import time
from pathlib import Path
from unittest import mock
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PROJECT_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(PROJECT_ROOT))
import tkinter as tk

import hook_handler  # noqa: E402
import widget as W   # noqa: E402

W.PORT = 0  # 全程使用随机临时端口，不影响正在运行的生产实例


def inject(win, sid, project, turn_id=""):
    win.apply_event({"session_id": sid, "event": "user_prompt_submit",
                     "project": project, "project_dir": "D:/" + sid,
                     "prompt_preview": "任务" + sid, "todos": [],
                     "current_task": "", "error_preview": "",
                     "turn_id": turn_id, "ts": time.time()})


def main():
    root = tk.Tk()
    win = W.Widget(root)
    ok = True

    # ---- 1) 最近活跃的会话排在最上面 ----
    inject(win, "a", "项目A")
    inject(win, "b", "项目B")
    inject(win, "c", "项目C")
    # Windows time.time() 粒度 ~15ms，连续事件时间戳可能相同；
    # 排序逻辑用显式时间戳验证（真实场景事件间隔远大于粒度）
    now = time.time()
    win.sessions["a"]["updated_at"] = now - 40
    win.sessions["b"]["updated_at"] = now - 20
    win.sessions["c"]["updated_at"] = now
    order1 = [s["project"] for s in win.visible_sessions()]
    inject(win, "a", "项目A")   # A 重新活跃 → 应顶到最上面
    order2 = [s["project"] for s in win.visible_sessions()]
    want1, want2 = ["项目C", "项目B", "项目A"], ["项目A", "项目C", "项目B"]
    for got, want, tag in ((order1, want1, "初始序"), (order2, want2, "A活跃后")):
        if got != want:
            print("1) FAIL %s: %s != %s" % (tag, got, want))
            ok = False
    print("1) 最近活跃排序: OK" if ok else "1) FAIL")

    # ---- 2) 状态持续时长：无清单时右列显示 m:ss，悬停里也有 ----
    s = win.sessions["a"]
    s["todos"] = []
    s["state"] = "working"
    s["state_since"] = time.time() - 95.5   # .5 余量抵消毫秒截断
    s["updated_at"] = time.time()
    win.render()
    root.update()
    row = win.rows[id(s)]
    txt = row["lab_n"].cget("text")
    if txt != "1:35":
        print("2) FAIL 行内时长: %r != '1:35'" % txt)
        ok = False
    else:
        print("2) 行内状态时长: OK")

    # ---- 3) 状态切换时刷新 state_since ----
    t_working = s["state_since"]
    win.apply_event({"session_id": "a", "event": "stop", "ts": time.time()})
    t_done = s["state_since"]
    if s["state"] != "done" or t_done < t_working:
        print("3) FAIL state_since 未随状态切换刷新")
        ok = False
    else:
        print("3) state_since 刷新: OK")

    # ---- 4) _fmt_dur 格式 ----
    cases = {0: "0:00", 59: "0:59", 95: "1:35", 3599: "59:59",
             3600: "1:00:00", 7325: "2:02:05"}
    bad = [(k, v, W._fmt_dur(k)) for k, v in cases.items() if W._fmt_dur(k) != v]
    if bad:
        print("4) FAIL _fmt_dur: %s" % bad)
        ok = False
    else:
        print("4) _fmt_dur 格式: OK")

    # ---- 5) hook 发送失败重试一次 ----
    hits = {"n": 0}

    class Flaky(BaseHTTPRequestHandler):
        def do_POST(self):
            hits["n"] += 1
            self.rfile.read(int(self.headers.get("Content-Length", 0)))
            if hits["n"] == 1:
                self.close_connection = True   # 第一次粗暴断连，模拟瞬时失败
                return
            self.send_response(204)
            self.end_headers()

        def log_message(self, *args):
            pass

    srv = ThreadingHTTPServer(("127.0.0.1", 0), Flaky)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    old_port = hook_handler.PORT
    hook_handler.PORT = srv.server_address[1]
    try:
        hook_handler.send({"event": "retry-test"})
        retry_ok = hits["n"] == 2
    except Exception as exc:
        retry_ok = False
        print("5) 异常: %r" % (exc,))
    finally:
        hook_handler.PORT = old_port
        srv.shutdown()
    if not retry_ok:
        print("5) FAIL 重试: 收到 %d 次请求" % hits["n"])
        ok = False
    else:
        print("5) hook 失败重试: OK")

    # ---- 6) 新一轮清除旧清单和旧错误 ----
    inject(win, "round", "跨轮测试")
    win.apply_event({"session_id": "round", "event": "todo_update",
                     "todos": [{"content": "旧任务", "status": "in_progress"}],
                     "current_task": "旧任务"})
    win.apply_event({"session_id": "round", "event": "tool_failure",
                     "error_preview": "旧错误"})
    win.apply_event({"session_id": "round", "event": "stop"})
    win.apply_event({"session_id": "round", "event": "user_prompt_submit",
                     "prompt_preview": "新一轮", "todos": [], "current_task": ""})
    round_s = win.sessions["round"]
    clean = (round_s["state"] == "working" and round_s["todos"] == []
             and round_s["current_task"] == ""
             and round_s.get("error_count", 0) == 0
             and not round_s.get("last_error"))
    if not clean:
        print("6) FAIL 跨轮清理: %r" % round_s)
        ok = False
    else:
        print("6) 跨轮状态清理: OK")

    # ---- 7) 空 todo_update 是权威快照，可清除旧任务 ----
    round_s["todos"] = [{"content": "残留", "status": "pending"}]
    round_s["current_task"] = "残留"
    win.apply_event({"session_id": "round", "event": "todo_update",
                     "todos": [], "current_task": ""})
    if round_s["todos"] or round_s["current_task"]:
        print("7) FAIL 空任务快照未清除")
        ok = False
    else:
        print("7) 空任务快照清理: OK")

    # ---- 8) 完成态拒绝迟到事件，且不会被刷新活动时间 ----
    inject(win, "closed", "终态测试", "turn-closed")
    win.apply_event({"session_id": "closed", "event": "todo_update",
                     "turn_id": "turn-closed",
                     "todos": [{"content": "完成前任务", "status": "in_progress"}],
                     "current_task": "完成前任务"})
    win.apply_event({"session_id": "closed", "event": "stop", "turn_id": "turn-closed"})
    closed = win.sessions["closed"]
    closed_updated = closed["updated_at"]
    closed_todos = list(closed["todos"])
    win.apply_event({"session_id": "closed", "event": "todo_update",
                     "turn_id": "turn-closed",
                     "todos": [{"content": "迟到任务", "status": "in_progress"}],
                     "current_task": "迟到任务"})
    win.apply_event({"session_id": "closed", "event": "permission_request",
                     "turn_id": "turn-closed", "last_tool": "Write"})
    win.apply_event({"session_id": "closed", "event": "tool_failure",
                     "turn_id": "turn-closed", "error_preview": "迟到错误"})
    closed_ok = (closed["state"] == "done" and closed["todos"] == closed_todos
                 and closed["updated_at"] == closed_updated
                 and not closed.get("error_count"))
    if not closed_ok:
        print("8) FAIL 完成态被迟到事件覆盖: %r" % closed)
        ok = False
    else:
        print("8) 完成态拒绝迟到事件: OK")

    # ---- 9) 旧轮 stop 不能终止新轮 ----
    inject(win, "turns", "轮次测试", "turn-1")
    inject(win, "turns", "轮次测试", "turn-2")
    turns = win.sessions["turns"]
    turns_updated = turns["updated_at"]
    win.apply_event({"session_id": "turns", "event": "stop", "turn_id": "turn-1"})
    win.apply_event({"session_id": "turns", "event": "todo_update",
                     "todos": [{"content": "未标识旧事件", "status": "in_progress"}],
                     "current_task": "未标识旧事件"})
    turn_ok = (turns["state"] == "working" and turns["active_turn_id"] == "turn-2"
               and turns["updated_at"] == turns_updated and not turns["todos"])
    if not turn_ok:
        print("9) FAIL 旧轮 stop 覆盖新轮: %r" % turns)
        ok = False
    else:
        print("9) 旧轮 stop 过滤: OK")

    # ---- 10) 无轮次 ID 的旧 payload 也不能唤醒完成态 ----
    inject(win, "legacy", "兼容测试")
    win.apply_event({"session_id": "legacy", "event": "stop"})
    legacy = win.sessions["legacy"]
    legacy_updated = legacy["updated_at"]
    win.apply_event({"session_id": "legacy", "event": "todo_update",
                     "todos": [{"content": "迟到", "status": "in_progress"}],
                     "current_task": "迟到"})
    legacy_ok = legacy["state"] == "done" and legacy["updated_at"] == legacy_updated
    if not legacy_ok:
        print("10) FAIL 无轮次兼容: %r" % legacy)
        ok = False
    else:
        print("10) 无轮次完成态兼容: OK")

    # ---- 11) Bash 权限请求保持黄灯，其他工具保持红灯 ----
    inject(win, "permissions", "权限测试", "turn-permission")
    permissions = win.sessions["permissions"]
    win.apply_event({"session_id": "permissions", "event": "permission_request",
                     "turn_id": "turn-permission", "last_tool": "Bash"})
    bash_ok = permissions["state"] == "working"
    win.apply_event({"session_id": "permissions", "event": "permission_request",
                     "turn_id": "turn-permission", "last_tool": "Write"})
    non_bash_ok = permissions["state"] == "waiting"
    if not (bash_ok and non_bash_ok):
        print("11) FAIL 权限灯策略: %r" % permissions)
        ok = False
    else:
        print("11) Bash 黄灯与其他权限红灯: OK")

    # ---- 12) 极大边距和负向拖动都夹在当前屏幕内 ----
    win.cfg.update({"corner": "bottom-right", "margin_x": 999999, "margin_y": 999999})
    win._place(1)
    root.update()
    sw, sh = root.winfo_screenwidth(), root.winfo_screenheight()
    placed_ok = (0 <= root.winfo_x() <= max(0, sw - W.PANEL_W)
                 and 0 <= root.winfo_y() <= max(0, sh - root.winfo_height()))
    root.geometry("+0+0")
    root.update()
    with mock.patch.object(W, "save_config"):
        win._remember_position()
    remembered_ok = win.cfg["margin_x"] >= 0 and win.cfg["margin_y"] >= 0
    if not placed_ok or not remembered_ok:
        print("12) FAIL 位置夹取")
        ok = False
    else:
        print("12) 窗口位置夹取: OK")

    # ---- 13) 默认常驻空闲态；关闭开关后隐藏；开启后立即恢复 ----
    win.sessions.clear()
    win.cfg["show_idle"] = True
    win.render()
    root.update()
    idle_key = id(win.idle_session)
    idle_ok = (root.winfo_viewable() and list(win.rows.keys()) == [idle_key]
               and win.rows[idle_key]["lab_t"].cget("text") == "暂无活跃会话")
    win.render()
    idle_stable = list(win.rows.keys()) == [idle_key]
    win.cfg["show_idle"] = False
    win.render()
    root.update()
    hidden_ok = not root.winfo_viewable() and not win.rows
    win.cfg["show_idle"] = True
    win.render()
    root.update()
    restored_ok = root.winfo_viewable() and list(win.rows.keys()) == [idle_key]
    if not (idle_ok and idle_stable and hidden_ok and restored_ok):
        print("13) FAIL 空闲态: idle=%s stable=%s hidden=%s restored=%s"
              % (idle_ok, idle_stable, hidden_ok, restored_ok))
        ok = False
    else:
        print("13) 常驻空闲态开关: OK")

    # ---- 14) 活跃会话出现后替换空闲行 ----
    inject(win, "active-after-idle", "活跃会话")
    win.render()
    root.update()
    active_ok = (len(win.rows) == 1
                 and next(iter(win.rows.keys())) != idle_key
                 and win.rows[next(iter(win.rows))]["lab_p"].cget("text") == "活跃会话")
    if not active_ok:
        print("14) FAIL 活跃会话未替换空闲行")
        ok = False
    else:
        print("14) 活跃会话替换空闲态: OK")
    try:
        root.destroy()
    except tk.TclError:
        pass
    print("ALL DISPLAY TESTS PASSED" if ok else "DISPLAY TESTS FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
