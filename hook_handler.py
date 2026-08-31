# -*- coding: utf-8 -*-
"""ZCode hook 入口：把 hook 事件通过本机回环 HTTP 发给悬浮窗进程。

用法（由 ~/.zcode/cli/config.json 的 hooks 配置调用，process 类型）:
    python.exe hook_handler.py <event> [session_id] [project_dir]

约定：
- stdout 必须保持为空（ZCode 对 hook 输出做严格 JSON 校验，任何多余输出都算失败）。
- 任何内部错误都吞掉并以 0 退出，绝不阻塞会话；仅非预期离线错误写入
  `%LOCALAPPDATA%\\zcode-status\\hook_error.log`，日志最多保留当前和一个备份。
- 状态由悬浮窗进程接收后仅在内存中持有；本脚本不读取或写入会话状态文件。
- 悬浮窗未运行时连接失败属于正常情况，静默丢弃即可。
"""

import errno
import json
import os
import re
import sqlite3
import sys
from pathlib import Path
import time
import http.client

HOST = "127.0.0.1"
# 测试用环境变量覆盖端口，避免与运行中的悬浮窗抢 57310
PORT = int(os.environ.get("ZCODE_STATUS_PORT") or 57310)
PROMPT_PREVIEW_LEN = 60
TASK_PREVIEW_LEN = 80
LOG_MAX_BYTES = 1024 * 1024
SESSION_DB_MAX_DEPTH = 16
SESSION_DB_TIMEOUT_SECONDS = 0.05


def base_dir():
    root = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
    return os.path.join(root, "zcode-status")


def log_error(msg):
    try:
        os.makedirs(base_dir(), exist_ok=True)
        path = os.path.join(base_dir(), "hook_error.log")
        backup = path + ".1"
        line = "%s %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg)
        size = os.path.getsize(path) if os.path.exists(path) else 0
        if size + len(line.encode("utf-8")) > LOG_MAX_BYTES:
            os.replace(path, backup)
        with open(path, "a", encoding="utf-8") as f:
            f.write(line)
    except Exception:
        pass


def is_expected_offline(exc):
    """悬浮窗未运行时的连接拒绝属于预期离线，不需要刷错误日志。"""
    return (isinstance(exc, ConnectionRefusedError)
            or getattr(exc, "errno", None) == errno.ECONNREFUSED
            or getattr(exc, "winerror", None) == 10061)


def expand(arg):
    """模板变量万一没被展开，兜底清掉 ${...} 形式。"""
    if not arg:
        return ""
    return re.sub(r"\$\{[^}]*\}", "", arg).strip()


def clip(s, n):
    s = " ".join(str(s).split())
    return s[: n - 1] + "…" if len(s) > n else s


def read_stdin():
    try:
        raw = sys.stdin.read() if not sys.stdin.isatty() else ""
    except Exception:
        raw = ""
    return raw or ""


def extract_todos(data):
    """防御式找 todos：tool_input.todos / todos / message.todos。"""
    for holder in (data.get("tool_input"), data, data.get("message")):
        if isinstance(holder, dict) and isinstance(holder.get("todos"), list):
            todos = []
            for t in holder["todos"]:
                if not isinstance(t, dict):
                    continue
                todos.append({
                    "content": clip(t.get("content") or t.get("activeForm")
                                    or t.get("subject") or "", TASK_PREVIEW_LEN),
                    "status": t.get("status") or "pending",
                })
            return todos
    return None


def extract_prompt(data):
    for key in ("prompt", "user_prompt", "message"):
        v = data.get(key)
        if isinstance(v, str) and v.strip():
            return clip(v, PROMPT_PREVIEW_LEN)
    return None


def extract_tool_name(data):
    v = data.get("tool_name") or data.get("toolName")
    return clip(v, 40) if v else None


def extract_turn_id(data):
    v = data.get("turn_id") or data.get("turnId")
    return clip(str(v), 128) if v else None


