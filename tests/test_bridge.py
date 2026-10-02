#!/usr/bin/env python3
"""Integration tests for bin/lms-bridge against an in-process fake LMS.

Run: PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1 python3 tests/test_bridge.py
No network, no credentials, no real server required.
"""

import json
import os
import pathlib
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from fake_lms import COVER_JPEG, FakeLMS  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[1]
BRIDGE = ROOT / "bin" / "lms-bridge"
PID1 = "aa:bb:cc:dd:ee:01"


def _load_bridge():
    import importlib.machinery
    import importlib.util
    spec = importlib.util.spec_from_loader(
        "lms_bridge", importlib.machinery.SourceFileLoader("lms_bridge", str(BRIDGE)))
    lb = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(lb)
    return lb


class BridgeProc:
    def __init__(self, demo=False):
        cmd = [sys.executable, str(BRIDGE)] + (["--demo"] if demo else [])
        self.proc = subprocess.Popen(
            cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, bufsize=1)
        self.events = []
        self._lock = threading.Lock()
        self._err = []
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

    def _read_stdout(self):
        for line in self.proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            with self._lock:
                self.events.append(ev)

    def _read_stderr(self):
        for line in self.proc.stderr:
            self._err.append(line)

    def send(self, obj):
        self.proc.stdin.write(json.dumps(obj) + "\n")
        self.proc.stdin.flush()

    def wait_for(self, predicate, timeout=8.0):
        deadline = time.time() + timeout
        seen = 0
        while time.time() < deadline:
            with self._lock:
                events = list(self.events)
            for ev in events[seen:]:
                if predicate(ev):
                    return ev
            seen = len(events)
            time.sleep(0.02)
        raise AssertionError("timed out waiting; got:\n" + self.dump())

    def by_ev(self, name):
        with self._lock:
            return [e for e in self.events if e.get("ev") == name]

    def dump(self):
        with self._lock:
            lines = [json.dumps(e) for e in self.events]
        return "\n".join(lines) + "\nSTDERR:\n" + "".join(self._err)

    def close(self):
        try:
            self.send({"op": "shutdown"})
            self.proc.wait(timeout=5)
        except Exception:  # noqa: BLE001
            self.proc.kill()


def test_demo_sequence():
    bp = BridgeProc(demo=True)
    try:
        bp.wait_for(lambda e: e.get("ev") == "hello")
        bp.send({"op": "config", "generation": 1, "demoMode": True,
                 "playerId": "demo:living"})
        bp.wait_for(lambda e: e.get("ev") == "phase" and e.get("phase") == "connected")
        players = bp.wait_for(lambda e: e.get("ev") == "players")
        assert len(players["items"]) == 2, players
        states = bp.by_ev("state")
        assert len(states) >= 1, bp.dump()
    finally:
        bp.close()
    print("ok demo sequence")


def test_live_connect_command_and_cover():
    fake = FakeLMS().start()
    bp = BridgeProc()
    try:
        bp.wait_for(lambda e: e.get("ev") == "hello")
        bp.send({"op": "config", "generation": 1, "host": "127.0.0.1",
                 "port": fake.port, "playerId": PID1})
        base_ev = bp.wait_for(lambda e: e.get("ev") == "coverbase")
        bp.wait_for(lambda e: e.get("ev") == "phase" and e.get("phase") == "connected")
        players = bp.wait_for(lambda e: e.get("ev") == "players")
        assert [p["name"] for p in players["items"]] == ["Living Room", "Kitchen"], players

        state = bp.wait_for(lambda e: e.get("ev") == "state"
                            and e["nowplaying"].get("title") == "Test Song")
        assert state["nowplaying"]["artist"] == "Test Artist", state
        assert state["nowplaying"]["mode"] == "play", state
        assert isinstance(state.get("seq"), int) and state["seq"] > 0, state

        # The fake LMS pushes a status payload on the /slim/subscribe response
        # channel during the first long-poll; the bridge must parse it directly
        # into a state event (this is what updates the panel on track change).
        push = bp.wait_for(lambda e: e.get("ev") == "state"
                           and e["nowplaying"].get("title") == "Push Song")
        assert push["nowplaying"]["artist"] == "Push Artist", push
        assert push["nowplaying"]["mode"] == "pause", push
        assert push["nowplaying"]["coverid"] == "cover99", push

        # Cover proxy forwards the artwork from the LMS.
        with urllib.request.urlopen(base_ev["url"] + "/now/" + PID1 + ".jpg",
                                    timeout=5) as res:
            assert res.read() == COVER_JPEG

        # Percent-encoded request paths (as the panel's encodeURIComponent
        # emits) must not be double-encoded when proxied upstream — the player
        # id the fake LMS sees must round-trip to the real id, and the proxy
        # must ask LMS for a resized variant (fast loads) rather than the
        # full-size original.
        with urllib.request.urlopen(
                base_ev["url"] + "/now/" + urllib.parse.quote(PID1, safe="") + ".jpg",
                timeout=5) as res:
            assert res.read() == COVER_JPEG
        assert fake.cover_paths, fake.cover_paths
        assert any(urllib.parse.unquote(p) == "/music/current/cover_600x600_f.jpg"
                   + "?player=" + PID1 for p in fake.cover_paths), fake.cover_paths

        # A command round-trips and is reflected back to the client.
        bp.send({"op": "cmd", "player": PID1, "cli": ["pause", "1"], "tag": "t1"})
        result = bp.wait_for(lambda e: e.get("ev") == "result" and e.get("tag") == "t1")
        assert result["success"] is True, result
        bp.wait_for(lambda e: e.get("ev") == "state"
                    and e["nowplaying"].get("mode") == "pause")
        assert any(cli[:2] == ["pause", "1"] for _p, cli in fake.commands), fake.commands
    finally:
        bp.close()
        fake.stop()
    print("ok live connect/command/cover")


