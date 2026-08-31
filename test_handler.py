# -*- coding: utf-8 -*-
"""hook_handler 本地自测：起一个临时接收器，跑各种样例事件并断言。

用法: python test_handler.py
"""

import json
import os
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path
from unittest import mock
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PROJECT_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(PROJECT_ROOT))
import hook_handler  # noqa: E402  仅复用 HOST 常量

received = []


class MockReceiver(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        received.append(json.loads(self.rfile.read(n).decode("utf-8")))
        self.send_response(204)
        self.end_headers()

    def log_message(self, *a):
        pass


# 绑定随机空闲端口，通过环境变量告知子进程，避免与运行中的真悬浮窗（57310）冲突
srv = ThreadingHTTPServer((hook_handler.HOST, 0), MockReceiver)
TEST_PORT = srv.server_address[1]
srv.daemon_threads = True
threading.Thread(target=srv.serve_forever, daemon=True).start()

PY = sys.executable
H = str(PROJECT_ROOT / "hook_handler.py")


def run(event, payload):
    p = subprocess.run(
        [PY, H, event, "test-session-1", "D:\\ZCode_ws"],
        input=json.dumps(payload).encode("utf-8"),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15,
        env={**os.environ, "ZCODE_STATUS_PORT": str(TEST_PORT)},
    )
    assert p.returncode == 0, (event, p.stderr)
    assert p.stdout == b"", ("stdout 必须为空", p.stdout)


run("user_prompt_submit", {"prompt": "帮我实现登录模块"})
run("todo_update", {"tool_input": {"todos": [
    {"content": "阅读配置", "status": "completed"},
    {"content": "修改登录模块", "status": "in_progress"},
    {"content": "写测试", "status": "pending"},
]}})
run("permission_request", {"tool_name": "Bash"})
run("tool_failure", {"tool_name": "Bash", "tool_response": {"error": "exit code 1"}})
run("stop", {})

time.sleep(0.3)
assert len(received) == 5, received
ev = {r["event"]: r for r in received}
assert ev["user_prompt_submit"]["prompt_preview"] == "帮我实现登录模块"
assert ev["user_prompt_submit"]["project"] == "ZCode_ws"
todos = ev["todo_update"]["todos"]
assert len(todos) == 3, todos
assert ev["todo_update"]["current_task"] == "修改登录模块"
assert ev["permission_request"]["last_tool"] == "Bash"
assert ev["tool_failure"]["error_preview"] == "exit code 1"
srv.shutdown()

# 非 2xx 必须重试：第一次 500，第二次 204
flaky_hits = []


class FlakyReceiver(BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        flaky_hits.append(1)
        self.send_response(500 if len(flaky_hits) == 1 else 204)
        self.end_headers()

    def log_message(self, *a):
        pass


flaky = ThreadingHTTPServer((hook_handler.HOST, 0), FlakyReceiver)
threading.Thread(target=flaky.serve_forever, daemon=True).start()
old_port = hook_handler.PORT
hook_handler.PORT = flaky.server_address[1]
hook_handler.send({"event": "retry-test"})
hook_handler.PORT = old_port
flaky.shutdown()
assert len(flaky_hits) == 2, flaky_hits

# 1 MiB 单备份轮转：mock 验证调用，不在测试里写动态路径
with mock.patch.object(hook_handler, "base_dir", return_value=r"C:\safe-test"), \
        mock.patch.object(hook_handler.os, "makedirs"), \
        mock.patch.object(hook_handler.os.path, "exists", return_value=True), \
        mock.patch.object(hook_handler.os.path, "getsize",
                          return_value=hook_handler.LOG_MAX_BYTES), \
        mock.patch.object(hook_handler.os, "replace") as replace, \
        mock.patch("builtins.open", mock.mock_open()) as opened:
    hook_handler.log_error("rotate-test")
    replace.assert_called_once_with(
        r"C:\safe-test\hook_error.log", r"C:\safe-test\hook_error.log.1")
    opened.assert_called_once()

# 悬浮窗未运行的连接拒绝属于正常离线
assert hook_handler.is_expected_offline(ConnectionRefusedError(10061, "offline"))
assert not hook_handler.is_expected_offline(TimeoutError("timeout"))

print("ALL TESTS PASSED")
