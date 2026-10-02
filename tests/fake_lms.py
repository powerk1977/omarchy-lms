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
        # Playlist titles by position and the currently playing position.
        # `status - N` starts at cur_index; `status 0 N` starts at position 0
        # (mirrors the real LMS CLI, so an offset bug is observable).
        self.tracks = ["Test Song"]
        self.cur_index = 0
        self.commands = []  # every (player, cli) the bridge sent
        self.connect_calls = 0
        self.cover_paths = []  # every cover-art request path the bridge proxied
        self.push_channel = ""  # /slim/subscribe response channel the bridge chose
        self.pending_pushes = []  # statuses queued by state-changing commands
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

    def _status_payload(self, start="-", count=1, tags=""):
        """The status dict this fake reports for its current state.

        Honours the LMS `status <start> <count> <tags>` semantics: `-` starts
        at the currently playing track, a numeric start at that playlist
        position, and count bounds the returned playlist slice. Requested tags
        (`t` title, `a` artist, `l` album) gate the per-track fields, so the
        `tags:aat` queue query sees title+artist while a bare status still
        gets a title.
        """
        tracks = getattr(self, "tracks", ["Test Song"]) or ["Test Song"]
        if start == "-":
            idx = self.cur_index
        else:
            try:
                idx = int(start)
            except (TypeError, ValueError):
                idx = self.cur_index
        if not 0 <= idx < len(tracks):
            idx = self.cur_index if 0 <= self.cur_index < len(tracks) else 0
        try:
            count = max(1, int(count))
        except (TypeError, ValueError):
            count = 1
        loop = []
        for pos in range(idx, min(idx + count, len(tracks))):
            item = {"id": 100 + pos, "duration": 200, "coverid": "cover42"}
            if not tags or "t" in tags:
                item["title"] = tracks[pos]
            if not tags or "a" in tags:
                item["artist"] = "Test Artist"
            if not tags or "l" in tags:
                item["album"] = "Test Album"
            loop.append(item)
        return {
            "mode": self.mode,
            "power": 1 if self.mode != "stop" else 0,
            "time": 12,
            "mixer volume": self.volume,
            "playlist_cur_index": str(self.cur_index),
            "playlist_loop": loop,
        }

    def _playlist_command(self, verb, arg):
        """Apply `playlist index|delete <arg>` the way LMS would."""
        if verb == "index":
            try:
                if str(arg).startswith(("+", "-")):
                    self.cur_index += int(arg)
                else:
                    self.cur_index = int(arg)
            except (TypeError, ValueError):
                return
            self.cur_index = max(0, min(len(self.tracks) - 1, self.cur_index))
        elif verb == "delete":
            try:
                pos = int(arg)
            except (TypeError, ValueError):
                return
            if 0 <= pos < len(self.tracks):
                del self.tracks[pos]
                if pos < self.cur_index:
                    self.cur_index -= 1
                if self.tracks:
                    self.cur_index = max(0, min(len(self.tracks) - 1, self.cur_index))
                else:
                    self.cur_index = 0

    def jsonrpc(self, player, cli):
        self.commands.append((player, list(cli)))
        cmd = cli[0] if cli else ""
        if cmd == "serverstatus":
            return {"_name": "FakeLMS", "version": "9.0.0-test",
                    "players_loop": PLAYERS}
        if cmd == "players":
            return {"count": len(PLAYERS), "players_loop": PLAYERS}
        if cmd == "status":
            start = cli[1] if len(cli) > 1 else "-"
            count = cli[2] if len(cli) > 2 else 1
            tags = ""
            for part in cli[3:]:
                if part.startswith("tags:"):
                    tags = part[len("tags:"):]
            return self._status_payload(start, count, tags)
        if cmd in ("albums", "artists", "playlists"):
            term = ""
            for part in cli[3:]:
                if part.startswith("search:"):
                    term = part[len("search:"):].lower()
            if "the" not in term:
                return {"count": 0, cmd + "_loop": []}
            if cmd == "albums":
                return {"count": 1, "albums_loop": [
                    {"id": 656, "album": "The Wall", "artist": "Pink Floyd",
                     "year": 1979, "artwork_track_id": "e4a46d1b"}]}
            if cmd == "artists":
                return {"count": 1, "artists_loop": [
                    {"id": 812, "artist": "The Jam"}]}
            return {"count": 1, "playlists_loop": [
                {"id": 5, "playlist": "The Mixtape"}]}
        if cmd == "pause":
            self.mode = "pause" if str(cli[1]) == "1" else "play"
        elif cmd == "play":
            self.mode = "play"
        elif cmd == "mixer":
            self.volume = int(cli[2])
        elif cmd == "playlist":
            self._playlist_command(cli[1] if len(cli) > 1 else "",
                                   cli[2] if len(cli) > 2 else "")
        # Like the real LMS: a state-changing command triggers an async push.
        if cmd in ("pause", "play", "mixer", "playlist", "time", "power"):
            self.pending_pushes.append(self._status_payload())
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
            elif channel == "/slim/subscribe":
                # LMS-style status subscription: record the response channel the
                # bridge chose so pushes can be delivered on it.
                self.fake.push_channel = (m.get("data") or {}).get("response", "")
                replies.append({"channel": channel, "id": mid, "successful": True})
            elif channel == "/meta/connect":
                self.fake.connect_calls += 1
                if self.fake.connect_calls == 1:
                    # Deliver one player-status push so the bridge exercises
                    # _on_push with a real status-shaped payload.
                    replies.append({
                        "channel": self.fake.push_channel,
                        "id": mid,
                        "data": {"mode": "pause", "power": 1, "time": 5,
                                 "mixer volume": 40, "playlist_cur_index": "0",
                                 "playlist_loop": [{"id": 99, "title": "Push Song",
                                                    "artist": "Push Artist",
                                                    "album": "Push Album",
                                                    "duration": 200,
                                                    "coverid": "cover99"}]},
                        "advice": {"reconnect": "retry"}})
                # Deliver statuses queued by state-changing commands, the way
                # LMS pushes asynchronously after a command.
                while self.fake.pending_pushes:
                    payload = self.fake.pending_pushes.pop(0)
                    replies.append({"channel": self.fake.push_channel,
                                    "id": mid, "data": payload,
                                    "advice": {"reconnect": "retry"}})
                    break
                else:
                    time.sleep(0.05)
                    replies.append({"channel": channel, "id": mid, "successful": True,
                                    "advice": {"reconnect": "retry"}})
            else:
                replies.append({"channel": channel, "id": mid, "successful": True})
        self._send(200, json.dumps(replies).encode())

    def log_message(self, *args):  # silence
        pass