def test_auth_required_and_recovery():
    bad = FakeLMS(require_auth=("user", "secret")).start()
    bp = BridgeProc()
    try:
        bp.wait_for(lambda e: e.get("ev") == "hello")
        bp.send({"op": "config", "generation": 1, "host": "127.0.0.1",
                 "port": bad.port, "username": "user", "password": "wrong"})
        err = bp.wait_for(lambda e: e.get("ev") == "phase" and e.get("phase") == "error")
        assert err["errorKind"] == "auth", err
    finally:
        bp.close()
        bad.stop()

    good = FakeLMS(require_auth=("user", "secret")).start()
    bp = BridgeProc()
    try:
        bp.wait_for(lambda e: e.get("ev") == "hello")
        bp.send({"op": "config", "generation": 1, "host": "127.0.0.1",
                 "port": good.port, "username": "user", "password": "secret"})
        base_ev = bp.wait_for(lambda e: e.get("ev") == "coverbase")
        bp.wait_for(lambda e: e.get("ev") == "phase" and e.get("phase") == "connected")
        with urllib.request.urlopen(base_ev["url"] + "/cover/cover42.jpg",
                                    timeout=5) as res:
            assert res.read() == COVER_JPEG
    finally:
        bp.close()
        good.stop()
    print("ok auth required and recovery")


def test_discovery_demo():
    bp = BridgeProc(demo=True)
    try:
        bp.wait_for(lambda e: e.get("ev") == "hello")
        bp.send({"op": "discover"})
        servers = bp.wait_for(lambda e: e.get("ev") == "servers")
        assert servers["items"], servers
    finally:
        bp.close()
    print("ok discovery (demo)")


def test_nowplaying_hardening():
    lb = _load_bridge()

    assert lb._coerce_int(None) == 0
    assert lb._coerce_int("") == 0
    assert lb._coerce_int("1:02") == 0
    assert lb._coerce_int("75 %") == 75
    assert lb._coerce_int("42") == 42
    assert lb._coerce_int(0) == 0

    hostile = {"mode": "play", "power": "", "time": "1:02", "mixer volume": "50 %",
               "playlist_loop": [{"duration": None, "title": "X"}]}
    np = lb._nowplaying(hostile, "pid")
    assert np == {"mode": "play", "power": 0, "time": 0, "duration": 0,
                  "title": "X", "artist": "", "album": "", "coverid": None,
                  "volume": 50, "cur_index": "0", "playerid": "pid"}, np
    print("ok nowplaying hardening")


