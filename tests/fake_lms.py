#!/usr/bin/env python3
"""A minimal in-process fake Lyrion Music Server for bridge tests.

Speaks just enough of the JSON-RPC + CometD surface that bin/lms-bridge uses,
on 127.0.0.1 with an ephemeral port. No external deps, no network access.
"""

import base64
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PLAYERS = [
    {"playerid": "aa:bb:cc:dd:ee:01", "name": "Living Room", "model": "squeezelite",
     "isplaying": 1, "power": 1, "connected": 1, "isgroup": 0},
    {"playerid": "aa:bb:cc:dd:ee:02", "name": "Kitchen", "model": "squeezelite",
     "isplaying": 0, "power": 0, "connected": 1, "isgroup": 0},
]

COVER_JPEG = b"\xff\xd8\xff\xe0" + b"\x00" * 16 + b"\xff\xd9"


class FakeLMS:
    def __init__(self, require_auth=None):
        self.require_auth = require_auth  # (user, password) or None
        self.mode = "play"
        self.volume = 40
        self.cur_index = 2
        self.commands = []  # every (player, cli) the bridge sent
        self.connect_calls = 0
        self.push_player = PLAYERS[0]["playerid"]
        self.cover_paths = []  # every cover-art request path the bridge proxied
        self._server = None
        self._thread = None
        self.port = 0

    # -- lifecycle ----------------------------------------------------------

    def start(self):
        handler = type("_Handler", (_Handler,), {"fake": self})
        self._server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.port = self._server.server_address[1]
        self._thread = threading.Thread(target=self._server.serve_forever,
                                        name="fake-lms", daemon=True)
        self._thread.start()
        return self

    def stop(self):
        if self._server:
            self._server.shutdown()
            self._server.server_close()

    # -- protocol -----------------------------------------------------------

    def jsonrpc(self, player, cli):
        self.commands.append((player, list(cli)))
        cmd = cli[0] if cli else ""
        if cmd == "serverstatus":
            return {"_name": "FakeLMS", "version": "9.0.0-test",
                    "players_loop": PLAYERS}
        if cmd == "players":
            return {"count": len(PLAYERS), "players_loop": PLAYERS}
        if cmd == "status":
            return {
                "mode": self.mode,
                "power": 1 if self.mode != "stop" else 0,
                "time": 12,
                "mixer volume": self.volume,
                "playlist_cur_index": str(self.cur_index),
                "playlist_loop": [{"id": 99, "title": "Test Song",
                                   "artist": "Test Artist", "album": "Test Album",
                                   "duration": 200, "coverid": "cover42"}],
            }
        if cmd == "pause":
            self.mode = "pause" if str(cli[1]) == "1" else "play"
        elif cmd == "play":
            self.mode = "play"
        elif cmd == "mixer":
            self.volume = int(cli[2])
        return {}


class _Handler(BaseHTTPRequestHandler):
    fake = None

    def _authorized(self):
        required = self.fake.require_auth
        if not required:
            return True
        user, password = required
        expected = "Basic " + base64.b64encode(
            ("%s:%s" % (user, password)).encode()).decode()
        return self.headers.get("Authorization", "") == expected

    def _send(self, code, body, ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):  # noqa: N802
        if not self._authorized():
            self._send(401, b'{"error":"unauthorized"}')
            return
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b""
        if self.path.endswith("/cometd"):
            self._handle_cometd(raw)
        elif self.path.endswith("/jsonrpc.js"):
            self._handle_jsonrpc(raw)
        else:
            self._send(404, b"{}")

    def do_GET(self):  # noqa: N802
        if not self._authorized():
            self._send(401, b"denied", ctype="text/plain")
            return
        if "cover" in self.path:
            self.fake.cover_paths.append(self.path)
            self._send(200, COVER_JPEG, ctype="image/jpeg")
        else:
            self._send(404, b"{}")

    def _handle_jsonrpc(self, raw):
        try:
            msg = json.loads(raw.decode())
            player, cli = msg["params"][0], msg["params"][1]
        except (ValueError, KeyError, IndexError):
            self._send(400, b'{"error":"bad request"}')
            return
        result = self.fake.jsonrpc(player, cli)
        body = json.dumps({"id": 1, "method": "slim.request", "result": result}).encode()
        self._send(200, body)

    def _handle_cometd(self, raw):
        try:
            messages = json.loads(raw.decode())
        except ValueError:
            self._send(400, b"[]")
            return
        replies = []
        for m in messages:
            channel = m.get("channel", "")
            mid = m.get("id")
            if channel == "/meta/handshake":
                replies.append({"channel": channel, "id": mid, "successful": True,
                                "clientId": "fakeclient",
                                "advice": {"reconnect": "retry", "timeout": 60000}})
            elif channel == "/meta/subscribe":
                replies.append({"channel": channel, "id": mid, "successful": True,
                                "subscription": m.get("subscription", "")})
            elif channel == "/meta/connect":
                self.fake.connect_calls += 1
                if self.fake.connect_calls == 1:
                    # Deliver one player push so the bridge exercises _on_push.
                    replies.append({
                        "channel": "/player/" + self.fake.push_player,
                        "id": mid, "data": {"mode": "pause"},
                        "advice": {"reconnect": "retry"}})
                else:
                    time.sleep(0.05)
                    replies.append({"channel": channel, "id": mid, "successful": True,
                                    "advice": {"reconnect": "retry"}})
            else:
                replies.append({"channel": channel, "id": mid, "successful": True})
        self._send(200, json.dumps(replies).encode())

    def log_message(self, *args):  # silence
        pass
