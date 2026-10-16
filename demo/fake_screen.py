#!/usr/bin/env python3
"""A stand-in for macOS Screen Sharing, for developing Flotilla's screen view.

Serves demo/assets/desktop.png over RFB 3.8 with ZRLE, and signs in the way a
Mac does (security type 30: Diffie-Hellman, then the user name and password
under AES-128). Clicking "Allow" on the fake permission prompt dismisses it,
so taps can be checked end to end. Keys, clicks and clipboard text are logged.

    uv run --with cryptography --with pillow demo/fake_screen.py [--dual]
    # sign in as demo / demo on 127.0.0.1:5901

With --dual a second display (a browser sign-in page) sits to the right, sent
as one wide picture the way macOS sends two displays.

Not a real VNC server. Development only.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import secrets
import socket
import struct
import threading
import time
import zlib

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
# RFC 2409 group 2, as a Mac uses for this sign-in.
PRIME = int(
    "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DD"
    "EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED"
    "EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE65381FFFFFFFFFFFFFFFF", 16)
ALLOW_BUTTON = (970, 1000, 1190, 1048)  # in desktop.png pixels
ALERT_BOX = (650, 760, 1270, 1130)


def recv_exact(sock: socket.socket, count: int) -> bytes:
    data = b""
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise ConnectionError("client closed")
        data += chunk
    return data


class Session:
    def __init__(self, sock: socket.socket, desktop: Image.Image, user: str, password: str, scale: float):
        self.sock = sock
        self.user = user
        self.password = password
        size = (int(desktop.width * scale), int(desktop.height * scale))
        self.scale = scale
        self.frame = desktop.resize(size, Image.LANCZOS).convert("RGB")
        self.clean = self.without_alert(desktop).resize(size, Image.LANCZOS).convert("RGB")
        self.zlib = zlib.compressobj(6)
        self.dirty = [(0, 0, size[0], size[1])]
        self.pending_request = False
        self.region = (0, 0, size[0], size[1])
        self.bpp = 32
        self.buttons = 0
        self.sent_bytes = 0
        self.drop_idle = False
        self.lock = threading.Lock()

    @staticmethod
    def without_alert(desktop: Image.Image) -> Image.Image:
        clean = desktop.copy().convert("RGB")
        # Paint the alert away with the wallpaper's own gradient.
        pixels = clean.load()
        x0, y0, x1, y1 = ALERT_BOX
        for y in range(y0, y1):
            for x in range(x0, x1):
                t = x / 1920 * 0.5 + y / 1200 * 0.5  # the first display's wallpaper
                pixels[x, y] = (int(40 + 60 * t), int(30 + 40 * (1 - t)), int(90 + 80 * t))
        return clean

    # Handshake ----------------------------------------------------------------

    def handshake(self) -> None:
        self.sock.sendall(b"RFB 003.008\n")
        recv_exact(self.sock, 12)
        self.sock.sendall(bytes([1, 30]))
        if recv_exact(self.sock, 1)[0] != 30:
            raise ConnectionError("client chose another security type")
        secret = secrets.randbits(1024)
        public = pow(2, secret, PRIME).to_bytes(128, "big")
        self.sock.sendall(struct.pack(">HH", 2, 128) + PRIME.to_bytes(128, "big") + public)
        sealed = recv_exact(self.sock, 128)
        client_public = int.from_bytes(recv_exact(self.sock, 128), "big")
        shared = pow(client_public, secret, PRIME).to_bytes(128, "big")
        key = hashlib.md5(shared).digest()
        decryptor = Cipher(algorithms.AES(key), modes.ECB()).decryptor()
        plain = decryptor.update(sealed) + decryptor.finalize()
        user = plain[:64].split(b"\0")[0].decode("utf-8", "replace")
        password = plain[64:].split(b"\0")[0].decode("utf-8", "replace")
        if (user, password) != (self.user, self.password):
            reason = b"Authentication failed"
            self.sock.sendall(struct.pack(">II", 1, len(reason)) + reason)
            raise ConnectionError(f"bad credentials for {user!r}")
        print(f"signed in as {user}")
        self.sock.sendall(struct.pack(">I", 0))
        recv_exact(self.sock, 1)
        name = b"Demo Mac"
        pixel_format = struct.pack(">BBBBHHHBBBxxx", 32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
        self.sock.sendall(struct.pack(">HH", *self.frame.size) + pixel_format + struct.pack(">I", len(name)) + name)

    # Updates ------------------------------------------------------------------

    def zrle(self, x: int, y: int, w: int, h: int) -> bytes:
        region = self.frame.crop((x, y, x + w, y + h)).tobytes()
        tiles = bytearray()
        for ty in range(0, h, 64):
            th = min(64, h - ty)
            for tx in range(0, w, 64):
                tw = min(64, w - tx)
                pixels = []
                for row in range(ty, ty + th):
                    start = (row * w + tx) * 3
                    line = region[start:start + tw * 3]
                    if self.bpp == 16:
                        pixels.extend(struct.pack("<H", (line[i] >> 3) << 11 | (line[i + 1] >> 2) << 5 | line[i + 2] >> 3)
                                      for i in range(0, len(line), 3))
                    else:
                        pixels.extend(bytes((line[i + 2], line[i + 1], line[i])) for i in range(0, len(line), 3))
                if len(set(pixels)) == 1:
                    tiles += b"\x01" + pixels[0]
                else:
                    tiles += b"\x00" + b"".join(pixels)
        data = self.zlib.compress(bytes(tiles)) + self.zlib.flush(zlib.Z_SYNC_FLUSH)
        return struct.pack(">HHHHiI", x, y, w, h, 16, len(data)) + data

    def clip(self, rect):
        x, y, w, h = rect
        rx, ry, rw, rh = self.region
        x0, y0 = max(x, rx), max(y, ry)
        x1, y1 = min(x + w, rx + rw), min(y + h, ry + rh)
        return (x0, y0, x1 - x0, y1 - y0) if x1 > x0 and y1 > y0 else None

    def tick_clock(self) -> None:
        """A seconds clock in the menu bar, so there is always something changing."""
        font = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", int(18 * self.scale))
        while True:
            time.sleep(1)
            with self.lock:
                box = (int(1600 * self.scale), 0, int(1910 * self.scale), int(30 * self.scale))
                for image in {id(self.frame): self.frame, id(self.clean): self.clean}.values():
                    draw = ImageDraw.Draw(image)
                    draw.rectangle(box, fill=(236, 236, 242))
                    draw.text((box[0] + 6, box[1] + 3), time.strftime("%H:%M:%S"), font=font, fill=(20, 20, 28))
                self.dirty.append((box[0], box[1], box[2] - box[0], box[3] - box[1]))

    def send_update(self) -> None:
        if not self.pending_request:
            return
        rects = list(dict.fromkeys(r for r in (self.clip(rect) for rect in self.dirty) if r))
        if not rects:
            if self.drop_idle:
                # What macOS does: a request with nothing to send is forgotten.
                self.pending_request = False
            return
        # Changes outside the requested region wait for a request that covers them.
        self.dirty = [rect for rect in self.dirty if not self.clip(rect)]
        self.pending_request = False
        with self.lock:
            body = b"".join(self.zrle(*rect) for rect in rects)
        self.sent_bytes += len(body)
        print(f"sent {len(rects)} rect(s) {rects[0]}… {len(body) / 1024:.0f} KB at {self.bpp} bpp", flush=True)
        self.sock.sendall(struct.pack(">BxH", 0, len(rects)) + body)

    def click(self, x: int, y: int) -> None:
        dx, dy = x / self.scale, y / self.scale
        bx0, by0, bx1, by1 = ALLOW_BUTTON
        print(f"click at {x},{y} (desktop {dx:.0f},{dy:.0f})")
        if bx0 <= dx <= bx1 and by0 <= dy <= by1 and self.frame is not self.clean:
            print("  -> Allow pressed: dismissing the prompt")
            self.frame = self.clean
            s = self.scale
            ax0, ay0, ax1, ay1 = ALERT_BOX
            self.dirty.append((int(ax0 * s), int(ay0 * s), int((ax1 - ax0) * s), int((ay1 - ay0) * s)))

    # Loop -----------------------------------------------------------------------

    def run(self) -> None:
        self.handshake()
        threading.Thread(target=self.tick_clock, daemon=True).start()
        while True:
            kind = recv_exact(self.sock, 1)[0]
            if kind == 0:
                self.bpp = recv_exact(self.sock, 19)[3]
            elif kind == 2:
                count = struct.unpack(">xH", recv_exact(self.sock, 3))[0]
                encodings = struct.unpack(f">{count}i", recv_exact(self.sock, count * 4))
                print("encodings", encodings)
            elif kind == 3:
                incremental, x, y, w, h = struct.unpack(">BHHHH", recv_exact(self.sock, 9))
                self.region = (x, y, w, h)
                if not incremental:
                    self.dirty.append((x, y, w, h))
                self.pending_request = True
            elif kind == 4:
                down, keysym = struct.unpack(">BxxI", recv_exact(self.sock, 7))
                print(f"key {'down' if down else 'up  '} {keysym:#06x}", repr(chr(keysym)) if keysym < 0x100 else "")
            elif kind == 5:
                buttons, x, y = struct.unpack(">BHH", recv_exact(self.sock, 5))
                if buttons & 1 and not self.buttons & 1:
                    self.click(x, y)
                if buttons & 24:
                    print("scroll", "up" if buttons & 8 else "down")
                if buttons & 4 and not self.buttons & 4:
                    print(f"right click at {x},{y}")
                self.buttons = buttons
            elif kind == 6:
                length = struct.unpack(">xxxI", recv_exact(self.sock, 7))[0]
                print("clipboard from phone:", recv_exact(self.sock, length).decode("latin-1"))
            else:
                raise ConnectionError(f"unknown message {kind}")
            self.send_update()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=5901)
    parser.add_argument("--user", default="demo")
    parser.add_argument("--password", default="demo")
    parser.add_argument("--scale", type=float, default=0.75, help="served size relative to desktop.png")
    parser.add_argument("--dual", action="store_true", help="add a second display to the right")
    parser.add_argument("--drop-idle", action="store_true",
                        help="forget update requests when nothing changed, as macOS does")
    args = parser.parse_args()
    desktop = Image.open(os.path.join(HERE, "assets", "desktop.png")).convert("RGB")
    if args.dual:
        second = Image.open(os.path.join(HERE, "assets", "desktop-browser.png")).convert("RGB")
        both = Image.new("RGB", (desktop.width + second.width, max(desktop.height, second.height)))
        both.paste(desktop, (0, 0))
        both.paste(second, (desktop.width, 0))
        desktop = both
    server = socket.create_server(("127.0.0.1", args.port))
    print(f"fake Screen Sharing on 127.0.0.1:{args.port} (user {args.user!r})", flush=True)
    while True:
        sock, _ = server.accept()
        session = Session(sock, desktop, args.user, args.password, args.scale)
        session.drop_idle = args.drop_idle

        def serve(session: Session = session) -> None:
            try:
                session.run()
            except (ConnectionError, OSError) as error:
                print("session ended:", error, flush=True)
            finally:
                session.sock.close()

        threading.Thread(target=serve, daemon=True).start()


if __name__ == "__main__":
    main()