def test_refresh_op_signature():
    bp = BridgeProc(demo=True)
    try:
        bp.send({"op": "config", "generation": 1, "demoMode": True,
                 "playerId": "demo:living"})
        bp.wait_for(lambda e: e.get("ev") == "phase" and e.get("phase") == "connected")
        # Regression: every op is dispatched as fn(msg); a handler that takes no
        # message arg used to TypeError into a phase:error on every refresh.
        bp.send({"op": "refresh"})
        bp.send({"op": "config", "generation": 2, "demoMode": True,
                 "playerId": "demo:office"})
        bp.wait_for(lambda e: e.get("ev") == "config_ack" and e.get("generation") == 2)
        bp.wait_for(lambda e: e.get("ev") == "phase" and e.get("phase") == "connected")
        errors = [e for e in bp.by_ev("phase") if e.get("phase") == "error"]
        assert not errors, errors
        assert bp.proc.poll() is None
    finally:
        bp.close()
    print("ok refresh op dispatches cleanly")


def test_bridge_survives_bad_messages():
    bp = BridgeProc(demo=True)
    try:
        bp.wait_for(lambda e: e.get("ev") == "hello")
        # A message that used to crash the process (ValueError on bad port).
        bp.send({"op": "config", "generation": 1, "demoMode": True, "port": "abc"})
        err = bp.wait_for(lambda e: e.get("ev") == "phase" and e.get("phase") == "error")
        assert "bridge error" in err.get("error", ""), err
        assert bp.proc.poll() is None, "bridge died on a bad message"
        # Unknown ops are tolerated, and a good config reconnects.
        bp.send({"op": "frobnicate"})
        bp.send({"op": "config", "generation": 2, "demoMode": True,
                 "playerId": "demo:living"})
        bp.wait_for(lambda e: e.get("ev") == "phase" and e.get("phase") == "connected")
        assert bp.proc.poll() is None
    finally:
        bp.close()
    print("ok bridge survives bad messages")


def test_status_query_uses_current_track():
    """Regression: status polls must ask LMS for the CURRENT track.

    `status 0 1` returns playlist index 0, so the connect-time poll, the
    panel-open `refresh`, and any push-without-playlist fallback used to
    overwrite now-playing with the playlist's first (oldest) song — the
    panel-open song revert. `status - 1` starts at the current song, matching
    the CometD subscribe query."""
    fake = FakeLMS().start()
    fake.tracks = ["Old Song", "New Song"]
    fake.cur_index = 1
    bp = BridgeProc()
    try:
        bp.wait_for(lambda e: e.get("ev") == "hello")
        bp.send({"op": "config", "generation": 1, "host": "127.0.0.1",
                 "port": fake.port, "playerId": PID1})
        bp.wait_for(lambda e: e.get("ev") == "phase" and e.get("phase") == "connected")

        # Connect-time poll reports the current track, not position 0.
        bp.wait_for(lambda e: e.get("ev") == "state" and e.get("player") == PID1
                    and e["nowplaying"].get("title") == "New Song")
        titles = [e["nowplaying"].get("title") for e in bp.by_ev("state")
                  if e.get("player") == PID1]
        assert "Old Song" not in titles, titles

        # A panel-open `refresh` must not resurrect the playlist's first track.
        bp.send({"op": "refresh"})
        bp.wait_for(lambda e: e.get("ev") == "result" and e.get("success") is True)
        titles = [e["nowplaying"].get("title") for e in bp.by_ev("state")
                  if e.get("player") == PID1]
        assert "Old Song" not in titles, titles
        assert titles.count("New Song") >= 2, titles
    finally:
        bp.close()
        fake.stop()
    print("ok status query uses current track")


def test_search_op():
    fake = FakeLMS().start()
    bp = BridgeProc()
    try:
        bp.wait_for(lambda e: e.get("ev") == "hello")
        bp.send({"op": "config", "generation": 1, "host": "127.0.0.1",
                 "port": fake.port, "playerId": PID1})
        bp.wait_for(lambda e: e.get("ev") == "phase" and e.get("phase") == "connected")

        bp.send({"op": "search", "q": "The", "tag": "s1"})
        res = bp.wait_for(lambda e: e.get("ev") == "searchResults" and e.get("tag") == "s1")
        assert res["q"] == "The", res
        assert res["albums"] == [{"id": 656, "name": "The Wall",
                                  "artist": "Pink Floyd", "year": 1979,
                                  "coverId": "e4a46d1b"}], res
        assert res["artists"] == [{"id": 812, "name": "The Jam"}], res
        assert res["playlists"] == [{"id": 5, "name": "The Mixtape"}], res
        bp.wait_for(lambda e: e.get("ev") == "result" and e.get("tag") == "s1"
                    and e.get("success") is True)

        # Empty query returns empty results without touching the server.
        n_cmds = len(fake.commands)
        bp.send({"op": "search", "q": "  ", "tag": "s2"})
        res2 = bp.wait_for(lambda e: e.get("ev") == "searchResults" and e.get("tag") == "s2")
        assert res2["albums"] == [] and res2["artists"] == [], res2
        assert len(fake.commands) == n_cmds, fake.commands
    finally:
        bp.close()
        fake.stop()
    print("ok search op")


