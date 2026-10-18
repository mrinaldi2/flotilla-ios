#!/usr/bin/env python3
"""A made-up team for trying Flotilla on the phone without your own bots.

Starts a throwaway gravityd in its own folder with the deterministic "double"
runtime (no Claude sessions, no tokens spent), creates two projects and eight
bots, has them raise decisions, writes Claude Code style logs and reports for
Gravity Lens to read, and optionally serves the lot:

    python3 demo/make_demo.py --serve

Nothing outside the output folder (default /tmp/flotilla-demo) is touched.
Everything in it is fiction. Standard library only.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "assets")
LENS = os.path.join(HERE, "..", "companion", "gravity_lens.py")
NOW = datetime.now(timezone.utc)


# ---------------------------------------------------------------- daemon

class Socket:
    """Just enough WebSocket for the daemon's control plane."""

    def __init__(self, port: int):
        self.port = port
        self.hello: Optional[Dict[str, Any]] = None
        self.connect()

    def connect(self) -> None:
        self.sock = socket.create_connection(("127.0.0.1", self.port), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((f"GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                           f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        self.reader = self.sock.makefile("rb")
        if b" 101 " not in self.reader.readline():
            raise SystemExit("gravityd refused the WebSocket upgrade")
        while self.reader.readline() not in (b"\r\n", b""):
            pass
        self.next = 0

    def send(self, message: Dict[str, Any]) -> None:
        self.frame(0x81, json.dumps(message).encode())

    def frame(self, first: int, payload: bytes) -> None:
        mask = os.urandom(4)
        header = bytearray([first])
        if len(payload) < 126:
            header.append(0x80 | len(payload))
        elif len(payload) < 65536:
            header += bytes([0x80 | 126]) + len(payload).to_bytes(2, "big")
        else:
            header += bytes([0x80 | 127]) + len(payload).to_bytes(8, "big")
        self.sock.sendall(bytes(header) + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def receive(self) -> Dict[str, Any]:
        data = b""
        while True:
            first = self.reader.read(2)
            length = first[1] & 0x7F
            if length == 126:
                length = int.from_bytes(self.reader.read(2), "big")
            elif length == 127:
                length = int.from_bytes(self.reader.read(8), "big")
            payload = self.reader.read(length)
            if first[0] & 0x0F == 0x9:
                self.frame(0x8A, payload)  # pong, or the daemon closes a silent client after 60s
                continue
            if first[0] & 0x0F >= 0x8:
                continue  # another control frame between messages
            data += payload
            if first[0] & 0x80:
                break
        return json.loads(data)

    def request(self, kind: str, **fields: Any) -> Dict[str, Any]:
        if kind == "hello":
            self.hello = fields
        try:
            return self.exchange(kind, **fields)
        except (BrokenPipeError, ConnectionResetError, json.JSONDecodeError, IndexError):
            # The daemon closes a client that was silent for 60s, as this one is
            # while the demo writes logs and waits on bots: reconnect and go on.
            self.sock.close()
            self.connect()
            if self.hello is not None and kind != "hello":
                self.exchange("hello", **self.hello)
            return self.exchange(kind, **fields)

    def exchange(self, kind: str, **fields: Any) -> Dict[str, Any]:
        self.next += 1
        req_id = str(self.next)
        self.send({"type": kind, "req_id": req_id, **fields})
        while True:
            reply = self.receive()
            if reply.get("req_id") == req_id:
                if reply.get("type") == "error":
                    raise SystemExit(f"{kind} failed: {reply.get('message')}")
                return reply


def find_gravityd(explicit: Optional[str]) -> str:
    for path in (explicit, os.path.expanduser("~/.flotilla/bin/flotillad"),
                 os.path.expanduser("~/.thehermes/bin/hermesd"), os.path.expanduser("~/.gravity/bin/gravityd"),
                 "/Applications/Gravity.app/Contents/MacOS/gravityd"):
        if path and os.access(path, os.X_OK):
            return path
    raise SystemExit("no daemon found: install Flotilla on this Mac or pass --gravityd")


def healthy(port: int) -> bool:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=1) as response:
            return response.status == 200
    except OSError:
        return False


# Every process the demo starts, one pid per line, so whoever ran it can stop
# exactly those (scripts/ui-tests.sh does) even when the demo itself died.
PIDS: Optional[str] = None


def remember(process: subprocess.Popen) -> None:
    if PIDS:
        with open(PIDS, "a") as handle:
            handle.write(f"{process.pid}\n")


def start_daemon(gravityd: str, out: str, port: int) -> subprocess.Popen:
    home = os.path.join(out, "gravity")
    os.makedirs(home, exist_ok=True)
    config = os.path.join(out, "gravityd.toml")
    with open(config, "w") as handle:
        # user_home: where the daemon reads Claude Code transcripts (~/.claude/projects),
        # for daemons that serve the chat themselves.
        handle.write(f'home = "{home}"\nuser_home = "{os.path.join(out, "user-home")}"\n'
                     f'bind = ["127.0.0.1"]\nport = {port}\nnegotiate_port = false\nruntime = "double"\n'
                     # Prompts wait an hour, long enough to look at them.
                     'permission_timeout_seconds = 3600\n')
    log = open(os.path.join(out, "gravityd.log"), "ab")
    daemon = subprocess.Popen([gravityd, "--config", config], stdout=log, stderr=log)
    remember(daemon)
    for _ in range(50):
        if healthy(port):
            return daemon
        time.sleep(0.2)
    daemon.kill()
    raise SystemExit(f"the demo daemon did not start; see {out}/gravityd.log")


def bot_tool(port: int, home: str, bot_id: str, tool: str, **arguments: Any) -> Dict[str, Any]:
    """What bots do on the bus (decisions, tasks) goes through their MCP tools, with the bot's token."""
    with open(os.path.join(home, "secrets", f"bot-{bot_id}.token")) as handle:
        token = handle.read().strip()
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                       "params": {"name": tool, "arguments": arguments}}).encode()
    request = urllib.request.Request(f"http://127.0.0.1:{port}/mcp", data=body, headers={
        "Authorization": f"Bearer {token}", "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream"})
    reply = json.loads(urllib.request.urlopen(request, timeout=10).read())
    try:
        return json.loads(reply["result"]["content"][0]["text"])
    except (KeyError, IndexError, ValueError):
        return {}


def gated(refusal: SystemExit) -> bool:
    """A step newer daemons keep from the owner token (0.17.4: H-205, approve capability)."""
    return "capability" in str(refusal) or "owner" in str(refusal)


def skip(out: str, step: str, refusal: SystemExit) -> None:
    """Leave out a demo step the daemon refuses, say so, and list it in out/skipped for the
    tests (scripts/ui-tests.sh passes it as DEMO_SKIPPED). A proper demo path is H-234."""
    print(f"  skipped {step}: {refusal}")
    with open(os.path.join(out, "skipped"), "a") as handle:
        handle.write(step + "\n")


def spawn_workers(ws: "Socket", port: int, home: str, out: str, bots: Dict[str, Dict[str, str]]) -> None:
    """Temporary workers for daemons that have them: Aurora Notes shares a git
    repository, Tech Writer splits the user guide into chapters past the cap
    of four, one chapter is finished and pushed, one is cancelled, and two
    wait in the queue."""
    if not shutil.which("git"):
        return
    repo = os.path.join(out, "notes-repo.git")
    seed = os.path.join(out, "notes-seed")
    git = ["git", "-c", "user.name=Demo", "-c", "user.email=demo@example.com"]
    subprocess.run(["git", "init", "-q", "--bare", "-b", "main", repo], check=True)
    subprocess.run(["git", "init", "-q", "-b", "main", seed], check=True)
    with open(os.path.join(seed, "README.md"), "w") as handle:
        handle.write("# Aurora Notes\n\nThe user guide lives in docs/guide.\n")
    subprocess.run(git + ["-C", seed, "add", "."], check=True)
    subprocess.run(git + ["-C", seed, "commit", "-qm", "Start the guide"], check=True)
    subprocess.run(["git", "-C", seed, "push", "-q", repo, "main"], check=True)
    shutil.rmtree(seed)

    project = next(p for p in ws.request("list_projects")["projects"] if p["name"] == "Aurora Notes")
    try:
        ws.request("set_project_repo", project_id=project["id"], url=repo, branch="main")
    except SystemExit as refusal:
        if not gated(refusal):
            raise
        skip(out, "project-repo", refusal)  # the workers below commit to that repo
        return
    chapters = ["Getting started", "Sync across devices", "Working offline", "When edits conflict",
                "Sharing a notebook", "Search", "Shortcuts", "Privacy and backups"]
    for number, title in enumerate(chapters, 1):
        bot_tool(port, home, bots["Tech Writer"]["id"], "spawn_worker", name=f"ch-{number}",
                 task=f"Write chapter {number} of the user guide, \"{title}\", in docs/guide/ch-{number}.md. "
                      "Plain words, one screenshot at most, under 600 words.")

    def running(name: str) -> Dict[str, Any]:
        workers = ws.request("list_workers", project_id=project["id"])["workers"]
        return next(w for w in workers if w["name"] == name)

    def write(worker: Dict[str, Any], text: str) -> None:
        bot = next(b for b in ws.request("list_bots")["bots"] if b["id"] == worker["bot_id"])
        folder = os.path.join(bot["workspace_path"], "repo", "docs", "guide")
        os.makedirs(folder, exist_ok=True)
        with open(os.path.join(folder, f"{worker['name']}.md"), "w") as handle:
            handle.write(text)

    # Chapter 1 is finished: the daemon commits it, pushes it, and says so in the result.
    first = running("ch-1")
    write(first, "# Getting started\n\nCreate a notebook, then a note.\n")
    bot_tool(port, home, first["bot_id"], "complete_task", task_id=first["task_id"],
             result="Chapter 1 is written: creating a notebook and a first note, in docs/guide/ch-1.md.")
    # Chapter 2 is cancelled halfway: its work is saved on a branch of its own.
    second = running("ch-2")
    write(second, "# Sync across devices\n\nDraft.\n")
    ws.request("cancel_worker", worker_id=second["id"], reason="The sync chapter waits for the new engine.")
    time.sleep(4)


def link_peer(ws: "Socket", out: str, gravityd: str, port: int, project_id: str) -> Optional[subprocess.Popen]:
    """A second throwaway gravityd, "Studio PC", peered with the demo one and linked
    into one project, so the app has a link to show (and to unlink)."""
    peer_out = os.path.join(out, "peer")
    if os.path.exists(peer_out):
        shutil.rmtree(peer_out)
    peer = start_daemon(gravityd, peer_out, port)
    with open(os.path.join(peer_out, "gravity", "secrets", "client.token")) as handle:
        other = Socket(port)
        other.request("hello", protocol_version=2, token=handle.read().strip(), client="flotilla-demo")
    try:
        invite = other.request("create_peer_invite", name="Demo Mac", url=f"ws://127.0.0.1:{port}/peer")["invite"]
    except SystemExit as refusal:
        if not gated(refusal):
            raise
        skip(out, "peer-link", refusal)
        peer.terminate()
        return None
    peer_id = ws.request("add_peer", name="Studio PC", invite=invite)["peer"]["id"]
    for _ in range(50):
        if any(p["id"] == peer_id and p.get("online") for p in ws.request("list_peers")["peers"]):
            break
        time.sleep(0.2)
    ws.request("link_project", project_id=project_id, peer_id=peer_id)
    return peer


PROMPTS = [
    ("Backend Dev", "Bash", {"command": "rm -rf build/ && npm ci",
                             "description": "Clean install before the release build"}),
    ("iOS Dev", "Write", {"file_path": "Sources/Sync/ConflictBanner.swift",
                          "content": "import SwiftUI\n\nstruct ConflictBanner: View {\n    // …\n}\n"}),
    ("Web Dev", "WebFetch", {"url": "https://example.com/pricing", "prompt": "Compare the plans"}),
]


def bot_token(home: str, bot_id: str) -> str:
    with open(os.path.join(home, "secrets", f"bot-{bot_id}.token")) as handle:
        return handle.read().strip()


def ask(port: int, home: str, bot_id: str, tool: str, tool_input: Dict[str, Any]) -> None:
    """One prompt, posted the way Claude Code's PermissionRequest hook does. It
    blocks until answered, so it runs on a thread of its own."""
    def post() -> None:
        body = json.dumps({"tool_name": tool, "tool_input": tool_input, "permission_suggestions": []}).encode()
        request = urllib.request.Request(f"http://127.0.0.1:{port}/hook/permission", data=body, headers={
            "Authorization": f"Bearer {bot_token(home, bot_id)}", "Content-Type": "application/json"})
        try:
            urllib.request.urlopen(request, timeout=3700).read()
        except OSError:
            pass
    threading.Thread(target=post, daemon=True).start()


def ask_permissions(port: int, home: str, bots: Dict[str, Dict[str, str]]) -> None:
    """Bots waiting on the owner: the daemon holds each prompt for an app to answer."""
    for number, (bot, tool, tool_input) in enumerate(PROMPTS):
        ask(port, home, bots[bot]["id"], tool, tool_input)
        time.sleep(1.2 if number < len(PROMPTS) - 1 else 0.5)


def hold_permissions(port: int, token: str) -> None:
    """The daemon holds a prompt for the app only while a client that can answer
    one is connected; between two app launches nobody is, and the prompts would
    go back to the bots' terminals. This client stays connected for the demo's
    life (reading keeps it answering pings)."""
    def run() -> None:
        while True:
            try:
                holder = Socket(port)
                holder.request("hello", protocol_version=2, token=token, client="flotilla-demo-holder",
                               features=["permission_cards", "terminal_card", "owner_actions", "decision_grants"])
                while True:
                    holder.receive()
            except (OSError, ValueError, IndexError):
                time.sleep(1)
    threading.Thread(target=run, daemon=True).start()


def bot_call(port: int, home: str, bot_id: str, tool: str, **arguments: Any) -> Dict[str, Any]:
    """A bot's MCP tool, with its error kept: {"ok": bool, "text": …, "data": parsed text or None}."""
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                       "params": {"name": tool, "arguments": arguments}}).encode()
    request = urllib.request.Request(f"http://127.0.0.1:{port}/mcp", data=body, headers={
        "Authorization": f"Bearer {bot_token(home, bot_id)}", "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream"})
    reply = json.loads(urllib.request.urlopen(request, timeout=20).read())
    if "error" in reply:
        return {"ok": False, "text": json.dumps(reply["error"]), "data": None}
    result = reply.get("result", {})
    text = "".join(part.get("text", "") for part in result.get("content", []))
    try:
        data = json.loads(text)
    except ValueError:
        data = None
    return {"ok": not result.get("isError", False), "text": text, "data": data}


