#!/usr/bin/env python3
"""A control endpoint for UI tests against a --scratch daemon (QA-007).

Acts as a second owner client on the scratch copy, so a test can change a
package under the phone, and reads back what the copy recorded.

  POST /bump?name=<release>          hold + unhold from this client: same package, version + 2
  POST /stale?name=<release>         release_rule with a wrong expected_version; returns the daemon's raw error
  POST /state?name=<release>         status, version, verdicts and the release decision, from the copy
  POST /cut?seconds=N                drop every connection through --proxy-port and refuse new ones for N s
  POST /freeze, /thaw                SIGSTOP / SIGCONT the scratch daemon (--daemon-pid, a process this run started)

Usage: scratch_control.py --port <daemon> --control-port <port> --token-file <f> --db <bus.sqlite>
"""
from __future__ import annotations

import argparse
import json
import os
import signal
import sqlite3
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_demo import Socket  # noqa: E402


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--control-port", type=int, required=True)
    parser.add_argument("--token-file", required=True)
    parser.add_argument("--db", required=True)
    parser.add_argument("--daemon-pid-file")
    parser.add_argument("--proxy-port", type=int, help="a TCP proxy to the daemon that /cut can drop")
    args = parser.parse_args()
    token = open(args.token_file).read().strip()

    import socket as net
    import threading
    import time
    proxy = {"down_until": 0.0, "conns": set(), "lock": threading.Lock()}

    def pipe(a, b) -> None:
        try:
            while True:
                data = a.recv(65536)
                if not data:
                    break
                b.sendall(data)
        except OSError:
            pass
        for s_ in (a, b):
            try:
                s_.close()
            except OSError:
                pass

    def serve_proxy(port: int) -> None:
        listener = net.socket(net.AF_INET, net.SOCK_STREAM)
        listener.setsockopt(net.SOL_SOCKET, net.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", port))
        listener.listen(64)
        while True:
            client, _ = listener.accept()
            if time.time() < proxy["down_until"]:
                client.close()  # the network is down: refused
                continue
            try:
                upstream = net.create_connection(("127.0.0.1", args.port), timeout=5)
                upstream.settimeout(None)
            except OSError:
                client.close()
                continue
            with proxy["lock"]:
                proxy["conns"].update({client, upstream})
            threading.Thread(target=pipe, args=(client, upstream), daemon=True).start()
            threading.Thread(target=pipe, args=(upstream, client), daemon=True).start()

    def cut(seconds: float) -> int:
        proxy["down_until"] = time.time() + seconds
        with proxy["lock"]:
            conns, proxy["conns"] = list(proxy["conns"]), set()
        for c in conns:
            try:
                c.shutdown(net.SHUT_RDWR)
                c.close()
            except OSError:
                pass
        return len(conns)

    if args.proxy_port:
        threading.Thread(target=serve_proxy, args=(args.proxy_port,), daemon=True).start()

    def owner() -> Socket:
        ws = Socket(args.port)
        ws.request("hello", protocol_version=2, token=token, client="flotilla-qa-other-client")
        return ws

    def raw(ws: Socket, kind: str, **fields):
        ws.next += 1
        ws.send({"type": kind, "req_id": str(ws.next), **fields})
        while True:
            reply = ws.receive()
            if reply.get("req_id") == str(ws.next):
                return reply

    def release(name: str):
        db = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True)
        db.row_factory = sqlite3.Row
        r = db.execute("select * from release where name=?", (name,)).fetchone()
        if r is None:
            return None, db
        return dict(r), db

    def state(name: str):
        r, db = release(name)
        if r is None:
            return {"error": f"no release {name}"}
        items = [dict(i) for i in db.execute(
            "select item_id, verdict, owner_note from release_item where release_id=? order by item_id", (r["id"],))]
        d = db.execute("select state, ruling_text, answered_by from decision where id=?", (r["decision_id"],)).fetchone()
        events = [dict(e) for e in db.execute(
            "select kind, actor, note from release_event where release_id=? order by at", (r["id"],))]
        return {"id": r["id"], "status": r["status"], "version": r["version"], "held_note": r["held_note"],
                "remind_at": r["remind_at"], "items": items, "decision": dict(d) if d else None, "events": events}

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self) -> None:
            url = urlparse(self.path)
            name = parse_qs(url.query).get("name", [""])[0]
            try:
                if url.path == "/cut":
                    seconds = float(parse_qs(url.query).get("seconds", ["2"])[0])
                    body = {"dropped": cut(seconds), "seconds": seconds}
                elif url.path in ("/freeze", "/thaw"):
                    pid = int(open(args.daemon_pid_file).read().strip())
                    os.kill(pid, signal.SIGSTOP if url.path == "/freeze" else signal.SIGCONT)
                    body = {"pid": pid, "done": url.path[1:]}
                elif url.path == "/state":
                    body = state(name)
                elif url.path == "/bump":
                    r, _ = release(name)
                    ws = owner()
                    held = raw(ws, "release_hold", release_id=r["id"], note="QA-007: changed by another client")
                    back = raw(ws, "release_unhold", release_id=r["id"])
                    body = {"hold": held.get("type"), "unhold": back.get("type"), "before": r["version"],
                            "after": state(name)["version"], "status": state(name)["status"]}
                elif url.path == "/stale":
                    r, db = release(name)
                    items = [i[0] for i in db.execute("select item_id from release_item where release_id=?", (r["id"],))]
                    reply = raw(owner(), "release_rule", release_id=r["id"], expected_version=r["version"] + 1,
                                verdicts=[{"item_id": i, "verdict": "ship"} for i in items])
                    body = {"reply": reply}
                else:
                    self.send_response(404); self.end_headers(); return
                data = json.dumps(body).encode()
                self.send_response(200)
            except Exception as e:  # noqa: BLE001
                data = json.dumps({"error": repr(e)}).encode()
                self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *a) -> None:
            sys.stderr.write("scratch_control: " + (a[0] % a[1:]) + "\n")

    ThreadingHTTPServer(("127.0.0.1", args.control_port), Handler).serve_forever()


if __name__ == "__main__":
    main()
