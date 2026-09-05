#!/bin/bash
# ZCodeStatusHook 端到端自测（对照 apps/desktop/scripts/test-hook-helper.ps1 的意图）。
# Windows 版编译 C# 单测；Swift 版纯函数已由 TestRunner 覆盖，这里补进程级行为：
# 编译 helper → sqlite3 种子库 → 本地 HTTP 捕获 → 断言 payload 字段、stdout 恒空、
# stdin 容错、端口不通重试上限。全部通过退出码 0。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/.build/debug/ZCodeStatusHook"
TMP="$(mktemp -d /tmp/zcode-status-hook-tests.XXXXXX)"
CAPTURE="$TMP/captured.jsonl"
SERVER_PID=""

cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

PASS=0
FAIL=0

report() {
  if [ "$1" -eq 0 ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $2"
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    report 0
  else
    report 1 "$desc — expected [$expected] actual [$actual]"
  fi
}

# 最近一条捕获 payload 的字段值（python 表达式 d 为解析后的对象；布尔输出小写）。
field() {
  tail -n 1 "$CAPTURE" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
value = $1
if isinstance(value, bool):
    value = str(value).lower()
print(value)" 2>/dev/null || echo "<error>"
}

captured_count() {
  [ -f "$CAPTURE" ] && wc -l < "$CAPTURE" | tr -d ' ' || echo 0
}

echo "== 构建 helper =="
(cd "$ROOT" && swift build --product ZCodeStatusHook) || { echo "build failed" >&2; exit 1; }

echo "== 准备 sqlite 种子库（parent 链 + 环链）=="
DB="$TMP/sessions.db"
sqlite3 "$DB" <<'SQL'
CREATE TABLE session (id TEXT PRIMARY KEY, directory TEXT, parent_id TEXT);
INSERT INTO session VALUES ('s-leaf', '/ephemeral/nightly', 's-root');
INSERT INTO session VALUES ('s-root', '/Users/tester/Projects/zcode_ws', NULL);
INSERT INTO session VALUES ('s-a', '/volatile/a', 's-b');
INSERT INTO session VALUES ('s-b', '/volatile/b', 's-a');
SQL

echo "== 启动本地捕获服务器 =="
LISTENER="$TMP/listener.py"
cat > "$LISTENER" <<'PY'
import http.server
import socketserver
import sys

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("content-length", 0))
        body = self.rfile.read(length)
        with open(sys.argv[1], "a") as capture:
            capture.write(body.decode("utf-8") + "\n")
        self.send_response(204)
        self.end_headers()

    def log_message(self, *_):
        pass

socketserver.TCPServer.allow_reuse_address = True
server = socketserver.TCPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
PY
python3 "$LISTENER" "$CAPTURE" > "$TMP/port.txt" &
SERVER_PID=$!
for _ in $(seq 1 50); do
  [ -s "$TMP/port.txt" ] && break
  sleep 0.1
done
PORT="$(cat "$TMP/port.txt")"
assert_eq "capture server bound" true "$([ -n "$PORT" ] && echo true || echo false)"

run_helper() {
  # $1=token $2=session $3=project_dir $4=db $5=stdin 文件（省略则空 stdin）
  ZCODE_STATUS_PORT="$PORT" "$HELPER" "$1" "$2" "$3" "$4" < "${5:-/dev/null}" > "$TMP/stdout.txt" 2>"$TMP/stderr.txt"
  echo $?
}

