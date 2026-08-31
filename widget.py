# -*- coding: utf-8 -*-
"""ZCode 任务状态悬浮窗。

常驻置顶小面板，每个活跃 ZCode 会话一行，行首横向排三颗信号灯（红/黄/绿）：
    (●○○) 项目名  当前任务…  x/y
黄灯闪烁=执行中，红灯快闪=等待确认，绿灯呼吸=本轮完成。
工具级报错不属于会话状态，不计入信号灯，只在悬停详情里显示次数。

事件来源：hook_handler.py 通过 127.0.0.1:57310 回环 POST /event 推送。
状态由本进程持有；面板可拖动（松手自动记忆位置）；系统托盘图标提供
设置/重置位置/退出菜单；设置窗口兼作首次运行的欢迎页。

配置与开机自启持久化在 HKCU 注册表（Software\\ZCodeStatusLight），
本进程不做任何文件读写。
"""

import json
import math
import os
import queue
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import tkinter as tk
from tkinter import font as tkfont

from version import VERSION

HOST = "127.0.0.1"
PORT = 57310

PANEL_W = 380
ROW_H = 34
PAD = 10
DONE_TTL = 300        # 完成的会话行保留 5 分钟
ANY_TTL = 1800        # 任何会话 30 分钟无活动即移除
TICK_MS = 140
DRAG_THRESHOLD = 4    # 位移超过该像素才算拖动，避免误碰
MAX_EVENT_BYTES = 64 * 1024
MAX_EVENT_QUEUE = 256
MAX_EVENTS_PER_TICK = 32

BG = "#1e1f24"
ROW_BG = "#24252b"
ROW_HOVER = "#2d2e35"
FG = "#e8e8ea"
FG_DIM = "#9a9aa2"
# ---- 信号灯：横向三灯（红/黄/绿），按状态点亮其中一颗并施加动效 ----
LIGHT_ORDER = ("red", "yellow", "green")
LIGHT_BRIGHT = {"red": "#e5484d", "yellow": "#f2c14e", "green": "#46b881"}
LIGHT_DIM = {"red": "#3d2a2c", "yellow": "#413a26", "green": "#28402f"}
# 状态 -> (点亮的灯, 动效, 周期ms)；blink=硬闪烁，steady=长亮，breath=呼吸(35%↔100%)
# 注意：只有会话级状态进这里。工具级报错（tool_failure）不改变会话状态。
STATE_LIGHTS = {
    "working": ("yellow", "blink", 500),
    "waiting": ("red", "blink", 240),      # 等确认：急促闪
    "done": ("green", "breath", 2400),     # 完成：慢节奏呼吸
    "unknown": (None, "steady", 0),
}
STATE_TEXT = {
    "working": "执行中",
    "waiting": "等待确认",
    "done": "已完成",
    "unknown": "空闲",
}
TODO_MARK = {"completed": "✓", "in_progress": "►", "pending": "○"}

CORNERS = {
    "bottom-right": "右下",
    "bottom-left": "左下",
    "top-right": "右上",
    "top-left": "左上",
}
DEFAULT_CONFIG = {"corner": "bottom-right", "margin_x": 14, "margin_y": 52,
                  "opacity": 100, "show_idle": True}

REG_KEY = "HKCU\\Software\\ZCodeStatusLight"
RUN_KEY = "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run"
RUN_VALUE = "ZCodeStatusLight"

events_q = queue.Queue(maxsize=MAX_EVENT_QUEUE)


def enqueue_event(data):
    """非阻塞入队；满载时拒绝新事件，保护 HTTP 线程和 Tk 主线程。"""
    try:
        events_q.put_nowait(data)
        return True
    except queue.Full:
        return False


# ---- 配置持久化（HKCU 注册表；读失败一律回退默认值） ----
# reg.exe 输出是本地编码（中文系统为 GBK），统一按字节拿，再忽略错误解码；
# 本程序只存 ASCII 键值，解码方式不影响解析。
def _reg(args):
    # CREATE_NO_WINDOW：无控制台 exe 里每次 reg.exe 都会闪黑窗，必须压掉
    return subprocess.run(["reg"] + args, timeout=5, capture_output=True,
                          creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))


def _reg_out(r):
    try:
        return (r.stdout or b"").decode("utf-8", "ignore")
    except Exception:
        return ""


def load_config():
    cfg = dict(DEFAULT_CONFIG)
    try:
        r = _reg(["query", REG_KEY])
        if r.returncode == 0:
            vals = {}
            for line in _reg_out(r).splitlines():
                parts = line.split()
                if len(parts) >= 3:
                    vals[parts[0]] = parts[-1]
            if vals.get("corner") in CORNERS:
                cfg["corner"] = vals["corner"]
            for key in ("margin_x", "margin_y"):
                try:
                    cfg[key] = max(0, int(vals.get(key, "")))
                except Exception:
                    pass
            try:
                cfg["opacity"] = max(20, min(100, int(vals.get("opacity", ""))))
            except Exception:
                pass
            if vals.get("show_idle") in ("0", "1"):
                cfg["show_idle"] = vals["show_idle"] == "1"
    except Exception:
        pass
    return cfg


