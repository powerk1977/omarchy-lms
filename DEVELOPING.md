# Lyrion Music for Omarchy

Control Lyrion Music Server (LMS / Squeezebox) players from the bar: now
playing, transport, volume, player selection, and per-server credentials.

A long-lived Python helper (`bin/lms-bridge`, standard library only) owns the
LMS connection and talks NDJSON protocol v1 on stdin/stdout, mirroring
`io.github.powerk1977.openhab`. Credentials travel over stdin via the `config`
op, are stored in the system keyring only (`CredentialManager.qml`,
`secret-tool`, service `omarchy-lms`), and never appear in argv or config.

Runtime dependency: Python 3.11+ (no pip/npm/venv) and `secret-tool`.

## Architecture

- `Service.qml`: session-wide facade — config, keyring credential lifecycle,
  bridge process, player/now-playing state for the widgets.
- `BridgeController.qml`: process lifecycle + NDJSON transport.
- `CredentialManager.qml`: serialized system-keyring access.
- `Panel.qml`: bar widget — player list, now playing, transport, volume.
- `Settings.qml`: connection overlay — host/port, discover, keyring password.
- `bin/lms-bridge`: LMS JSON-RPC (`/jsonrpc.js`) + CometD long-poll adapter,
  cover-art proxy on `127.0.0.1`, and the `lms-bridge pick <query>` terminal
  picker (prints to fzf when present).

## Testing

```sh
PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1 python3 tests/test_bridge.py
```

The tests need no network, credentials, or real server: `tests/fake_lms.py`
is an in-process fake LMS.

## Validation

```sh
omarchy plugin validate .
/usr/lib/qt6/bin/qmllint -I /usr/lib/qt6/qml -I /path/to/shell qml  # see below
```

`qs.Ui`/`qs.Commons` live under the Omarchy source tree (e.g.
`/usr/share/omarchy/shell/{Ui,Commons}`); qmllint expects the standard
`qs/<name>` layout, so point `-I` at a directory where those resolve.