echo "== T1: 完整路径（token 小写化 / SQLite 根工作区 / 截断 / todos / turn_id）=="
printf '%s' '{"prompt":"  多行\n空白\t要\n 折叠 ","turn_id":"t-1","tool_name":"TodoWrite","tool_input":{"todos":[{"content":"这条待办内容特别长需要被截断到八十个字符以内因为上限是八十超过之后会显示前七十七个字符加上省略号结尾这样就对了而且还要继续加长超过八十个字符上限才会真正触发截断分支逻辑","status":"completed"},{"content":"进行中的任务","status":"in_progress"}]}}' > "$TMP/t1.json"
CODE="$(run_helper USER_PROMPT_SUBMIT s-leaf /ephemeral/nightly "$DB" "$TMP/t1.json")"
assert_eq "T1 exit code" 0 "$CODE"
assert_eq "T1 stdout empty" "" "$(cat "$TMP/stdout.txt")"
assert_eq "T1 captured one event" 1 "$(captured_count)"
assert_eq "T1 event lowercased" "user_prompt_submit" "$(field "d['event']")"
assert_eq "T1 session_id" "s-leaf" "$(field "d['session_id']")"
assert_eq "T1 project from db root" "zcode_ws" "$(field "d['project']")"
assert_eq "T1 workspace_dir from db root" "/Users/tester/Projects/zcode_ws" "$(field "d['workspace_dir']")"
assert_eq "T1 workspace_source" "session_root" "$(field "d['workspace_source']")"
assert_eq "T1 prompt collapsed" "多行 空白 要 折叠" "$(field "d['prompt_preview']")"
assert_eq "T1 todo content clipped to 80" 80 "$(field "len(d['todos'][0]['content'])")"
assert_eq "T1 todo clipped suffix" true "$(field "d['todos'][0]['content'].endswith('...')")"
assert_eq "T1 current_task" "进行中的任务" "$(field "d['current_task']")"
assert_eq "T1 turn_id" "t-1" "$(field "d['turn_id']")"
assert_eq "T1 ts numeric" true "$(field "isinstance(d['ts'], float) or isinstance(d['ts'], int)")"

echo "== T2: 未展开模板剥离（session_id 变空 → event_dir 兜底）=="
CODE="$(run_helper permission_request '${CLAUDE_SESSION_ID}' /volatile/run42 "$DB" /dev/null)"
assert_eq "T2 exit code" 0 "$CODE"
assert_eq "T2 stdout empty" "" "$(cat "$TMP/stdout.txt")"
assert_eq "T2 session_id stripped to empty" "" "$(field "d['session_id']")"
assert_eq "T2 project falls back to event dir" "run42" "$(field "d['project']")"
assert_eq "T2 workspace_source event_dir" "event_dir" "$(field "d['workspace_source']")"
assert_eq "T2 no workspace_dir key" false "$(field "'workspace_dir' in d")"

echo "== T3: parent 环链 → 放弃溯源（event_dir 兜底）=="
CODE="$(run_helper todo_update s-a /volatile/a "$DB" /dev/null)"
assert_eq "T3 exit code" 0 "$CODE"
assert_eq "T3 project falls back to event dir" "a" "$(field "d['project']")"
assert_eq "T3 no workspace_dir key" false "$(field "'workspace_dir' in d")"

echo "== T4: 端口不通 → 重试后静默退出（不超时挂死）=="
BEFORE=$(captured_count)
START=$SECONDS
ZCODE_STATUS_PORT=57397 "$HELPER" stop s-leaf /ephemeral/nightly "$DB" < /dev/null > "$TMP/stdout.txt" 2>&1
CODE=$?
ELAPSED=$((SECONDS - START))
assert_eq "T4 exit code" 0 "$CODE"
assert_eq "T4 stdout empty" "" "$(cat "$TMP/stdout.txt")"
assert_eq "T4 no event captured" "$BEFORE" "$(captured_count)"
if [ "$ELAPSED" -lt 6 ]; then report 0; else report 1 "T4 retry took ${ELAPSED}s (expected < 6s)"; fi

echo "== T5: 非法 UTF-8 stdin → 放弃发送 =="
BEFORE=$(captured_count)
printf '\xef\xbb\xbf{"event":"x","bad":"\xff\xfe\x00"}' > "$TMP/t5.bin"
CODE="$(run_helper stop s-leaf /ephemeral/nightly "$DB" "$TMP/t5.bin")"
assert_eq "T5 exit code" 0 "$CODE"
assert_eq "T5 no event captured" "$BEFORE" "$(captured_count)"

echo "== T6: stdin 超过 64KiB → 放弃发送 =="
BEFORE=$(captured_count)
python3 -c 'import sys; sys.stdout.write("a" * (64 * 1024 + 1))' > "$TMP/t6.json"
CODE="$(run_helper stop s-leaf /ephemeral/nightly "$DB" "$TMP/t6.json")"
assert_eq "T6 exit code" 0 "$CODE"
assert_eq "T6 no event captured" "$BEFORE" "$(captured_count)"

echo "== T7: db 缺失 → 静默 event_dir 兜底 =="
CODE="$(run_helper stop s-leaf /ephemeral/nightly "$TMP/missing.db" /dev/null)"
assert_eq "T7 exit code" 0 "$CODE"
assert_eq "T7 project falls back to event dir" "nightly" "$(field "d['project']")"

echo
echo "helper e2e: $PASS passed, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
