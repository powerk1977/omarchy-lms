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

        # Cover proxy forwards the artwork from the LMS.
        with urllib.request.urlopen(base_ev["url"] + "/now/" + PID1 + ".jpg",
                                    timeout=5) as res:
            assert res.read() == COVER_JPEG

        # Percent-encoded request paths (as the panel's encodeURIComponent
        # emits) must not be double-encoded when proxied upstream — the player
        # id the fake LMS sees must round-trip to the real id.
        with urllib.request.urlopen(
                base_ev["url"] + "/now/" + urllib.parse.quote(PID1, safe="") + ".jpg",
                timeout=5) as res:
            assert res.read() == COVER_JPEG
        assert fake.cover_paths, fake.cover_paths
        assert any(urllib.parse.unquote(p) == "/music/current/cover.jpg"
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
    import importlib.machinery
    import importlib.util
    spec = importlib.util.spec_from_loader(
        "lms_bridge", importlib.machinery.SourceFileLoader("lms_bridge", str(BRIDGE)))
    lb = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(lb)

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


if __name__ == "__main__":
    os.environ.setdefault("PYTHONDONTWRITEBYTECODE", "1")
    test_demo_sequence()
    test_live_connect_command_and_cover()
    test_auth_required_and_recovery()
    test_discovery_demo()
    test_nowplaying_hardening()
    test_bridge_survives_bad_messages()
    test_refresh_op_signature()
    print("\nall bridge tests passed")