# The 0.17 flows (UI tests, on demand): a project whose bots have board roles by name.
LAB = ("Flotilla Lab", [
    ("Team Lead", "icon:orbit", "Leads Flotilla Lab: plans releases and runs the stand-up."),
    ("Desktop Dev", "icon:ember", "Builds the desktop app for Flotilla Lab."),
    ("DevOps", "icon:frost", "Ships Flotilla Lab: builds, installs and restarts."),
])


def serve_control(control_port: int, port: int, home: str, token: str, bots: Dict[str, Dict[str, str]],
                  daemon_pid: int = 0) -> None:
    """A small HTTP endpoint for UI tests to set the demo up per test (127.0.0.1 only):

    POST /permissions          the 3 demo prompts are pending again (missing ones re-asked)
    POST /approval?bot=<name>  that bot waits on a permission prompt in its own terminal

    0.17 daemons, in the "Flotilla Lab" project (created on first use):
    POST /lab                  the project and its bots; {"project_id", "caps"}
    POST /grants               Team Lead raises a decision whose first option grants extras
    POST /runcard              Desktop Dev proposes a Run card (owner action)
    POST /question             Desktop Dev asks the owner a question (owner thread)
    POST /items                Desktop Dev files 3 board items labelled platform:… and area:… (the
                               board must exist: open it first)
    POST /proposal             0.19: Team Lead proposes a new board; {"decision_id", "board"} of the
                               decision it raises (the board must exist: open it first)
    POST /terminal             a terminal command asks to act as the owner (H-108), from
                               inside Desktop Dev's workspace; held until answered or timed out
    POST /pins                 {"pinned": [project names]} from projects_overview
    POST /questions            0.22 (questions_v1): Team Lead files a spike and asks three questions on
                               it with ask_owner, one with options and a recommendation;
                               {"item_id", "questions": [ids]}
                               (both start the Lab's board when it has none)
    POST /artifacts            0.22 (artifacts_v2): files in each group of the lab's artifacts, one
                               attached to a new card; {"item_id", "loose": [paths], "used": path}
    POST /freeze, /thaw        pause and resume the demo daemon (SIGSTOP/SIGCONT), so a
                               request from the app fails as a connection error would
    """
    lab: Dict[str, Any] = {}

    caps: List[str] = []

    def owner() -> "Socket":
        ws = Socket(port)
        hello = ws.request("hello", protocol_version=2, token=token, client="flotilla-demo-control",
                           features=["permission_cards", "terminal_card", "owner_actions", "decision_grants"])
        caps[:] = hello.get("capabilities", [])
        return ws

    def ensure_lab() -> Dict[str, Any]:
        if lab:
            return lab
        ws = owner()
        projects = {p["name"]: p for p in ws.request("list_projects")["projects"]}
        project = projects.get(LAB[0]) or ws.request("create_project", name=LAB[0])["project"]
        existing = {b["name"]: b for b in ws.request("list_bots", project_id=project["id"])["bots"]}
        lab_bots: Dict[str, Dict[str, str]] = {}
        for name, avatar, description in LAB[1]:
            bot = existing.get(name) or ws.request("create_bot", project_id=project["id"], name=name, avatar=avatar,
                                                   description=description, instructions=description)["bot"]
            lab_bots[name] = {"id": bot["id"], "workspace": os.path.join(home, "projects", project["dir_name"],
                                                                         "bots", bot["dir_name"], "workspace")}
        for _ in range(50):  # the bots' tokens are written as they start
            if all(os.path.exists(os.path.join(home, "secrets", f"bot-{b['id']}.token")) for b in lab_bots.values()):
                break
            time.sleep(0.2)
        # 0.19 gives no board role by a bot's name: a new board gives the project's lead the lead
        # role. Named before any board starts; a daemon without the request keeps its own rules.
        try:
            ws.request("set_project_lead", project_id=project["id"], bot_id=lab_bots["Team Lead"]["id"])
        except (Exception, SystemExit):
            pass
        lab.update(project_id=project["id"], bots=lab_bots, caps=list(caps))
        return lab

    def ensure_board(project_id: str) -> None:
        """The board, started as an app's first board_watch starts it (a binary BoardRequest:
        Envelope{req_id: 1, board_request{board_watch{project_id}}}), so seeds can file cards."""
        def field(number: int, payload: bytes) -> bytes:
            return bytes([number << 3 | 2, len(payload)]) + payload
        ws = owner()
        ws.frame(0x82, b"\x08\x01" + field(2, field(7, field(1, project_id.encode()))))
        time.sleep(1)
        ws.sock.close()

    def terminal_request(cwd: str) -> None:
        """What `hermesd peer …` does from a terminal: hermes/owner_request on the bus socket,
        from a process whose working folder is cwd (the daemon reads the origin from it)."""
        path = os.path.join(home, "run", "bus.sock")
        try:
            with open(os.path.join(home, "run", "endpoint")) as handle:
                path = handle.read().strip() or path
        except OSError:
            pass
        script = ("import json, socket, sys\n"
                  "c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); c.settimeout(3700); c.connect(sys.argv[1])\n"
                  "c.sendall(json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'hermes/owner_request',"
                  " 'params': {'command': 'git push --force origin main', 'cwd': sys.argv[2]}}).encode() + b'\\n')\n"
                  "c.recv(65536)\n")
        remember(subprocess.Popen([sys.executable, "-c", script, path, cwd], cwd=cwd,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))

    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    from urllib.parse import parse_qs, urlparse

    def pending() -> List[Dict[str, Any]]:
        return owner().request("list_permissions")["permissions"]

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self) -> None:
            url = urlparse(self.path)
            query = parse_qs(url.query)
            try:
                if url.path == "/permissions":
                    # A prompt about to expire would vanish mid-test (0.17 holds one for 14 min):
                    # deny those first and raise them fresh.
                    now = datetime.now(timezone.utc)
                    demo_ids = {bots[b]["id"] for b, _, _ in PROMPTS}
                    for prompt in pending():
                        expires = prompt.get("expires_at")
                        if prompt.get("bot_id") in demo_ids and expires and \
                                datetime.fromisoformat(expires.replace("Z", "+00:00")) - now < timedelta(minutes=4):
                            owner().request("answer_permission", request_id=prompt["id"], decision="deny",
                                            reason="UI tests: raised fresh")
                    time.sleep(0.5)
                    waiting = {(p["bot_id"], p["tool"]) for p in pending()}
                    for bot, tool, tool_input in PROMPTS:
                        if (bots[bot]["id"], tool) not in waiting:
                            ask(port, home, bots[bot]["id"], tool, tool_input)
                    for _ in range(50):
                        waiting = {(p["bot_id"], p["tool"]) for p in pending()}
                        if all((bots[b]["id"], t) in waiting for b, t, _ in PROMPTS):
                            break
                        time.sleep(0.2)
                    demo = {(bots[b]["id"], t) for b, t, _ in PROMPTS}
                    reply: Dict[str, Any] = {"pending": len(waiting & demo)}  # not a held terminal request
                elif url.path == "/approval":
                    bot = bots[query["bot"][0]]["id"]
                    body = json.dumps({"hook_event_name": "Notification",
                                       "message": "Claude needs your permission to use Bash"}).encode()
                    urllib.request.urlopen(urllib.request.Request(
                        f"http://127.0.0.1:{port}/hook", data=body, headers={
                            "Authorization": f"Bearer {bot_token(home, bot)}",
                            "Content-Type": "application/json"}), timeout=10).read()
                    reply = {"ok": True}
                elif url.path == "/lab":
                    info = ensure_lab()
                    reply = {"project_id": info["project_id"], "caps": info["caps"]}
                elif url.path == "/proposal":
                    info = ensure_lab()
                    name = f"Research {int(time.time()) % 100000}"
                    made = bot_call(port, home, info["bots"]["Team Lead"]["id"], "board_create", name=name, preset="simple")
                    if not made.get("ok"):
                        raise RuntimeError(f"board_create: {made}")
                    raised = [d for d in owner().request("list_decisions")["decisions"]
                              if d["title"].startswith("Board change proposed") and name in d["title"]]
                    reply = {"decision_id": raised[0]["id"] if raised else None, "board": name}
                elif url.path in ("/grants", "/runcard", "/question", "/items", "/terminal"):
                    info = ensure_lab()
                    lead, dev = info["bots"]["Team Lead"], info["bots"]["Desktop Dev"]
                    if url.path == "/grants":
                        reply = bot_call(port, home, lead["id"], "raise_decision", kind="decision",
                                         title="Let DevOps install 0.17.1 and Desktop Dev publish the notes?",
                                         body="The release is verified. Installing and publishing need your grant.",
                                         options=[{"key": "grant", "label": "Grant both",
                                                   "description": "DevOps installs, Desktop Dev publishes.",
                                                   "grants": [{"bot": "DevOps", "extra": "install"},
                                                              {"bot": "Desktop Dev", "extra": "publish"}]},
                                                  {"key": "wait", "label": "Not yet"}],
                                         recommendation="grant")
                    elif url.path == "/runcard":
                        reply = bot_call(port, home, dev["id"], "propose_owner_action", content="rm -rf ~/Library/Caches/flotilla-lab",
                                         reason="Clear the stale build cache", cwd=dev["workspace"])
                    elif url.path == "/question":
                        reply = bot_call(port, home, dev["id"], "message_owner", asks=True,
                                         body="Should the release notes mention the new board?")
                    elif url.path == "/items":
                        # 0.19: the lead gives Desktop Dev its role, which no name gives any more (a
                        # 0.18 daemon gave it by name and may refuse this).
                        bot_call(port, home, lead["id"], "role_set", bot="Desktop Dev", role="dev")
                        made = []
                        # Labels, never platforms (0.19 K8); a 0.18 daemon keeps them as free labels.
                        for title, labels in [("Board chips on iPad", ["platform:ios", "area:board"]),
                                              ("Owner threads read marks", ["platform:desktop", "area:threads"]),
                                              ("Terminal card copy", ["platform:ios", "area:terminal"])]:
                            made.append(bot_call(port, home, dev["id"], "item_create", type="chore", title=title,
                                                 description="QA seed item.", labels=labels))
                        reply = {"ok": all(m["ok"] for m in made), "items": made}
                    else:
                        terminal_request(dev["workspace"])
                        reply = {"ok": True}
                elif url.path == "/questions" and "questions" in lab:
                    # Asked once per demo: the daemon refuses the same question twice.
                    reply = lab["questions"]
                elif url.path == "/questions":
                    info = ensure_lab()
                    ensure_board(info["project_id"])
                    lead = info["bots"]["Team Lead"]["id"]
                    made = bot_call(port, home, lead, "item_create", type="spike", title="Saints dataset: sources and licensing",
                                    description="Research the sources and licensing for the saints dataset.")
                    if not made.get("ok"):
                        raise RuntimeError(f"item_create: {made}")
                    item = (made.get("data") or {}).get("item", made.get("data") or {}).get("id")
                    # Each with its why: flotilla#66 refuses a question without one ("'body' is required").
                    asked = bot_call(port, home, lead, "ask_owner", item_id=item, questions=[
                        {"text": "Should v1 cover only the ~250 celebrated saints, or the full Martyrology?",
                         "why": "It sets the dataset's size and the licensing work.",
                         "options": [{"key": "celebrated", "label": "The ~250 celebrated saints",
                                      "description": "A smaller dataset we can check by hand."},
                                     {"key": "full", "label": "The full Martyrology (~7,000)"}],
                         # Not blocking: only a question on a plan node may block, and the Lab doesn't plan.
                         "recommendation": "celebrated"},
                        {"text": "Italy plus the universal calendar only?",
                         "why": "Each national calendar adds its own feasts.",
                         "options": [{"key": "yes", "label": "Yes, Italy and universal"},
                                     {"key": "more", "label": "Add other national calendars"}]},
                        {"text": "May we contact the LEV and the CEI about licensing?",
                         "why": "They hold the rights to the official texts."},
                    ])
                    if not asked.get("ok"):
                        raise RuntimeError(f"ask_owner: {asked}")
                    reply = {"item_id": item, "questions": [q["id"] for q in (asked.get("data") or {}).get("questions", [])]}
                    lab["questions"] = reply
                elif url.path == "/artifacts":
                    info = ensure_lab()
                    ensure_board(info["project_id"])
                    lead = info["bots"]["Team Lead"]["id"]
                    project = next(p for p in owner().request("list_projects")["projects"] if p["id"] == info["project_id"])
                    folder = os.path.join(home, "projects", project["dir_name"], "artifacts")
                    files = {"refs/old-sources.md": "# Old sources\n\nA first list, superseded.\n",
                             "refs/scratch-notes.md": "# Scratch\n\nNotes nobody uses.\n",
                             "refs/draft-table.md": "# Draft table\n\n| Saint | Day |\n",
                             "refs/saints-calendar.md": "# Saints calendar\n\nThe universal calendar, by month.\n",
                             "uploads/sketch.md": "# Sketch\n\nSent from the phone.\n",
                             "checks/0a1b2c3d4e5f-lint.log": "lint: 0 problems\n"}
                    for rel, text in files.items():
                        os.makedirs(os.path.dirname(os.path.join(folder, rel)), exist_ok=True)
                        with open(os.path.join(folder, rel), "w") as handle:
                            handle.write(text)
                    made = bot_call(port, home, lead, "item_create", type="task", title="Calendar view of the saints",
                                    description="Show the saints by month.")
                    if not made.get("ok"):
                        raise RuntimeError(f"item_create: {made}")
                    item = (made.get("data") or {}).get("item", made.get("data") or {}).get("id")
                    attached = bot_call(port, home, lead, "item_attach", id=item, artifact="refs/saints-calendar.md")
                    if not attached.get("ok"):
                        raise RuntimeError(f"item_attach: {attached}")
                    reply = {"item_id": item, "loose": ["refs/old-sources.md", "refs/scratch-notes.md", "refs/draft-table.md"],
                             "used": "refs/saints-calendar.md"}
                elif url.path in ("/freeze", "/thaw"):
                    if not daemon_pid:
                        raise RuntimeError("no daemon pid")
                    os.kill(daemon_pid, signal.SIGSTOP if url.path == "/freeze" else signal.SIGCONT)
                    reply = {"ok": True}
                elif url.path == "/pins":
                    rows = owner().request("projects_overview", project_ids=[])["overview"].get("rows", [])
                    reply = {"pinned": [r["name"] for r in rows if r.get("pinned")]}
                else:
                    self.send_error(404)
                    return
            except (Exception, SystemExit) as error:  # the test reads the reason (Socket raises SystemExit)
                self.send_error(500, str(error))
                return
            data = json.dumps(reply).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *args: Any) -> None:
            pass

    server = ThreadingHTTPServer(("127.0.0.1", control_port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()


def raise_decision(port: int, home: str, bot_id: str, **arguments: Any) -> None:
    bot_tool(port, home, bot_id, "raise_decision", **arguments)


def hand_out_tasks(port: int, home: str, bots: Dict[str, Dict[str, str]]) -> None:
    """Work bots gave each other, for the Tasks tab: open, waiting and done."""
    def send(sender: str, to: str, body: str, hours: int = 24) -> str:
        return bot_tool(port, home, bots[sender]["id"], "send_message", to=to, kind="task", body=body,
                        deadline_hours=hours).get("task_id", "")

    send("iOS Dev", "QA Tester", "Run the sync suite on build 142 on the SE and the 15, and report every layout "
         "bug in the conflict banner with a screenshot.", hours=8)
    send("QA Tester", "Backend Dev", "The SE run needs a sync server with two devices' worth of conflicting edits. "
         "Can you seed the staging server with the conflict fixtures?", hours=4)
    schema = send("Architect", "Backend Dev", "Write the conflict resolution note for the sync server. It should "
                  "cover:\n\n1. **Vector clocks** per note: how they are stored, merged and compacted.\n"
                  "2. **Last-writer-wins** for titles and tags, and why bodies are different.\n"
                  "3. The **three-way merge** for bodies when edits do not overlap, with the paragraph as the unit.\n"
                  "4. What the server sends the app when it cannot merge, so the banner can show both versions.\n"
                  "5. The migration for notes written before clocks existed.\n\n"
                  "Put it in the artifacts as sync-conflicts.md and keep it under two pages.")
    bot_tool(port, home, bots["Backend Dev"]["id"], "complete_task", task_id=schema, result=(
        "Done: **sync-conflicts.md** is in the artifacts.\n\n"
        "- Each note carries a vector clock keyed by device, merged element-wise and compacted when a device has "
        "been silent for 90 days.\n- Titles and tags are last-writer-wins on the clock; bodies are not, because a "
        "lost paragraph is worse than a banner.\n- Bodies merge three ways by paragraph when edits do not overlap.\n"
        "- When they do, the server answers `409 conflict` with both versions and their clocks, which is exactly "
        "what the banner needs.\n- Old notes get a clock of zero on first sync, so any edit wins over them.\n\n"
        "The test fixtures cover all five cases."), artifacts=["sync-conflicts.md"])
    copy = send("Designer", "Copywriter", "Two lines for the conflict banner: one for 'edited on two devices', "
                "one for the merge that worked.")
    bot_tool(port, home, bots["Copywriter"]["id"], "complete_task", task_id=copy,
             result="\"This note changed on two devices. Keep both?\" and \"Merged edits from your other device.\"")


# ---------------------------------------------------------------- logs

def stamp(minutes_ago: float) -> str:
    return (NOW - timedelta(minutes=minutes_ago)).strftime("%Y-%m-%dT%H:%M:%S.") + "000Z"


class Log:
    """Writes one bot's Claude Code session log, turn by turn."""

    def __init__(self) -> None:
        self.records: List[Dict[str, Any]] = []
        self.clock = 0.0
        self.started = 0.0

    def _add(self, record: Dict[str, Any], seconds: float = 20) -> None:
        self.clock -= seconds / 60
        record.setdefault("uuid", str(uuid.uuid4()))
        record["timestamp"] = stamp(max(self.clock, 0.05))
        self.records.append(record)

    def message(self, minutes_ago: float, sender: str, kind: str, num: int, text: str) -> "Log":
        self.clock = self.started = minutes_ago
        self._add({"type": "user", "isMeta": True, "message": {"role": "user", "content":
                   f"Another Claude session sent a message:\n[msg #{num} from {sender.upper()} · {kind}] {text}"}}, 0)
        return self

    def typed(self, minutes_ago: float, text: str) -> "Log":
        self.clock = self.started = minutes_ago
        self._add({"type": "user", "message": {"role": "user", "content": text}}, 0)
        return self

    def say(self, text: str) -> "Log":
        self._add({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}})
        return self

    def tool(self, name: str, arguments: Dict[str, Any], output: Optional[str] = None,
             result: Optional[Dict[str, Any]] = None, content: Any = None, error: bool = False) -> "Log":
        tool_id = "toolu_" + uuid.uuid4().hex[:20]
        self._add({"type": "assistant", "message": {"role": "assistant", "content": [
            {"type": "tool_use", "id": tool_id, "name": name, "input": arguments}]}}, 15)
        if output is None and result is None and content is None:
            return self  # still running
        block = {"type": "tool_result", "tool_use_id": tool_id, "content": content if content is not None else output or ""}
        if error:
            block["is_error"] = True
        self._add({"type": "user", "message": {"role": "user", "content": [block]},
                   "toolUseResult": result if result is not None else {"stdout": output or "", "stderr": ""}}, 25)
        return self

    def bash(self, description: str, command: str, output: Optional[str], error: bool = False) -> "Log":
        return self.tool("Bash", {"command": command, "description": description}, output=output,
                         result=None if output is None else {"stdout": output, "stderr": "", "interrupted": False},
                         error=error)

    def read(self, path: str, lines: int = 120) -> "Log":
        return self.tool("Read", {"file_path": path}, output=f"{lines} lines")

    def look(self, path: str, image: str) -> "Log":
        with open(image, "rb") as handle:
            data = base64.b64encode(handle.read()).decode()
        return self.tool("Read", {"file_path": path}, content=[{"type": "image", "source": {
            "type": "base64", "media_type": "image/png", "data": data}}], result={"type": "image"})

    def edit(self, path: str, start: int, lines: List[str]) -> "Log":
        old = sum(1 for line in lines if not line.startswith("+"))
        new = sum(1 for line in lines if not line.startswith("-"))
        return self.tool("Edit", {"file_path": path, "old_string": "…", "new_string": "…"}, result={
            "filePath": path, "structuredPatch": [{"oldStart": start, "oldLines": old, "newStart": start,
                                                   "newLines": new, "lines": lines}]}, output="ok")

    def send(self, to: str, kind: str, body: str) -> "Log":
        return self.tool("mcp__gravity-bus__send_message", {"to": to, "kind": kind, "body": body}, output="sent")

    def incoming(self, sender: str, kind: str, num: int, text: str) -> "Log":
        self._add({"type": "attachment", "attachment": {"type": "queued_command",
                   "prompt": f"[msg #{num} from {sender.upper()} · {kind}] {text}"}})
        return self

    def complete(self, result: str, artifacts: List[str]) -> "Log":
        return self.tool("mcp__gravity-bus__complete_task", {"task_id": str(uuid.uuid4()), "result": result,
                                                             "artifacts": artifacts}, output="completed")

    def end(self) -> "Log":
        self._add({"type": "system", "subtype": "turn_duration",
                   "durationMs": int((self.started - self.clock) * 60_000) + 4000}, 2)
        return self

    def write(self, folder: str) -> None:
        os.makedirs(folder, exist_ok=True)
        with open(os.path.join(folder, f"{uuid.uuid4()}.jsonl"), "w") as handle:
            for record in self.records:
                handle.write(json.dumps(record) + "\n")


def project_folder(workspace: str) -> str:
    """Claude Code's folder name: every character but letters and digits becomes "-"."""
    return re.sub(r"[^A-Za-z0-9]", "-", workspace)


# ---------------------------------------------------------------- the team

PROJECTS = [
    ("Aurora Notes", [
        ("Architect", "icon:orbit", "Owns the architecture of Aurora Notes and keeps the team's plan coherent."),
        ("iOS Dev", "icon:ember", "Builds the SwiftUI app: sync, editor and widgets."),
        ("Backend Dev", "icon:tide", "Runs the sync API and its Postgres schema."),
        ("QA Tester", "icon:volt", "Tests every build on devices and writes the release reports."),
        ("Designer", "icon:bloom", "Owns the design system, icons and screens."),
        ("Tech Writer", "icon:quartz", "Writes the docs, changelog and App Store copy."),
    ]),
    ("Website", [
        ("Web Dev", "icon:comet", "Builds the marketing site."),
        ("Copywriter", "icon:mint", "Writes the words on the website."),
    ]),
]

SRC = "/Users/you/Code/aurora-notes"


def write_logs(bots: Dict[str, Dict[str, str]], shots: str, artifacts: Dict[str, str]) -> Dict[str, Log]:
    aurora = artifacts["Aurora Notes"]
    logs: Dict[str, Log] = {name: Log() for name in bots}

    # iOS Dev: finished the conflict banner, now running the UI tests.
    ios = logs["iOS Dev"]
    ios.message(95, "Architect", "task", 41,
                "Build the sync-conflict banner from the design in design-tokens.md. When the server returns 409, "
                "keep both versions and show the banner on the notes list. Flag it behind `syncConflictsUI`.")
    ios.say("Starting on the conflict banner. I'll read the store and the sync client first.")
    ios.read(f"{SRC}/Sources/Sync/NoteStore.swift", 212).read(f"{SRC}/Sources/Sync/SyncClient.swift", 148)
    ios.edit(f"{SRC}/Sources/Sync/NoteStore.swift", 88, [
        "     func apply(_ change: RemoteChange) throws {",
        "-        notes[change.id] = change.note",
        "+        if let local = notes[change.id], local.revision != change.baseRevision {",
        "+            conflicts.append(Conflict(local: local, remote: change.note))",
        "+            return",
        "+        }",
        "+        notes[change.id] = change.note",
        "     }"])
    ios.edit(f"{SRC}/Sources/Views/NotesList.swift", 31, [
        "     var body: some View {",
        "         List {",
        "+            if featureFlags.syncConflictsUI, !store.conflicts.isEmpty {",
        "+                ConflictBanner(count: store.conflicts.count)",
        "+            }",
        "             ForEach(store.sortedNotes) { NoteRow(note: $0) }"])
    ios.bash("Build for the simulator", "xcodebuild -scheme Aurora -destination 'platform=iOS Simulator,name=iPhone 16' build",
             "CompileSwift normal arm64 NoteStore.swift\nCompileSwift normal arm64 NotesList.swift\nLd Aurora.app\n** BUILD SUCCEEDED ** [41.2 sec]")
    ios.bash("Screenshot the notes list in light and dark", "./scripts/snap.sh notes-list --appearance light,dark",
             f"saved {shots}/notes_list_light.png\nsaved {shots}/notes_list_dark.png")
    ios.send("QA Tester", "task", "Build 142 is up on TestFlight with the conflict banner behind `syncConflictsUI`. "
             "Please run the sync suite on the iPhone 15 and the SE, and check the banner in dark mode.")
    ios.incoming("QA Tester", "reply", 58, "On it. Starting with the SE, it had the layout bugs last time.")
    ios.say("Handed build 142 to QA. While they test I'm running the UI tests locally.")
    ios.bash("Run the UI tests", "xcodebuild test -scheme AuroraUITests -destination 'platform=iOS Simulator,name=iPhone 16'", None)

    # QA Tester: tested build 141, filed a report with a chart.
    qa = logs["QA Tester"]
    qa.message(180, "iOS Dev", "task", 37, "Build 141 is on TestFlight: offline mode and faster launch. Full regression please.")
    qa.bash("Install build 141 on the test devices", "./qa/install.sh --build 141 --devices iphone15,iphonese",
            "iPhone 15 (17.5): installed 141\niPhone SE (17.5): installed 141")
    qa.bash("Run the regression suite", "./qa/run.sh --suite regression --build 141",
            "Regression · build 141\n  sync ............ 48 passed\n  editor .......... 61 passed\n  widgets ......... 12 passed\n"
            "  offline ......... 29 passed, 2 FAILED\n    ✗ offline_edit_then_delete_on_other_device\n    ✗ offline_rename_while_syncing\n"
            "150 passed, 2 failed", error=True)
    qa.bash("Measure cold launch time", "./qa/launch_time.py --builds 136-142 --device iphone15 --runs 10",
            f"median cold launch: 431 ms (budget 500 ms)\nchart: {shots}/launch_time.png")
    qa.look(f"{shots}/notes_list_light.png", os.path.join(shots, "notes_list_light.png"))
    qa.say("Two offline failures, both about a note changing on another device while this one is offline. "
           "That is exactly what the conflict banner is for, so I'm sending them to iOS Dev rather than filing them as regressions.")
    qa.send("iOS Dev", "reply", "Build 141: 150 passed, 2 failed, both offline edits racing another device "
            "(`offline_edit_then_delete_on_other_device`, `offline_rename_while_syncing`). Launch is down to 431 ms. Report attached.")
    qa.complete("Regression for build 141: 150/152 pass; the 2 failures are sync conflicts the banner will cover. "
                "Cold launch 431 ms, inside the 500 ms budget.", [f"{aurora}/qa-build-141.md"])
    qa.end()
    qa.message(20, "iOS Dev", "task", 57, "Build 142 is up on TestFlight with the conflict banner behind `syncConflictsUI`.")
    qa.bash("Install build 142", "./qa/install.sh --build 142 --devices iphone15,iphonese", "iPhone 15: installed 142\niPhone SE: installed 142")
    qa.send("iOS Dev", "reply", "On it. Starting with the SE, it had the layout bugs last time.")
    qa.bash("Run the sync suite on the SE", "./qa/run.sh --suite sync --build 142 --device iphonese", None)

    # Architect: the owner asked for a plan; wrote the design and raised a decision.
    arch = logs["Architect"]
    arch.typed(240, "Plan how sync conflicts should work end to end. Keep it simple enough to ship this month.")
    arch.read(f"{SRC}/docs/architecture.md", 310).read(f"{SRC}/server/sync/changes.go", 180)
    arch.tool("Write", {"file_path": f"{aurora}/sync-engine-design.md", "content": "# Sync engine…"},
              result={"type": "create", "filePath": f"{aurora}/sync-engine-design.md", "content": "…",
                      "structuredPatch": []}, output="written")
    arch.tool("mcp__gravity-bus__raise_decision", {"title": "Resolve conflicts automatically or always ask?"}, output="raised")
    arch.say("## Plan\n\nConflicts are **detected on the server** and **resolved on the device**:\n\n"
             "1. Every note carries a `revision`. A change is sent with the revision it was based on.\n"
             "2. The server rejects a stale change with `409` and returns the current note.\n"
             "3. The app keeps both versions and shows a banner; nothing is lost silently.\n\n"
             "| Field | Rule |\n|---|---|\n| Title | last writer wins |\n| Body | keep both, ask |\n| Tags | union |\n\n"
             "I've written it up in `sync-engine-design.md` and asked you one question in Decisions: "
             "whether bodies should merge automatically.")
    arch.end()
    arch.message(100, "User", "chat", 40, "Go with the plan. Split the work between iOS Dev and Backend Dev.")
    arch.send("iOS Dev", "task", "Build the sync-conflict banner from the design in design-tokens.md.")
    arch.send("Backend Dev", "task", "Return 409 with the current note when a change is based on a stale revision.")
    arch.say("Split the work: Backend Dev returns `409` on stale revisions, iOS Dev builds the banner behind a flag.")
    arch.end()

    # Backend Dev: shipped the 409 path.
    be = logs["Backend Dev"]
    be.message(98, "Architect", "task", 42, "Return 409 with the current note when a change is based on a stale revision.")
    be.read("/Users/you/Code/aurora-notes/server/sync/changes.go", 180)
    be.edit("/Users/you/Code/aurora-notes/server/sync/changes.go", 64, [
        "     current, err := s.notes.Get(ctx, change.NoteID)",
        "     if err != nil { return err }",
        "+    if current.Revision != change.BaseRevision {",
        "+        return conflictError(current) // 409 with the note as it is now",
        "+    }",
        "     return s.notes.Put(ctx, change.Apply(current))"])
    be.bash("Run the server tests", "go test ./server/...",
            "ok  \taurora/server/auth\t0.412s\nok  \taurora/server/sync\t1.873s\nok  \taurora/server/notes\t0.955s")
    be.bash("Deploy to staging", "./deploy.sh staging", "staging: v2.14.0 → v2.15.0 · healthy in 38 s")
    be.send("iOS Dev", "note", "Staging now returns `409` with the current note in the body. Shape: `{ \"note\": {…}, \"revision\": 18 }`.")
    be.complete("Stale changes now get 409 with the current note; tests pass; on staging as v2.15.0.", [])
    be.end()

    # Designer: design tokens with the palette.
    design = logs["Designer"]
    design.message(300, "Architect", "task", 33, "We need a banner style for sync conflicts that works in both themes.")
    design.bash("Export the palette", "./design/export.sh tokens --format png", f"wrote {shots}/palette.png")
    design.look(f"{shots}/notes_list_dark.png", os.path.join(shots, "notes_list_dark.png"))
    design.complete("Banner uses amber/500 on paper in light and amber/500 at 20% on ink in dark. Tokens and palette attached.",
                    [f"{aurora}/design-tokens.md"])
    design.end()

    # Tech Writer and the website team.
    writer = logs["Tech Writer"]
    writer.message(60, "iOS Dev", "note", 50, "The conflict banner ships behind a flag in 142. Changelog entry please.")
    writer.edit(f"{SRC}/CHANGELOG.md", 1, ["+## 1.8 (build 142)", "+", "+- Notes edited on two devices at once are kept side by side, with a banner to review them.",
                                           "+- The app opens up to 30% faster.", "+", " ## 1.7"])
    writer.say("Changelog for 1.8 is in. I kept it to what people will notice: no lost edits, faster launch.")
    writer.end()

    web = logs["Web Dev"]
    web.message(420, "Copywriter", "note", 12, "Hero copy is final: “Your notes, everywhere, even offline.”")
    web.edit("/Users/you/Code/aurora-site/src/pages/index.astro", 12, [
        "-<h1>Notes that sync</h1>", "+<h1>Your notes, everywhere, even offline.</h1>"])
    web.bash("Build the site", "npm run build", "✓ 14 pages built in 2.31s")
    web.end()

    copy = logs["Copywriter"]
    copy.typed(460, "Write the homepage hero for the offline launch.")
    copy.say("Three options, shortest first:\n\n1. **Your notes, everywhere, even offline.**\n2. Write anywhere. Sync when you can.\n"
             "3. Offline is not an excuse to forget.\n\nI'd go with 1: it names the feature and the benefit in six words.")
    copy.send("Web Dev", "note", "Hero copy is final: “Your notes, everywhere, even offline.”")
    copy.end()
    return logs


def write_reports(folder: str, shots: str) -> None:
    for image in ("launch_time.png", "palette.png"):
        shutil.copy(os.path.join(ASSETS, image), os.path.join(folder, image))
    reports = {
        "qa-build-141.md": """# QA report · build 141

**Result:** 150 of 152 pass. Both failures are sync conflicts that the conflict banner (build 142) will surface.

| Suite | Passed | Failed |
|---|---:|---:|
| Sync | 48 | 0 |
| Editor | 61 | 0 |
| Widgets | 12 | 0 |
| Offline | 29 | 2 |

## Failures

- `offline_edit_then_delete_on_other_device`: the edit is lost when another device deletes the note.
- `offline_rename_while_syncing`: the title from the other device overwrites the local one.

## Launch time

Cold launch is **431 ms** (median of 10 on an iPhone 15), inside the 500 ms budget.

![Cold launch time by build](launch_time.png)
""",
        "sync-engine-design.md": """# Sync engine: conflicts

Conflicts are detected on the server and resolved on the device.

1. Every note carries a `revision`.
2. A change is sent with the revision it was based on.
3. A stale change gets `409 Conflict` and the current note.
4. The app keeps both versions and shows a banner.

```swift
if local.revision != change.baseRevision {
    conflicts.append(Conflict(local: local, remote: change.note))
}
```

## Open question

Should note bodies merge automatically when the edits do not overlap? Raised as a decision.
""",
        "design-tokens.md": """# Design tokens

The conflict banner uses **amber/500** on paper in light mode and amber/500 at 20% on ink in dark mode.

![Colour tokens](palette.png)

| Token | Light | Dark |
|---|---|---|
| banner.background | `#FFF3E0` | `#FFB240` @ 20% |
| banner.text | `#AA6400` | `#FFB240` |
""",
    }
    for name, text in reports.items():
        with open(os.path.join(folder, name), "w") as handle:
            handle.write(text)


def write_home(home: str) -> None:
    """A small made-up home folder for the file browser."""
    files = {
        "Code/aurora-notes/README.md": "# Aurora Notes\n\nNotes that sync, even offline.\n\n```bash\nswift build\n```\n",
        "Code/aurora-notes/CHANGELOG.md": "## 1.8 (build 142)\n\n- Conflicting edits are kept side by side.\n- Up to 30% faster launch.\n",
        "Code/aurora-notes/Package.swift": "// swift-tools-version: 5.9\nimport PackageDescription\n",
        "Code/aurora-notes/Sources/Sync/NoteStore.swift": "final class NoteStore {\n    var notes: [UUID: Note] = [:]\n}\n",
        "Code/aurora-notes/Sources/Sync/SyncClient.swift": "struct SyncClient {}\n",
        "Code/aurora-notes/Sources/Views/NotesList.swift": "import SwiftUI\n",
        "Code/aurora-notes/server/sync/changes.go": "package sync\n",
        "Code/aurora-site/src/pages/index.astro": "<h1>Your notes, everywhere, even offline.</h1>\n",
        "Documents/Offsite agenda.md": "# Offsite\n\n1. Roadmap\n2. Hiring\n",
        "Downloads/aurora-1.8.zip": "not really a zip",
    }
    for relative, text in files.items():
        path = os.path.join(home, relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as handle:
            handle.write(text)
    shots = os.path.join(home, "Code", "aurora-notes", "docs", "screenshots")
    os.makedirs(shots, exist_ok=True)
    for image in ("notes_list_light.png", "notes_list_dark.png", "launch_time.png"):
        shutil.copy(os.path.join(ASSETS, image), os.path.join(shots, image))
    os.makedirs(os.path.join(home, "Desktop"), exist_ok=True)
    shutil.copy(os.path.join(ASSETS, "palette.png"), os.path.join(home, "Desktop", "palette.png"))


# ---------------------------------------------------------------- main

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", default="/tmp/flotilla-demo")
    parser.add_argument("--port", type=int, default=49790, help="demo gravityd port")
    parser.add_argument("--lens-port", type=int, default=49788)
    parser.add_argument("--gravityd", help="path to gravityd (default: the one Gravity installed)")
    parser.add_argument("--serve", action="store_true", help="keep the daemon running and start Gravity Lens")
    parser.add_argument("--control-port", type=int, default=0,
                        help="with --serve: an HTTP endpoint for UI tests to reset the demo per test")
    parser.add_argument("--peer-port", type=int, default=0,
                        help="also start a peer daemon on this port and link Aurora Notes with it")
    args = parser.parse_args()

    out = args.out
    if os.path.exists(out):
        shutil.rmtree(out)
    home = os.path.join(out, "gravity")
    claude = os.path.join(out, "user-home", ".claude", "projects")
    shots = os.path.join(out, "shots")
    os.makedirs(shots)
    global PIDS
    PIDS = os.path.join(out, "pids")
    for image in os.listdir(ASSETS):
        shutil.copy(os.path.join(ASSETS, image), os.path.join(shots, image))

    daemon = start_daemon(find_gravityd(args.gravityd), out, args.port)
    with open(os.path.join(home, "secrets", "client.token")) as handle:
        token = handle.read().strip()
    ws = Socket(args.port)
    # It answers permission prompts, so the daemon holds them while the demo runs.
    hello = ws.request("hello", protocol_version=2, token=token, client="flotilla-demo",
                       features=["permission_cards"])

    bots: Dict[str, Dict[str, str]] = {}
    artifacts: Dict[str, str] = {}
    project_ids: Dict[str, str] = {}
    for project_name, members in PROJECTS:
        project = ws.request("create_project", name=project_name)["project"]
        project_ids[project_name] = project["id"]
        artifacts[project_name] = os.path.join(home, "projects", project["dir_name"], "artifacts")
        os.makedirs(artifacts[project_name], exist_ok=True)
        for name, avatar, description in members:
            bot = ws.request("create_bot", project_id=project["id"], name=name, avatar=avatar,
                             description=description, instructions=description)["bot"]
            bots[name] = {"id": bot["id"], "workspace": os.path.join(home, "projects", project["dir_name"],
                                                                      "bots", bot["dir_name"], "workspace")}

    for name, log in write_logs(bots, shots, artifacts).items():
        log.write(os.path.join(claude, project_folder(bots[name]["workspace"])))
    write_reports(artifacts["Aurora Notes"], shots)

    raise_decision(args.port, home, bots["Architect"]["id"], kind="decision",
                   title="Resolve conflicts automatically or always ask?",
                   body="When two devices edit the same note body, we can **merge automatically** when the edits "
                        "don't overlap, or **always ask**. Merging is less friction; asking never surprises anyone.\n\n"
                        "Meanwhile the banner asks in every case.",
                   options=[{"key": "merge", "label": "Merge when edits don't overlap",
                             "description": "Fewer banners; about two more days of work."},
                            {"key": "ask", "label": "Always ask", "description": "Ships with build 142 as it is."}],
                   recommendation="ask", priority="urgent", tags=["sync"])
    raise_decision(args.port, home, bots["Designer"]["id"], kind="question",
                   title="Which accent colour for the App Store screenshots?",
                   body="Amber matches the app; blue tests better in the store. Your call.")
    raise_decision(args.port, home, bots["Copywriter"]["id"], kind="decision",
                   title="Launch the site with the offline headline?",
                   options=[{"key": "yes", "label": "Yes, go live Monday"}, {"key": "wait", "label": "Wait for sharing"}],
                   body="The page is built and staged.")
    hand_out_tasks(args.port, home, bots)
    peer = None
    if args.peer_port:
        peer = link_peer(ws, out, find_gravityd(args.gravityd), args.peer_port, project_ids["Aurora Notes"])
    if "workers" in hello.get("capabilities", []):
        spawn_workers(ws, args.port, home, out, bots)
    ws.request("send_user_message", to_bot_id=bots["iOS Dev"]["id"],
               body="Nice work on the banner. Keep it behind the flag until QA signs off.")

    launch = (f"xcrun simctl launch booted <your bundle id> -gravHost 127.0.0.1 -gravPort {args.port} "
              f"-lensPort {args.lens_port} -gravToken {token}")
    print(f"Demo ready in {out}\n  daemon: 127.0.0.1:{args.port}  token: {home}/secrets/client.token")
    print(f"  simulator (Debug build): {launch}")
    if not args.serve:
        print("Stop the demo daemon with: kill", daemon.pid, *([peer.pid] if peer else []))
        return
    mac_home = os.path.join(out, "mac-home")
    write_home(mac_home)
    lens = subprocess.Popen([sys.executable, LENS, "--port", str(args.lens_port), "--bind", "127.0.0.1",
                             "--gravity-home", home, "--claude-projects", claude, "--daemon-port", str(args.port),
                             "--files-root", mac_home, "--displays-json", json.dumps([
                                 {"id": 1, "main": True, "x": 0, "y": 0, "width": 1920, "height": 1200},
                                 {"id": 2, "main": False, "x": 1920, "y": 0, "width": 1920, "height": 1200}])])
    remember(lens)
    print(f"  Gravity Lens: 127.0.0.1:{args.lens_port}\nServing. Ctrl-C stops both.")
    if "permissions" in hello.get("capabilities", []):
        hold_permissions(args.port, token)
        ask_permissions(args.port, home, bots)
    if args.control_port:
        serve_control(args.control_port, args.port, home, token, bots, daemon.pid)
    # kill stops the lot as Ctrl-C does (scripts/ui-tests.sh runs the demo in the background).
    signal.signal(signal.SIGTERM, signal.default_int_handler)
    try:
        daemon.wait()
    except KeyboardInterrupt:
        pass
    finally:
        lens.terminate()
        daemon.terminate()
        if peer:
            peer.terminate()


if __name__ == "__main__":
    main()