def has_config():
    try:
        return _reg(["query", REG_KEY]).returncode == 0
    except Exception:
        return True  # 查询失败时不打扰用户（不当成首次运行）


def save_config(cfg):
    try:
        items = (("corner", str(cfg["corner"])),
                 ("margin_x", str(int(cfg["margin_x"]))),
                 ("margin_y", str(int(cfg["margin_y"]))),
                 ("opacity", str(int(cfg.get("opacity", 100)))),
                 ("show_idle", str(int(bool(cfg.get("show_idle", True))))))
        for name, value in items:
            _reg(["add", REG_KEY, "/v", name, "/t", "REG_SZ", "/d", value, "/f"])
    except Exception:
        pass


# ---- 开机自启（HKCU Run 键，仅当前用户，无需管理员） ----
def autostart_enabled():
    try:
        return _reg(["query", RUN_KEY, "/v", RUN_VALUE]).returncode == 0
    except Exception:
        return False


def set_autostart(enable, target):
    try:
        if enable:
            _reg(["add", RUN_KEY, "/v", RUN_VALUE, "/t", "REG_SZ", "/d", target, "/f"])
        else:
            _reg(["delete", RUN_KEY, "/v", RUN_VALUE, "/f"])
    except Exception:
        pass


class ExclusiveThreadingHTTPServer(ThreadingHTTPServer):
    allow_reuse_address = False

    def server_bind(self):
        # Windows 的 SO_REUSEADDR 语义可能允许两个进程同时监听同一端口；
        # 独占绑定让固定端口真正具备单实例保护作用，不额外引入 mutex。
        if sys.platform == "win32":
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        super().server_bind()


