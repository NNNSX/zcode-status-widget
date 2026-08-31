# -*- coding: utf-8 -*-
"""三个 bug 的回归测试（不依赖截屏，直接断言窗口样式与事件路由）：

1) bind_all 隔离：设置窗口/其他 Toplevel 上的鼠标事件不得触发面板拖拽
   （修复"拖透明度滑块时面板跟着鼠标跑"）。
2) 透明度跨越 100% 后仍有效：>=100% 清除 WS_EX_LAYERED（换回 DWM 圆角），
   <100% 必须确保样式在位再设 alpha（Tk 自己不会补回，这是"透明度突然失效"的根因）。
   通过 GetWindowLongPtrW / GetLayeredWindowAttributes 直接读系统状态断言。

用法: python test_opacity_regression.py
"""
import ctypes
import ctypes.wintypes as wt
import sys
import time
import types
import tkinter as tk

from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(PROJECT_ROOT))
import widget as W  # noqa: E402

W.PORT = 0  # 随机临时端口，不影响正在运行的生产实例

GWL_EXSTYLE = -20
WS_EX_LAYERED = 0x80000
GA_ROOT = 2


def root_hwnd(root):
    return ctypes.windll.user32.GetAncestor(root.winfo_id(), GA_ROOT)


def ex_style(root):
    return ctypes.windll.user32.GetWindowLongPtrW(root_hwnd(root), GWL_EXSTYLE)


def layered_alpha(root):
    """返回 (是否设置了分层alpha, alpha值)。未分层时返回 (False, None)。"""
    if not ex_style(root) & WS_EX_LAYERED:
        return False, None
    alpha = ctypes.c_ubyte()   # wt.BYTE 会被按有符号解析，153 变成 -103
    flags = wt.DWORD()
    ok = ctypes.windll.user32.GetLayeredWindowAttributes(
        root_hwnd(root), None, ctypes.byref(alpha), ctypes.byref(flags))
    return bool(ok), alpha.value if ok else None


def press_event(widget, num=1):
    # ButtonPress=4
    return types.SimpleNamespace(type=types.SimpleNamespace(value="4"), num=num,
                                 widget=widget, x=10, y=10, x_root=500, y_root=500)


def main():
    failures = []

    root = tk.Tk()
    win = W.Widget(root)
    root.update_idletasks()
    for _ in range(10):
        root.update()
        time.sleep(0.02)

    # ---- 1) bind_all 隔离 ----
    try:
        fake = tk.Toplevel(root)          # 模拟设置窗口
        btn = tk.Button(fake)             # 其上的控件
        fake.update_idletasks()
        win._handler_proxy(press_event(btn))
        if win._press is not None:
            failures.append("外部 Toplevel 控件上的按下被误当成面板拖拽")
        win._handler_proxy(press_event(root))
        if win._press is None:
            failures.append("面板自身按下未被记录")
        print("1) bind_all 事件隔离: OK" if not failures else "1) FAIL: %s" % failures)
    except Exception as exc:
        failures.append("part1 异常: %r" % exc)
        print("1) FAIL 异常:", exc)

    # ---- 2) 透明度跨越 100% 回归 ----
    try:
        checks = []
        for k, want_layered in ((100, False), (60, True), (100, False), (60, True),
                                (85, True), (100, False), (60, True)):
            win._apply_opacity(k)
            root.update()
            time.sleep(0.05)
            layered, alpha = layered_alpha(root)
            ok = bool(ex_style(root) & WS_EX_LAYERED) == want_layered
            if want_layered and alpha is not None:
                ok = ok and abs(alpha - round(255 * k / 100)) <= 2
            checks.append((k, want_layered, layered, alpha, ok))
            if not ok:
                failures.append("opacity=%s 期望 layered=%s 实际 layered=%s alpha=%s"
                                % (k, want_layered, layered, alpha))
        if not failures:
            print("2) 透明度跨越 100%% 回归: OK  （opacity, layered, alpha 序列 %s）" %
                  [(c[0], c[2], c[3]) for c in checks])
        else:
            print("2) FAIL:", [c for c in checks if not c[4]])
    except Exception as exc:
        failures.append("part2 异常: %r" % exc)
        print("2) FAIL 异常:", exc)

    win.quit()
    try:
        root.destroy()
    except tk.TclError:
        pass
    if failures:
        print("REGRESSION FAILED: %d 项" % len(failures))
        return 1
    print("ALL REGRESSION TESTS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