def test_state_seq_guard():
    """Regression: a stale status poll must not overwrite a newer push.

    The bridge reserves a monotonic seq *before* the (blocking) status
    request; a consumer (Service.qml) applies states in arrival order but
    drops seq <= the last applied per player. A poll that started before a
    track change can therefore return after the newer CometD push without
    winning."""
    lb = _load_bridge()
    bridge = lb.Bridge()
    bridge._players = [{"playerid": "p1"}]
    bridge._http = True  # _on_push bails without a connection
    emitted = []
    emit_lock = threading.Lock()

    def capture(obj):
        with emit_lock:
            emitted.append(obj)

    bridge.emit = capture

    query_started = threading.Event()
    release_query = threading.Event()

    def slow_query(pid):
        query_started.set()
        release_query.wait(2.0)
        return {"title": "Old Song", "artist": "", "mode": "play"}

    bridge._query_status = slow_query

    # A poll (e.g. the panel-open `refresh`) starts and blocks mid-request.
    poll = threading.Thread(target=lambda: bridge._poll_state("p1"))
    poll.start()
    assert query_started.wait(2.0), "poll never started"

    # A newer push for the same player arrives while the poll is in flight.
    bridge._on_push("p1", {"playlist_loop": [{"title": "New Song"}]})
    release_query.set()
    poll.join(2.0)

    states = [e for e in emitted if e.get("ev") == "state"]
    old = next(e for e in states if e["nowplaying"].get("title") == "Old Song")
    new = next(e for e in states if e["nowplaying"].get("title") == "New Song")
    # The push reserved its seq after the poll, even though the poll emitted
    # its (stale) response last.
    assert new["seq"] > old["seq"], states
    assert new["seq"] > 0 and old["seq"] > 0, states

    # Mirror Service.handleEvent's guard: replay in arrival order, drop older.
    last = {}
    applied = None
    for e in states:
        player = e["player"]
        if e["seq"] > last.get(player, 0):
            last[player] = e["seq"]
            applied = e["nowplaying"].get("title")
    assert applied == "New Song", (applied, states)
    print("ok state seq guard")


def test_queue_op():
    """The queue op returns every playlist entry with the current one flagged."""
    fake = FakeLMS().start()
    fake.tracks = ["First", "Second", "Third"]
    fake.cur_index = 1
    bp = BridgeProc()
    try:
        bp.wait_for(lambda e: e.get("ev") == "hello")
        bp.send({"op": "config", "generation": 1, "host": "127.0.0.1",
                 "port": fake.port, "playerId": PID1})
        bp.wait_for(lambda e: e.get("ev") == "phase" and e.get("phase") == "connected")

        bp.send({"op": "queue", "player": PID1, "tag": "q1"})
        res = bp.wait_for(lambda e: e.get("ev") == "queueResults"
                          and e.get("tag") == "q1")
        assert res["player"] == PID1, res
        assert [i["title"] for i in res["items"]] == ["First", "Second", "Third"], res
        assert [i["artist"] for i in res["items"]] == ["Test Artist"] * 3, res
        assert [i["current"] for i in res["items"]] == [False, True, False], res
        ids = [i["id"] for i in res["items"]]
        assert len(set(ids)) == 3, ids
        assert isinstance(res.get("seq"), int) and res["seq"] > 0, res
        # Queries the playlist from index 0 with title+artist tags.
        assert any(cli[:3] == ["status", "0", "50"] and cli[3] == "tags:aat"
                   for _p, cli in fake.commands), fake.commands
        bp.wait_for(lambda e: e.get("ev") == "result" and e.get("tag") == "q1"
                    and e.get("success") is True)
    finally:
        bp.close()
        fake.stop()
    print("ok queue op")