class EventReceiver(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/event":
            self.send_error(404)
            return
        raw_length = self.headers.get("Content-Length")
        try:
            length = int(raw_length)
        except (TypeError, ValueError):
            self.send_error(400)
            return
        if length < 0:
            self.send_error(400)
            return
        if length > MAX_EVENT_BYTES:
            # Windows 在服务端带未读正文关闭 socket 时可能发 RST，客户端收不到 413。
            # 只丢弃至多“上限+1”字节（不按恶意 Content-Length 无限读取），
            # 并限制等待时间，既稳定响应又不让慢客户端占住线程。
            old_timeout = self.connection.gettimeout()
            try:
                self.connection.settimeout(0.05)
                remaining = min(length, MAX_EVENT_BYTES + 1)
                while remaining:
                    chunk = self.rfile.read(min(8192, remaining))
                    if not chunk:
                        break
                    remaining -= len(chunk)
            except (OSError, TimeoutError):
                pass
            finally:
                self.connection.settimeout(old_timeout)
            self.send_response(413)
            self.send_header("Content-Length", "0")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.flush()
            self.close_connection = True
            return
        try:
            data = json.loads(self.rfile.read(length).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self.send_error(400)
            return
        if not isinstance(data, dict):
            self.send_error(400)
            return
        if not enqueue_event(data):
            self.send_error(503)
            return
        self.send_response(204)
        self.end_headers()

    def log_message(self, *args):  # 静默访问日志
        pass


def start_server():
    server = ExclusiveThreadingHTTPServer((HOST, PORT), EventReceiver)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, thread


class Widget:
    def __init__(self, root):
        self.root = root
        self.server, self.server_thread = start_server()
        self.sessions = {}          # key -> dict
        self.idle_session = {"state": "unknown", "label": "状态灯", "project": "状态灯",
                             "prompt_preview": "暂无活跃会话", "todos": [],
                             "created_at": 0, "updated_at": 0}
        self.rows = {}              # key -> frame widgets
        self.dragging = False
        self._press = None
        self.topmost = True
        self.tooltip = None
        self.hover_key = None
        self.cfg = load_config()
        self.cmd_q = queue.Queue()  # 托盘线程 → tk 线程 的命令队列
        self.icon = None
        self.settings_win = None

        root.overrideredirect(True)
        root.attributes("-topmost", True)
        root.configure(bg=BG)
        self._apply_opacity()

        self.font_base = tkfont.Font(family="Microsoft YaHei UI", size=9)
        self.font_bold = tkfont.Font(family="Microsoft YaHei UI", size=9, weight="bold")
        self.font_small = tkfont.Font(family="Microsoft YaHei UI", size=8)

        self.body = tk.Frame(root, bg=BG)
        self.body.pack(fill="both", expand=True, padx=PAD, pady=PAD)

        self.topmost_var = tk.BooleanVar(value=True)
        self.menu = tk.Menu(root, tearoff=0, font=self.font_base)
        self.menu.add_command(label="设置…", command=self.open_settings)
        self.menu.add_checkbutton(label="置顶显示", onvalue=True, offvalue=False,
                                  variable=self.topmost_var, command=self._apply_topmost)
        self.menu.add_separator()
        self.menu.add_command(label="退出", command=self.quit)

        for seq in ("<ButtonPress-1>", "<B1-Motion>", "<ButtonRelease-1>",
                    "<Button-3>", "<Leave>"):
            root.bind_all(seq, self._handler_proxy, add="+")
        root.protocol("WM_DELETE_WINDOW", self.quit)
        root.after(TICK_MS, self.tick)
        self._start_tray()

    # ---- 事件统一分发 ----
    # Tk 事件类型码（本机实测）：4=ButtonPress 5=ButtonRelease 6=Motion 8=Leave；
    # 个别 tkinter 旧实现直接给同名字符串，两种都兼容。
    _EVENT_NAMES = {4: "ButtonPress", 5: "ButtonRelease", 6: "Motion", 8: "Leave"}

    def _handler_proxy(self, event):
        try:
            # 只处理发生在面板自身（含其子控件）上的鼠标事件；
            # bind_all 会连设置窗口/悬停窗的事件一起收到，
            # 不过滤的话拖设置里的滑块会被误当成拖面板（面板跟着鼠标跑）
            if event.widget.winfo_toplevel() is not self.root:
                return
            # event.type 实测为 EventType 枚举（value 为 `'4'/'5'/'6'/'8'` 这类字符串码）；
            # 兼容裸 int 与旧版字符串三种形态，统一转成事件名
            t = getattr(event.type, "value", event.type)
            try:
                name = self._EVENT_NAMES[int(t)]
            except (TypeError, ValueError):
                name = str(t)
            if name == "ButtonPress" and event.num == 1:
                self._drag_start(event)
            elif name == "Motion":
                self._drag_move(event)
            elif name == "ButtonRelease" and event.num == 1:
                self._drag_release(event)
            elif name == "ButtonPress" and event.num == 3:
                self.menu.tk_popup(event.x_root, event.y_root)
            elif name == "Leave":
                self._unhover()
        except Exception:
            pass

    # ---- 拖动（按住移动；松手后把落点换算成 角落+边距 存入配置） ----
    def _drag_start(self, event):
        self._press = (event.x_root, event.y_root)
        self.dragging = False
        self._hide_tooltip()

    def _drag_move(self, event):
        if self._press is None:
            return
        if not self.dragging:
            if (abs(event.x_root - self._press[0])
                    + abs(event.y_root - self._press[1])) < DRAG_THRESHOLD:
                return
            self.dragging = True
            self._drag_off = (event.x_root - self.root.winfo_x(),
                              event.y_root - self.root.winfo_y())
        self.root.geometry("+%d+%d" % (event.x_root - self._drag_off[0],
                                       event.y_root - self._drag_off[1]))

    def _drag_release(self, event):
        self._press = None
        if not self.dragging:
            return
        self.dragging = False
        try:
            self._remember_position()
        except Exception:
            pass

    def _remember_position(self):
        sw = self.root.winfo_screenwidth()
        sh = self.root.winfo_screenheight()
        h = self.root.winfo_height()
        x = max(0, min(self.root.winfo_x(), max(0, sw - PANEL_W)))
        y = max(0, min(self.root.winfo_y(), max(0, sh - h)))
        right = (x + PANEL_W / 2) > sw / 2
        bottom = (y + h / 2) > sh / 2
        self.cfg["corner"] = ("bottom" if bottom else "top") + "-" + ("right" if right else "left")
        self.cfg["margin_x"] = max(0, (sw - PANEL_W - x) if right else x)
        self.cfg["margin_y"] = max(0, (sh - h - y) if bottom else y)
        save_config(self.cfg)

    def _apply_round_corners(self):
        """Windows 11 DWM 圆角（抗锯齿）。要点有二：
        1. 用 GetAncestor(GA_ROOT) 拿真正的顶层 HWND（GetParent(winfo_id()) 会取空）；
        2. 必须在窗口映射(显示)之后调用——预映射阶段设置会在显示时丢失，
           因此每次 _place 都无条件重设一次。"""
        try:
            import ctypes
            user32 = ctypes.windll.user32
            GA_ROOT = 2
            hwnd = user32.GetAncestor(self.root.winfo_id(), GA_ROOT)
            if not hwnd:
                hwnd = self.root.winfo_id()
            pref = ctypes.c_int(2)  # DWMWCP_ROUND
            res = ctypes.windll.dwmapi.DwmSetWindowAttribute(
                hwnd, 33, ctypes.byref(pref), ctypes.sizeof(pref))
            return res == 0
        except Exception:
            return False

    def _apply_topmost(self):
        self.topmost = bool(self.topmost_var.get())
        self.root.attributes("-topmost", self.topmost)
        # Tk 重写窗口样式时会带走手动加的 WS_EX_LAYERED，补回透明度
        self._apply_opacity()

    def _set_win_alpha(self, win, k):
        """对指定顶层窗口直接用 Win32 分层 API 设透明度，不用 Tk 的
        attributes("-alpha")：外部已设置 WS_EX_LAYERED 时再走 Tk 的
        alpha 管理会破坏其内部状态，导致窗口完全不被绘制（实测白板）。
        统一手动管理样式位 + SetLayeredWindowAttributes，两条路不混用。"""
        import ctypes
        user32 = ctypes.windll.user32
        hwnd = user32.GetAncestor(win.winfo_id(), 2)  # GA_ROOT
        if not hwnd:
            return False
        GWL_EXSTYLE, WS_EX_LAYERED, LWA_ALPHA = -20, 0x80000, 2
        style = user32.GetWindowLongPtrW(hwnd, GWL_EXSTYLE)
        if k >= 100:
            if style & WS_EX_LAYERED:
                user32.SetWindowLongPtrW(hwnd, GWL_EXSTYLE,
                                         style & ~WS_EX_LAYERED)
            return True
        if not style & WS_EX_LAYERED:
            user32.SetWindowLongPtrW(hwnd, GWL_EXSTYLE,
                                     style | WS_EX_LAYERED)
        user32.SetLayeredWindowAttributes(hwnd, 0,
                                          ctypes.c_ubyte(round(255 * k / 100)),
                                          LWA_ALPHA)
        return True

    def _apply_opacity(self, value=None):
        """应用面板透明度（20..100）。Windows 的分层窗口（半透明）不参与
        DWM 圆角渲染，因此只有 100% 时圆角才生效。滑块反复跨越 100% 时
        Tk 不会自动补回分层样式，所以样式位始终由这里手动管理。"""
        try:
            k = int(value if value is not None else self.cfg.get("opacity", 100))
        except (TypeError, ValueError):
            k = 100
        k = max(20, min(100, k))
        try:
            if not self._set_win_alpha(self.root, k):
                self.root.attributes("-alpha", k / 100.0)  # 兜底（非 Windows）
            if k >= 100:
                self._apply_round_corners()
        except Exception:
            try:
                self.root.attributes("-alpha", k / 100.0)
            except Exception:
                pass

    def quit(self):
        try:
            if self.icon is not None:
                self.icon.stop()
        except Exception:
            pass
        try:
            self.server.shutdown()
            self.server.server_close()
            self.server_thread.join(timeout=1)
        except Exception:
            pass
        self.root.destroy()

    # ---- 托盘 ----
    def _start_tray(self):
        try:
            import pystray
            from PIL import Image, ImageDraw
        except Exception:
            self.icon = None  # 无托盘时仍有右键菜单可用
            return
        img = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        d.ellipse((6, 6, 26, 26), fill=(242, 193, 78, 255))
        menu = pystray.Menu(
            pystray.MenuItem("设置…", lambda: self.cmd_q.put("settings"), default=True),
            pystray.MenuItem("重置位置", lambda: self.cmd_q.put("reset_pos")),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem("退出", lambda: self.cmd_q.put("quit")),
        )
        self.icon = pystray.Icon("ZCodeStatusLight", img, "ZCode 状态灯", menu)
        threading.Thread(target=self.icon.run_detached, daemon=True).start()

    def _drain_cmds(self):
        try:
            while True:
                cmd = self.cmd_q.get_nowait()
                if cmd == "settings":
                    self.open_settings()
                elif cmd == "reset_pos":
                    self.cfg = dict(DEFAULT_CONFIG)
                    save_config(self.cfg)
                    self._place(max(1, len(self.visible_sessions())))
                elif cmd == "quit":
                    self.quit()
                    return
        except queue.Empty:
            pass

    # ---- 设置窗口（首次运行兼欢迎页） ----
    def open_settings(self, welcome=False):
        if self.settings_win is not None and self.settings_win.winfo_exists():
            self.settings_win.deiconify()
            self.settings_win.lift()
            return
        win = self.settings_win = tk.Toplevel(self.root)
        win.title("ZCode 状态灯 v%s" % VERSION)
        win.configure(bg=BG)
        win.resizable(False, False)
        win.attributes("-topmost", True)
        f = tk.Frame(win, bg=BG, padx=18, pady=14)
        f.pack(fill="both", expand=True)

        if welcome:
            tk.Label(f, text="ZCode 状态灯已启动", bg=BG, fg=FG,
                     font=("Microsoft YaHei UI", 13, "bold"),
                     anchor="w").pack(fill="x")
            tk.Label(f, text=("之后每个 ZCode 会话会在这里实时显示状态（三色信号灯）：\n"
                              "黄灯闪烁＝执行中   红灯快闪＝等待你确认\n"
                              "绿灯呼吸＝本轮完成   工具报错不影响状态\n"
                              "面板可以按住拖动，下面可以固定显示位置。"),
                     bg=BG, fg=FG_DIM, font=self.font_base, justify="left",
                     anchor="w").pack(fill="x", pady=(4, 12))

        tk.Label(f, text="显示位置", bg=BG, fg=FG_DIM,
                 font=self.font_small, anchor="w").pack(fill="x")
        pos_row = tk.Frame(f, bg=BG)
        pos_row.pack(anchor="w", pady=(2, 8))
        self.pos_var = tk.StringVar(value=self.cfg["corner"])
        for val in ("bottom-right", "bottom-left", "top-right", "top-left"):
            tk.Radiobutton(pos_row, text=CORNERS[val], value=val, variable=self.pos_var,
                           bg=BG, fg=FG, selectcolor=ROW_BG,
                           activebackground=BG, activeforeground=FG,
                           font=self.font_base).pack(side="left", padx=(0, 10))

        mg_row = tk.Frame(f, bg=BG)
        mg_row.pack(anchor="w", pady=(0, 8))
        tk.Label(mg_row, text="边距 X", bg=BG, fg=FG_DIM,
                 font=self.font_base).pack(side="left")
        self.mx_var = tk.StringVar(value=str(self.cfg["margin_x"]))
        tk.Entry(mg_row, textvariable=self.mx_var, width=6, bg=ROW_BG, fg=FG,
                 insertbackground=FG, relief="flat").pack(side="left", padx=(4, 12))
        tk.Label(mg_row, text="边距 Y", bg=BG, fg=FG_DIM,
                 font=self.font_base).pack(side="left")
        self.my_var = tk.StringVar(value=str(self.cfg["margin_y"]))
        tk.Entry(mg_row, textvariable=self.my_var, width=6, bg=ROW_BG, fg=FG,
                 insertbackground=FG, relief="flat").pack(side="left", padx=4)

        op_row = tk.Frame(f, bg=BG)
        op_row.pack(anchor="w", pady=(0, 2))
        tk.Label(op_row, text="面板透明度", bg=BG, fg=FG_DIM,
                 font=self.font_base).pack(side="left")
        self.opacity_var = tk.IntVar(value=int(self.cfg.get("opacity", 100)))
        tk.Scale(op_row, from_=20, to=100, orient="horizontal", resolution=5,
                 length=180, variable=self.opacity_var, bg=BG, fg=FG,
                 troughcolor=ROW_BG, highlightthickness=0, activebackground=ROW_HOVER,
                 font=self.font_small,
                 command=lambda v: self._apply_opacity(v)).pack(side="left", padx=(8, 0))
        tk.Label(f, text="注：低于 100% 时 Windows 不渲染面板圆角，拉回 100% 即恢复。",
                 bg=BG, fg=FG_DIM, font=self.font_small, anchor="w").pack(fill="x", pady=(0, 8))

        self.show_idle_var = tk.BooleanVar(value=bool(self.cfg.get("show_idle", True)))
        tk.Checkbutton(f, text="无会话时显示空闲状态", variable=self.show_idle_var, bg=BG, fg=FG,
                       selectcolor=ROW_BG, activebackground=BG, activeforeground=FG,
                       font=self.font_base).pack(anchor="w", pady=(0, 6))

        self.auto_var = tk.BooleanVar(value=autostart_enabled())
        tk.Checkbutton(f, text="开机自动启动", variable=self.auto_var, bg=BG, fg=FG,
                       selectcolor=ROW_BG, activebackground=BG, activeforeground=FG,
                       font=self.font_base).pack(anchor="w", pady=(0, 10))

        btn_row = tk.Frame(f, bg=BG)
        btn_row.pack(fill="x")
        tk.Button(btn_row, text="状态自检", command=self._self_test, bg=ROW_BG, fg=FG,
                  activebackground=ROW_HOVER, activeforeground=FG,
                  relief="flat", font=self.font_base).pack(side="left")
        tk.Button(btn_row, text="保存并关闭", command=lambda: self._save_settings(win),
                  bg="#3b5bdb", fg="#ffffff", activebackground="#364fc7",
                  relief="flat", font=self.font_base).pack(side="right")

        win.update_idletasks()
        sw = win.winfo_screenwidth()
        sh = win.winfo_screenheight()
        win.geometry("+%d+%d" % ((sw - win.winfo_reqwidth()) // 2,
                                 (sh - win.winfo_reqheight()) // 2))

    def _save_settings(self, win):
        try:
            mx = max(0, int(float(str(self.mx_var.get()).strip() or DEFAULT_CONFIG["margin_x"])))
        except Exception:
            mx = DEFAULT_CONFIG["margin_x"]
        try:
            my = max(0, int(float(str(self.my_var.get()).strip() or DEFAULT_CONFIG["margin_y"])))
        except Exception:
            my = DEFAULT_CONFIG["margin_y"]
        corner = self.pos_var.get()
        self.cfg["corner"] = corner if corner in CORNERS else DEFAULT_CONFIG["corner"]
        self.cfg["margin_x"], self.cfg["margin_y"] = mx, my
        try:
            self.cfg["opacity"] = max(20, min(100, int(self.opacity_var.get())))
        except Exception:
            self.cfg["opacity"] = DEFAULT_CONFIG["opacity"]
        self.cfg["show_idle"] = bool(self.show_idle_var.get())
        save_config(self.cfg)
        set_autostart(bool(self.auto_var.get()), self._autostart_target())
        win.destroy()
        self.settings_win = None
        n = len(self.visible_sessions())
        if n:
            self._place(n)
        else:
            self.render()

    def _autostart_target(self):
        if getattr(sys, "frozen", False):
            return sys.executable
        pythonw = os.path.join(os.path.dirname(sys.executable), "pythonw.exe")
        interpreter = pythonw if os.path.exists(pythonw) else sys.executable
        return '"%s" "%s"' % (interpreter, os.path.abspath(__file__))

    def _self_test(self):
        """注入一串假事件，演示 黄→清单→红闪→绿 完整流转。"""
        base = {"session_id": "selftest", "project": "自检演示"}
        enqueue_event(dict(base, event="user_prompt_submit",
                           prompt_preview="演示：开始执行一组任务"))

        def step1():
            enqueue_event(dict(base, event="todo_update", todos=[
                {"content": "演示任务一：读取文件", "status": "completed"},
                {"content": "演示任务二：修改代码", "status": "in_progress"},
                {"content": "演示任务三：运行测试", "status": "pending"}]))

        def step2():
            enqueue_event(dict(base, event="permission_request"))

        def step3():
            enqueue_event(dict(base, event="stop"))

        def step4():
            self.sessions.pop("selftest", None)

        self.root.after(400, step1)
        self.root.after(2200, step2)
        self.root.after(4200, step3)
        self.root.after(7000, step4)

    # ---- 状态机 ----
    @staticmethod
    def _set_state(s, now, new):
        if s["state"] != new:
            s["state"] = new
            s["state_since"] = now   # 用于展示"该状态已持续多久"

    def apply_event(self, ev):
        key = ev.get("session_id") or ev.get("project_dir") or ev.get("project") or "default"
        event = str(ev.get("event") or "").lower()
        now = time.time()
        s = self.sessions.get(key)
        if s is None:
            s = self.sessions[key] = {
                "created_at": now, "todos": [], "state": "unknown",
                "state_since": now,
            }
        s["updated_at"] = now
        for field in ("project", "last_tool", "error_preview"):
            if ev.get(field):
                s[field] = ev[field]

        if event == "user_prompt_submit":
            # 同一 session 的新一轮边界：旧清单和旧错误不能跨轮残留
            s["prompt_preview"] = ev.get("prompt_preview") or ""
            s["todos"] = []
            s["current_task"] = ""
            for field in ("error_count", "last_error", "error_preview", "last_tool"):
                s.pop(field, None)
            self._set_state(s, now, "working")
        elif event == "todo_update":
            # TodoWrite 上报完整快照；空值同样有语义，用于清除旧内容
            todos = ev.get("todos")
            s["todos"] = todos if isinstance(todos, list) else []
            s["current_task"] = ev.get("current_task") or ""
            if s["state"] in ("done", "unknown"):
                self._set_state(s, now, "working")
        elif event == "permission_request":
            self._set_state(s, now, "waiting")
        elif event == "tool_failure":
            # 单个工具失败不代表会话状态（执行中会自行调整重试），
            # 只累计到会话上，悬停详情里展示
            s["error_count"] = s.get("error_count", 0) + 1
            if ev.get("error_preview"):
                s["last_error"] = ev["error_preview"]
        elif event == "stop":
            self._set_state(s, now, "done")

    def visible_sessions(self):
        now = time.time()
        alive = []
        for key, s in list(self.sessions.items()):
            age = now - s.get("updated_at", now)
            if age > ANY_TTL or (s["state"] == "done" and age > DONE_TTL):
                del self.sessions[key]
                continue
            alive.append(s)
        # 最近活跃的会话排最上面，多会话时一眼看到当前正在干活的那个
        alive.sort(key=lambda s: s.get("updated_at", 0), reverse=True)
        return alive

    # ---- 渲染 ----
    def tick(self):
        for _ in range(MAX_EVENTS_PER_TICK):
            try:
                event = events_q.get_nowait()
            except queue.Empty:
                break
            self.apply_event(event)
        self._drain_cmds()
        if not self._root_alive():
            return
        try:
            self.render()
        except Exception:
            import traceback
            traceback.print_exc()  # 渲染出错不终止循环
        if self._root_alive():
            self.root.after(TICK_MS, self.tick)

    def _root_alive(self):
        try:
            return bool(self.root.winfo_exists())
        except Exception:
            return False

    def render(self):
        if self.dragging:
            return  # 拖动中不动布局，避免与 geometry 打架
        sessions = self.visible_sessions()
        if not sessions:
            self._hide_tooltip()
            if not self.cfg.get("show_idle", True):
                for f in list(self.rows):
                    self.rows.pop(f)["frame"].destroy()
                self.root.withdraw()
                return
            idle_key = id(self.idle_session)
            if list(self.rows.keys()) != [idle_key]:
                for f in list(self.rows):
                    self.rows.pop(f)["frame"].destroy()
                self._make_row(self.idle_session)
            self._update_row(self.idle_session, int(time.time() * 1000))
            if (not self.root.winfo_viewable()
                    or abs(self.root.winfo_height() - (ROW_H + 3 + 2 * PAD)) > 4):
                self._place(1)
            return

        # 项目重名加序号
        seen = {}
        for s in sessions:
            name = s.get("project") or "ZCode"
            seen[name] = seen.get(name, 0) + 1
            s["label"] = name if seen[name] == 1 else "%s·%d" % (name, seen[name])

        now_ms = int(time.time() * 1000)
        keys = [id(s) for s in sessions]

        # 删除多余行 / 顺序变化时重建
        if list(self.rows.keys()) != keys:
            for f in list(self.rows):
                self.rows.pop(f)["frame"].destroy()
            for s in sessions:
                self._make_row(s)

        for s in sessions:
            self._update_row(s, now_ms)

        need_h = len(sessions) * (ROW_H + 3) + 2 * PAD
        if (not self.root.winfo_viewable()
                or abs(self.root.winfo_height() - need_h) > 4):
            # 行数变化按角锚点重放：底部/右侧锚定时保持贴角，
            # 否则先按旧行数放置后行数增长会把新增行推出屏幕外
            self._place(len(sessions))

    def _make_row(self, s):
        key = id(s)
        f = tk.Frame(self.body, bg=ROW_BG, height=ROW_H)
        dot = tk.Canvas(f, width=44, height=16, bg=ROW_BG, highlightthickness=0)
        ids = {}
        for i, name in enumerate(LIGHT_ORDER):
            x = 4 + i * 13
            ids[name] = dot.create_oval(x, 4, x + 9, 13,
                                        fill=LIGHT_DIM[name], outline="")
        dot.pack(side="left", padx=(4, 4))
        lab_p = tk.Label(f, text="", bg=ROW_BG, fg=FG, font=self.font_bold, width=9, anchor="w")
        lab_p.pack(side="left")
        lab_t = tk.Label(f, text="", bg=ROW_BG, fg=FG_DIM, font=self.font_base, anchor="w")
        lab_t.pack(side="left", fill="x", expand=True)
        lab_n = tk.Label(f, text="", bg=ROW_BG, fg=FG_DIM, font=self.font_small, anchor="e")
        lab_n.pack(side="right", padx=(4, 6))
        f.pack(fill="x", pady=(0, 3))
        f.pack_propagate(False)
        for w in (f, dot, lab_p, lab_t, lab_n):
            w.bind("<Enter>", lambda e, k=key: self._set_hover(k))
            w.bind("<Leave>", lambda e: self._unhover())
        self.rows[key] = {"frame": f, "dot": dot, "light_ids": ids,
                          "lab_p": lab_p, "lab_t": lab_t, "lab_n": lab_n,
                          "sig": None}

    def _update_row(self, s, now_ms):
        w = self.rows[id(s)]
        state = s.get("state", "unknown")
        lit, mode, rate = STATE_LIGHTS.get(state, STATE_LIGHTS["unknown"])
        if mode == "blink":
            k = 1.0 if (now_ms // rate) % 2 == 0 else 0.0
        elif mode == "breath":
            k = 0.35 + 0.65 * (0.5 - 0.5 * math.cos(2 * math.pi * (now_ms % rate) / rate))
        else:
            k = 1.0
        fills = tuple(
            _lerp_color(LIGHT_DIM[name], LIGHT_BRIGHT[name], k) if name == lit
            else LIGHT_DIM[name]
            for name in LIGHT_ORDER
        )

        todos = s.get("todos") or []
        done_n = sum(1 for t in todos if t.get("status") == "completed")
        prog = "%d/%d" % (done_n, len(todos)) if todos else ""

        # 执行中/等待确认时，右侧展示该状态已持续多久：
        # 没有清单进度时它就是右列内容，时长本身也能暴露"卡住多久了"
        right = prog
        if not right and state in ("working", "waiting"):
            right = _fmt_dur(now_ms / 1000 - s.get("state_since", now_ms / 1000))

        if s.get("current_task"):
            task = s["current_task"]
        elif s.get("prompt_preview"):
            task = s["prompt_preview"]
        else:
            task = STATE_TEXT.get(state, "")

        sig = (state, fills, s.get("label"), task, right)
        if sig == w["sig"]:
            return
        w["sig"] = sig
        for name, color in zip(LIGHT_ORDER, fills):
            w["dot"].itemconfigure(w["light_ids"][name], fill=color)
        w["lab_p"].configure(text=clip(s.get("label", ""), 9))
        w["lab_t"].configure(text=clip(task, 22))
        w["lab_n"].configure(text=right)

    def _place(self, n):
        self.root.update_idletasks()
        h = n * (ROW_H + 3) + 2 * PAD
        sw = self.root.winfo_screenwidth()
        sh = self.root.winfo_screenheight()
        mx = self.cfg["margin_x"]
        my = self.cfg["margin_y"]
        corner = self.cfg["corner"]
        x = sw - PANEL_W - mx if "right" in corner else mx
        y = sh - h - my if "bottom" in corner else my
        x = max(0, min(x, max(0, sw - PANEL_W)))
        y = max(0, min(y, max(0, sh - h)))
        self.root.geometry("%dx%d+%d+%d" % (PANEL_W, h, x, y))
        self.root.deiconify()
        self._apply_round_corners()  # 映射后重设；预映射阶段设置会丢失
        # Tk 映射窗口时会用自己缓存的扩展样式覆盖掉手动加的 WS_EX_LAYERED，
        # 透明度随之失效，所以映射后必须重新断言
        self._apply_opacity()

    # ---- 悬停提示 ----
    def _set_hover(self, key):
        self.hover_key = key
        self.root.after(250, lambda: self._show_tooltip(key))

    def _show_tooltip(self, key):
        s = self.sessions_by_id().get(key)
        if s is None or self.hover_key != key or self.dragging:
            return
        self._hide_tooltip()
        lines = ["%s · %s" % (s.get("label", ""), STATE_TEXT.get(s.get("state"), ""))]
        if s.get("state") in ("working", "waiting"):
            lines.append("该状态已持续 %s" % _fmt_dur(
                time.time() - s.get("state_since", time.time())))
        for t in s.get("todos") or []:
            mark = TODO_MARK.get(t.get("status"), "○")
            lines.append("  %s %s" % (mark, t.get("content", "")))
        if s.get("prompt_preview"):
            lines.append("输入：%s" % s["prompt_preview"])
        if s.get("error_count"):
            lines.append("本轮工具出错 %d 次%s"
                         % (s["error_count"],
                            ("：%s" % s["last_error"]) if s.get("last_error") else ""))

        self.tooltip = tw = tk.Toplevel(self.root)
        tw.overrideredirect(True)
        tw.attributes("-topmost", True)
        frame = tk.Frame(tw, bg=BG, padx=8, pady=6)
        frame.pack()
        for i, line in enumerate(lines):
            tk.Label(frame, text=clip(line, 46), bg=BG,
                     fg=FG if i == 0 else FG_DIM,
                     font=self.font_bold if i == 0 else self.font_small,
                     anchor="w").pack(fill="x")
        x = self.root.winfo_x() + PANEL_W + 6
        y = self.root.winfo_y() + 8
        tw.update_idletasks()
        sw = self.root.winfo_screenwidth()
        sh = self.root.winfo_screenheight()
        if x + tw.winfo_reqwidth() > sw:
            x = max(4, self.root.winfo_x() - tw.winfo_reqwidth() - 6)
        if y + tw.winfo_reqheight() > sh:
            y = max(4, sh - tw.winfo_reqheight() - 8)
        tw.geometry("+%d+%d" % (x, y))
        try:
            # 映射后设透明度（走与面板相同的 Win32 分层路径），
            # 预映射设置会被 Tk 的样式重写抹掉
            tw.update_idletasks()
            self._set_win_alpha(tw, max(20, min(100, int(self.cfg.get("opacity", 100)))))
        except Exception:
            pass

    def _hide_tooltip(self):
        if self.tooltip is not None:
            try:
                self.tooltip.destroy()
            except Exception:
                pass
            self.tooltip = None

    def _unhover(self):
        self.hover_key = None
        self._hide_tooltip()

    def sessions_by_id(self):
        return {id(s): s for s in self.sessions.values()}


_LERP_CACHE = {}


def _lerp_color(c1, c2, k):
    # 每 140ms 每行都要算 3 个灯色，十六进制解析结果直接缓存
    key = (c1, c2, round(k, 2))
    v = _LERP_CACHE.get(key)
    if v is None:
        a = [int(c1[i:i + 2], 16) for i in (1, 3, 5)]
        b = [int(c2[i:i + 2], 16) for i in (1, 3, 5)]
        v = "#%02x%02x%02x" % tuple(
            round(a[i] + (b[i] - a[i]) * key[2]) for i in range(3))
        _LERP_CACHE[key] = v
    return v


def clip(s, n):
    s = str(s or "")
    return s if len(s) <= n else s[: max(1, n - 1)] + "…"


def _fmt_dur(sec):
    """秒数 → m:ss / h:mm:ss，用于展示状态持续时长。"""
    sec = max(0, int(sec))
    if sec < 3600:
        return "%d:%02d" % (sec // 60, sec % 60)
    return "%d:%02d:%02d" % (sec // 3600, (sec // 60) % 60, sec % 60)


def main():
    try:
        import ctypes
        ctypes.windll.shcore.SetProcessDpiAwareness(1)  # 必须在 Tk() 之前，否则坐标按虚拟分辨率算
    except Exception:
        pass
    root = tk.Tk()
    try:
        widget = Widget(root)
    except OSError:
        # 端口被占：已有实例在跑
        root.destroy()
        return
    root.withdraw()  # 有会话事件后再显示；启动 1 秒后补一次渲染
    root.after(1000, widget.render)
    if not has_config():  # 首次运行：设置窗口兼欢迎页
        root.after(900, lambda: widget.open_settings(welcome=True))
    root.mainloop()


if __name__ == "__main__":
    main()
