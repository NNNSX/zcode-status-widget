# -*- coding: utf-8 -*-
"""tooltip 代码路径无头自测：注入会话数据后直接调用 _set_hover，断言弹窗生成。

用独立端口，不影响正在运行的悬浮窗实例。
用法: python test_tooltip.py
"""

import sys
import time

from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(PROJECT_ROOT))

import tkinter as tk

import widget as wmod

wmod.PORT = 57399  # 避开运行中的实例

root = tk.Tk()
root.withdraw()
wg = wmod.Widget(root)

wg.apply_event({
    "event": "user_prompt_submit", "session_id": "t1",
    "project": "proj-a", "project_dir": "D:\\proj-a",
    "prompt_preview": "帮我做一个登录模块", "ts": time.time(),
})
wg.apply_event({
    "event": "todo_update", "session_id": "t1", "project": "proj-a",
    "todos": [
        {"content": "阅读配置", "status": "completed"},
        {"content": "修改登录模块", "status": "in_progress"},
        {"content": "编写测试", "status": "pending"},
    ],
    "current_task": "修改登录模块", "ts": time.time(),
})

wg.render()
root.update()

assert len(wg.rows) == 1, "应有一行: %r" % wg.rows
key = next(iter(wg.rows.keys()))
wg._set_hover(key)
deadline = time.time() + 2
while time.time() < deadline and wg.tooltip is None:
    root.update()
    time.sleep(0.05)

assert wg.tooltip is not None, "tooltip 未生成"
root.update()
texts = [l.cget("text") for l in wg.tooltip.winfo_children()[0].winfo_children()]
print("TOOLTIP LINES:")
for t in texts:
    print(" ", t)
assert any("proj-a" in t for t in texts), texts
assert any("修改登录模块" in t for t in texts), texts

wg._unhover()
root.update()
assert wg.tooltip is None, "离开后 tooltip 应销毁"
print("TOOLTIP TEST PASSED")
wg.quit()
