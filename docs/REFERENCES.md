# REFERENCES.md — architecture references for building the plugin

Copy patterns from these, do not reinvent. All local paths are on this
machine (workspace `~/projects`).

## 1. openhab-omarchy — the shape to follow (primary)

`~/projects/openhab-omarchy/`

The proven plugin architecture the plan is built on: a long-lived Python
bridge owning the network connection, talking to Quickshell QML over
**versioned NDJSON on stdin/stdout**.

- `bin/oh-bridge` — the transport owner. **Port this almost exactly**: same
  CLI/NDJSON framing, command dispatch, demo backend used as a fallback.
  Only the backend protocol changes (CometD + jsonrpc.js instead of openHAB
  REST/SSE).
- `BridgeController.qml` — bridge lifecycle + NDJSON transport in QML.
- `Service.qml`, `Panel.qml`, `Settings.qml` — the QML trio (panel popup /
  pop-out window / settings overlay).
- `manifest.json` — the manifest schema to mirror (`schemaVersion`, `id`,
  `kinds`, `entryPoints`, `barWidget.displayName/category/aliases/…`).
- `DEVELOPING.md` — architecture map, security invariants, and the exact
  verification command suite (`python3 tests/test_bridge.py`, `node
  tests/*.js`, `python3 -m py_compile bin/oh-bridge`, `qmllint`,
  `qmlformat`, `omarchy plugin validate .`).
- `tests/fake_openhab.py` + `tests/test_bridge.py` — stdlib `http.server`
  fake backend; tests must **never** depend on a real server/creds/internet.
  Build `tests/fake_lms.py` the same way (speak jsonrpc.js + a stubbed
  CometD long-poll).
- `README.md`"Install" section — `omarchy plugin add <git-url> --enable`,
  `omarchy bar move <id> --section right`.

## 2. akshar.radio-atlas — the closest existing audio plugin (secondary)

`~/.config/omarchy/plugins/akshar.radio-atlas/`

Marketplace-installed, category **Media**, audio playback with a
bar-widget (`BarWidget.qml`) + panel (`RadioAtlas.qml`). Study for:
- Sidecar-process pattern: `radio-player`, `radio-state`, `radio-fetch`,
  `radio-proxy` executables + `radio-status.lua` (shell-side glue to
  Omarchy's media controls / MPRIS).
- `manifest.json` with `"kinds":["panel","bar-widget"]`, `keepLoaded: true`,
  `keywords: [...,"music","mpris"]`, `barWidget.category: "Media"` sway of
  how an audio plugin presents. Category `Media` vs our plan's `Hardware`
  is a deliberate choice (device control), reaffirmed at packaging.

## 3. Marketplace reference copies

- `~/.config/omarchy/plugins/io.github.powerk1977.openhab` —
  installed copy of the openhab-omarchy reference.
- Other installed plugins (sportsbar, omawall, netneighbors, …) — manifest /
  category variety examples; `~/.config/omarchy/plugins/`.

## 4. Upstream

- `https://github.com/konradk/hass` — Home Assistant for Omarchy, the
  upstream reference openhab-omarchy was built against.

## 5. LMS protocol sources used for RESEARCH.md

- lyrion.org / slimdevices JSON-RPC & CLI docs (commands, `playerpref`,
  `syncgroups`).
- Live probing on `http://localhost:9000` and `http://<lan-ip>:9000`
  (see `docs/RESEARCH.md`, every claim carries a verified example).
- `lms-mcp` server (`glama.ai/.../eggs-gd/lms-mcp`): confirmed HTTP Basic
  auth on `jsonrpc.js` with `LMS_USERNAME`/`LMS_PASSWORD` credentials.
- MadPatrick LMS→Domoticz plugin (`github.com/MadPatrick/LMS`): confirmed
  `requests.Session.post(..., auth=(user, pwd))` on every `jsonrpc.js` call.

## Naming / IDs

- Plugin `id` follows the reference convention (`io.github.<author>.<name>`);
  final string decided at packaging (e.g. `io.github.powerk1977.lms`).
- Item/bridge naming conventions follow openhab-omarchy (no baked-in
  instance config; per-user inputs via settings).