def extract_error(data):
    resp = data.get("tool_response")
    if isinstance(resp, dict):
        for key in ("error", "message", "stderr"):
            if resp.get(key):
                return clip(resp[key], PROMPT_PREVIEW_LEN)
    elif isinstance(resp, str) and resp.strip():
        return clip(resp, PROMPT_PREVIEW_LEN)
    for key in ("error", "message"):
        if isinstance(data.get(key), str) and data.get(key).strip():
            return clip(data[key], PROMPT_PREVIEW_LEN)
    return None


def session_db_path():
    override = os.environ.get("ZCODE_STATUS_DB_PATH")
    if override:
        return override
    return os.path.join(os.path.expanduser("~"), ".zcode", "cli", "db", "db.sqlite")


def root_workspace_dir(session_id):
    """按 parent_id 追溯根会话目录；无法读取时返回空字符串并走旧路径回退。"""
    if not session_id:
        return ""
    path = session_db_path()
    if not os.path.isfile(path):
        return ""
    try:
        uri = Path(path).resolve().as_uri() + "?mode=ro"
        conn = sqlite3.connect(uri, uri=True, timeout=SESSION_DB_TIMEOUT_SECONDS)
        try:
            current = str(session_id)
            seen = set()
            root_dir = ""
            for _ in range(SESSION_DB_MAX_DEPTH):
                if not current or current in seen:
                    return ""
                seen.add(current)
                row = conn.execute(
                    "SELECT directory, parent_id FROM session WHERE id = ?", (current,)
                ).fetchone()
                if not row:
                    return ""
                directory, parent_id = row
                if isinstance(directory, str) and directory.strip():
                    root_dir = directory.strip()
                current = str(parent_id or "").strip()
                if not current:
                    return root_dir
            return ""
        finally:
            conn.close()
    except (OSError, sqlite3.Error, ValueError):
        return ""


def build_payload(event, session_id, project_dir, data):
    workspace_dir = root_workspace_dir(session_id)
    display_dir = workspace_dir or project_dir
    project = os.path.basename(display_dir.rstrip("\\/")) or "ZCode"
    todos = extract_todos(data) or []
    current_task = next(
        (t["content"] for t in todos if t.get("status") == "in_progress"),
        "",
    )
    return {
        "event": event,
        "session_id": session_id,
        "project": project,
        "project_dir": project_dir,
        "workspace_dir": workspace_dir,
        "workspace_source": "session_root" if workspace_dir else "event_dir",
        "prompt_preview": extract_prompt(data) or "",
        "last_tool": extract_tool_name(data) or "",
        "error_preview": extract_error(data) or "",
        "todos": todos,
        "current_task": current_task,
        "turn_id": extract_turn_id(data) or "",
        "ts": time.time(),
    }


def send(payload, retries=1):
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    last = None
    for attempt in range(retries + 1):
        conn = http.client.HTTPConnection(HOST, PORT, timeout=0.5)
        try:
            conn.request("POST", "/event", body=body,
                         headers={"Content-Type": "application/json"})
            response = conn.getresponse()
            response.read()
            if not 200 <= response.status < 300:
                raise RuntimeError("widget HTTP %d" % response.status)
            return
        except Exception as exc:
            # 悬浮窗正在重启/瞬时抢占端口时一次失败不代表丢失，
            # 重试一次（最坏 ~1.2s，仍远低于 hook 的 5s 超时）
            last = exc
        finally:
            conn.close()
        if attempt < retries:
            time.sleep(0.15)
    raise last


def main():
    args = [expand(a) for a in sys.argv[1:]]
    event = (args[0] if args else "").lower()
    session_id = args[1] if len(args) > 1 else ""
    project_dir = args[2] if len(args) > 2 else ""
    if not project_dir:
        project_dir = os.environ.get("ZCODE_PROJECT_DIR") or os.environ.get("CLAUDE_PROJECT_DIR") or ""

    raw = read_stdin()
    try:
        data = json.loads(raw) if raw else {}
        if not isinstance(data, dict):
            data = {}
    except Exception:
        data = {}

    send(build_payload(event, session_id, project_dir, data))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # 永远以 0 退出，不阻塞会话
        if not is_expected_offline(exc):
            log_error("unhandled: %r" % (exc,))
    sys.exit(0)
