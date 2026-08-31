# -*- coding: utf-8 -*-
"""HTTP/队列/退出边界回归测试，全部使用随机临时端口。"""
import http.client
import json
import queue
import socket
import sys
import time
import tkinter as tk

from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(PROJECT_ROOT))
import widget as W  # noqa: E402

W.PORT = 0


def request(port, path="/event", body=b"{}", headers=None):
    conn = http.client.HTTPConnection(W.HOST, port, timeout=2)
    try:
        all_headers = {"Content-Type": "application/json",
                       "Content-Length": str(len(body))}
        all_headers.update(headers or {})
        conn.request("POST", path, body=body, headers=all_headers)
        response = conn.getresponse()
        response.read()
        return response.status
    finally:
        conn.close()


def drain_events():
    while True:
        try:
            W.events_q.get_nowait()
        except queue.Empty:
            return


def main():
    drain_events()
    root = tk.Tk()
    win = W.Widget(root)
    port = win.server.server_address[1]

    assert request(port, "/wrong") == 404
    # 固定端口必须独占，第二个服务不能同时绑定
    duplicate_blocked = False
    try:
        duplicate = W.ExclusiveThreadingHTTPServer((W.HOST, port), W.EventReceiver)
        duplicate.server_close()
    except OSError:
        duplicate_blocked = True
    assert duplicate_blocked
    assert request(port, body=b"not-json") == 400
    assert request(port, body=b"[]") == 400

    oversized = b"x" * (W.MAX_EVENT_BYTES + 1)
    assert request(port, body=oversized) == 413
    assert W.events_q.qsize() == 0

    event = json.dumps({"event": "stop", "session_id": "stability"}).encode("utf-8")
    assert request(port, body=event) == 204
    assert W.events_q.qsize() == 1
    drain_events()

    for i in range(W.MAX_EVENT_QUEUE):
        assert W.enqueue_event({"event": "stop", "session_id": "q-%d" % i})
    assert W.events_q.qsize() == W.MAX_EVENT_QUEUE
    assert request(port, body=event) == 503
    assert W.events_q.qsize() == W.MAX_EVENT_QUEUE
    drain_events()

    processed = []
    original_apply = win.apply_event
    original_after = root.after
    win.apply_event = lambda ev: processed.append(ev["n"])
    root.after = lambda *args: None
    for i in range(W.MAX_EVENTS_PER_TICK + 5):
        W.enqueue_event({"n": i})
    win.tick()
    assert processed == list(range(W.MAX_EVENTS_PER_TICK)), processed
    remaining = []
    while True:
        try:
            remaining.append(W.events_q.get_nowait()["n"])
        except queue.Empty:
            break
    assert remaining == list(range(W.MAX_EVENTS_PER_TICK,
                                   W.MAX_EVENTS_PER_TICK + 5)), remaining
    win.apply_event = original_apply
    root.after = original_after

    server_thread = win.server_thread
    win.quit()
    assert not server_thread.is_alive()
    assert win.server.fileno() == -1
    with socket.socket() as sock:
        sock.bind((W.HOST, port))

    try:
        root.destroy()
    except tk.TclError:
        pass
    print("ALL STABILITY TESTS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