def test_queue_jump_and_delete():
    """queueJump/queueDelete map to playlist index/delete <N>."""
    fake = FakeLMS().start()
    fake.tracks = ["First", "Second", "Third"]
    fake.cur_index = 0
    bp = BridgeProc()
    try:
        bp.wait_for(lambda e: e.get("ev") == "hello")
        bp.send({"op": "config", "generation": 1, "host": "127.0.0.1",
                 "port": fake.port, "playerId": PID1})
        bp.wait_for(lambda e: e.get("ev") == "phase" and e.get("phase") == "connected")

        bp.send({"op": "queueJump", "player": PID1, "index": 2, "tag": "j1"})
        bp.wait_for(lambda e: e.get("ev") == "result" and e.get("tag") == "j1"
                    and e.get("success") is True)
        assert any(cli == ["playlist", "index", "2"]
                   for _p, cli in fake.commands), fake.commands
        assert fake.cur_index == 2, fake.cur_index

        bp.send({"op": "queueDelete", "player": PID1, "index": 0, "tag": "d1"})
        bp.wait_for(lambda e: e.get("ev") == "result" and e.get("tag") == "d1"
                    and e.get("success") is True)
        assert any(cli == ["playlist", "delete", "0"]
                   for _p, cli in fake.commands), fake.commands
        assert fake.tracks == ["Second", "Third"], fake.tracks

        # A malformed index fails cleanly instead of crashing the bridge.
        bp.send({"op": "queueDelete", "player": PID1, "index": "x", "tag": "d2"})
        bad = bp.wait_for(lambda e: e.get("ev") == "result" and e.get("tag") == "d2")
        assert bad["success"] is False, bad
        assert bp.proc.poll() is None
    finally:
        bp.close()
        fake.stop()
    print("ok queue jump and delete")


def test_queue_stale_seq_guard():
    """A stale queue response must not outrank a newer one.

    The bridge reserves a monotonic seq before the queue query (same counter as
    state); a consumer applies queueResults in arrival order but drops seq <=
    the last applied. A query that started first can return last without
    winning."""
    lb = _load_bridge()
    bridge = lb.Bridge()
    bridge._http = True  # _handle_queue bails without a connection
    bridge._active = "p1"
    emitted = []
    emit_lock = threading.Lock()

    def capture(obj):
        with emit_lock:
            emitted.append(obj)

    bridge.emit = capture

    query_started = threading.Event()
    release_query = threading.Event()
    calls = {"n": 0}

    def fake_jsonrpc(_http, _player, _cli):
        calls["n"] += 1
        if calls["n"] == 1:
            query_started.set()
            release_query.wait(2.0)
            return {"playlist_cur_index": "0", "playlist_loop": [
                {"id": 1, "title": "Old Song", "artist": "A"}]}
        return {"playlist_cur_index": "0", "playlist_loop": [
            {"id": 2, "title": "New Song", "artist": "B"}]}

    lb.jsonrpc = fake_jsonrpc

    # An earlier queue fetch starts and blocks mid-request.
    first = threading.Thread(target=lambda: bridge._handle_queue({"tag": "q1"}))
    first.start()
    assert query_started.wait(2.0), "queue fetch never started"

    # A newer queue fetch completes while the first is still in flight.
    bridge._handle_queue({"tag": "q2"})
    release_query.set()
    first.join(2.0)

    results = [e for e in emitted if e.get("ev") == "queueResults"]
    old = next(e for e in results if e["items"][0]["title"] == "Old Song")
    new = next(e for e in results if e["items"][0]["title"] == "New Song")
    assert new["seq"] > old["seq"], results
    assert new["seq"] > 0 and old["seq"] > 0, results

    # Mirror Service.handleEvent's queue guard: replay in arrival order.
    last = 0
    applied = None
    for e in results:
        if e["seq"] > last:
            last = e["seq"]
            applied = e["items"][0]["title"]
    assert applied == "New Song", (applied, results)
    print("ok queue stale seq guard")


if __name__ == "__main__":
    os.environ.setdefault("PYTHONDONTWRITEBYTECODE", "1")
    test_demo_sequence()
    test_live_connect_command_and_cover()
    test_auth_required_and_recovery()
    test_discovery_demo()
    test_nowplaying_hardening()
    test_bridge_survives_bad_messages()
    test_refresh_op_signature()
    test_search_op()
    test_state_seq_guard()
    test_status_query_uses_current_track()
    test_queue_op()
    test_queue_jump_and_delete()
    test_queue_stale_seq_guard()
    print("\nall bridge tests passed")
