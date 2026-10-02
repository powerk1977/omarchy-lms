# RESEARCH.md — Lyrion Music Server (LMS) plugin

Distilled, verified facts for building the LMS plugin. Every protocol detail
below was confirmed live (this box or the LAN server) unless marked "pin in
P1". Nothing here is a guess; anything unverified is explicitly flagged.

## Live environment

Two servers were probed during planning. Both answer HTTP JSON-RPC on
`:9000`.

| Server | Version | Players | Notes |
|---|---|---|---|
| `http://localhost:9000` (= `127.0.0.1:9000`) | LMS 9.x | 2 | A SqueezeLite player (powered ON, on this machine) and a remote RaopBridge/squeezelite player. 945 albums. |
| `http://<lan-ip>:9000` | LMS 9.1.1 | 3 | Includes a **Whole house** sync group (`model":"group"`, `isgroup:1`). 10,386 songs / 1,176 artists / 65 genres. |

The localhost server is the primary test target (the local SqueezeLite
player runs on this machine).

Player enumeration identifies sync groups: entries with
`isgroup == 1` or `model == "group"` are groups, not standalone players.
Accessory/casting nodes (TVs, consoles, laptops) can be excluded by name
when enumerating.

## Transport: HTTP JSON-RPC (commands)

- Endpoint: `POST http://<host>:9000/jsonrpc.js`
- Content-Type: `application/json`
- Framing (verified by live code and curls):

```bash
curl -s -X POST http://localhost:9000/jsonrpc.js \
  -H 'Content-Type: application/json' \
  -d '{"id":1,"method":"slim.request","params":["",["serverstatus","0","100"]]}'
```

`params[0]` is the player id (`""` / `"0"` = server-wide), `params[1]` is the
command array. Response: `{"id":1,"method":"slim.request","result":{...}}`.

## Transport: CometD / Bayeux real-time (state push) — VERIFIED

**No polling anywhere.** CometD endpoint is `/cometd`.

Handshake (verified):

```bash
curl -s -X POST http://localhost:9000/cometd -H 'Content-Type: application/json' \
  -d '[{"advice":{"interval":0,"timeout":0},"channel":"/meta/handshake","id":"1",\
       "supportedConnectionTypes":["long-polling"],"version":"1.0"}]'
```

→ `{"successful":true,"clientId":"<id>","advice":{"reconnect":"retry","timeout":60000,"interval":0},...}`
The 60000 ms advice timeout means one long-poll hold lasts ~60 s.

Subscribe (verified). Both channel spellings are accepted; use
`/player/<playerid>`:

```bash
curl -s -X POST http://localhost:9000/cometd -H 'Content-Type: application/json' \
  -d "[{\"advice\":{\"timeout\":0},\"channel\":\"/meta/subscribe\",\
       \"clientId\":\"$CID\",\"id\":\"2\",\"subscription\":\"/player/<playerid>\"}]"
```

→ `{"successful":true,"channel":"/meta/subscribe","subscription":"/player/…"}`
Confirmed working: `/player/<id>` and `/slim/player/<id>`.

PIN IN P1: the shape of the pushed `channel:"/player/<id>"` message payloads
(track/transport/volume/sync membership), which server-wide channels exist
(e.g. `/serverstatus`), and reconnect/backoff behavior across an LMS restart.
Capture real push payloads during a normal play/stop/pause sequence.

## Commands catalog

Enumerate players:
`["players",0,100]` → `result.players_loop` (`name`, `playerid`, `model`,
`isplaying`, `power`, `connected`, `isgroup`).

Selected player's prefs in one call: `["players",0,5,"playerprefs:<name>"]`.

Sync groups: `["syncgroups"]`; group membership tags `sync_master` /
`sync_slaves`; join/leave via `["sync","<playerid>"]` (or `"sync","-"` to
unsync); targeting the group id controls the set.

Search / browse: `["albums"|"tracks"|"artists"|"playlists",0,50,"search:<q>"]`
and hierarchical `["menu:…"]` queries (Artists Albums Tracks, Genres,
Playlists, Radio). Add-locally flag: `"search:<q>", "add"`.

Transport controls: play/pause/next/prev, volume (`"mixer","volume",<n>`),
seek, power (`"power",0|1`).

## Audio sync delay (multi-room echo)

- Per-player pref, written `["playerpref","<id>","<token>","<ms>"]`.
- Read probe (verified) shows the pref returns `null` when unset:

```bash
curl -s -X POST http://localhost:9000/jsonrpc.js -H 'Content-Type: application/json' \
  -d '{"id":1,"method":"slim.request",\
       "params":["<playerid>",["playerpref","<playerid>","syncDelay","?"]]}'
```

→ `"result":{"_p2":null}` — so "unset" and "0 ms" are distinguishable only by
writing; treat `null` as "no delay set".

PIN IN P1: the exact pref token name (candidate `syncDelay`), value range
(~0–5000 ms) and sign/direction, by writing a small value on a synced player
and listening for how the group behaves (map to the manual write via LM S
Settings → Player → Synchronize → "Player Audio Delay"). Applies on next
resync and persists across unsyncs. Slider should appear only when the player
is synced.

## Cover art

- Per album/track: `http://<host>:9000/music/<trackid>/cover` (and
  `…/cover.jpg?player=<id>`).
- Now-playing: `http://<host>:9000/music/current/cover.jpg?player=<id>`.
- On password-protected servers these URLs also require credentials. QML's
  `<Image>` cannot attach an Authorization header, so the bridge serves cover
  art through a localhost proxy (bridge binds `127.0.0.1:*`, QML loads images
  from it, bridge forwards with its stored creds). See Authentication below.

## Authentication (server security enabled)

Mechanism — **verified against two independent working implementations**:

- LMS security is the `authorize` server preference (Settings → Security).
  When on, CLI/telnet (9090) requires `login` as the **first** command and
  disconnects otherwise — but that is the telnet path only.
- `jsonrpc.js` over HTTP uses **HTTP Basic auth** on every request. Confirmed
  by:
  - `lms-mcp` server: `LMS_USERNAME` / `LMS_PASSWORD` — "HTTP basic auth user
    (only if password protection is on)".
  - MadPatrick LMS→Domoticz plugin: `self.auth = (user, pwd)` passed as
    `requests` auth on every `jsonrpc.js` POST; username/password optional,
    only required when LMS auth is enabled.
- Stock LMS has a single server password (no user accounts), but an empty or
  arbitrary username works; some deployments put LMS behind a reverse proxy
  (nginx/tailscale) with its **own** Basic auth — supporting Basic headers
  covers both cases.

Design decisions for this plugin:

- **Credentials live only in the system keyring** (secret-tool via the same
  `CredentialManager.qml` flow as openhab-omarchy's API token). Never in
  config, never in process args.
- **Connect flow**: unauthenticated `serverstatus` probe fails →
  panel shows "auth required" → prompt for username/password → "Test"
  button validates; remembered-server list keeps an `authRequired` flag.
  Discovery sweep does the same per candidate.
- **Bridge-proxy cover art**: bridge serves `/music/<id>/cover` over a
  localhost endpoint using its creds, so images work on secured servers
  without leaking creds into QML.
- Audio streaming is untouched: player devices pull streams from LMS
  themselves, not through the plugin.

PIN IN P1 (needs a password-enabled server; cannot be tested on the current
unsecured localhost setup):

1. Exact failure signal of an unauthenticated request on a secured server
   (HTTP 401 vs empty `{}` / disconnect).
2. Whether `/cometd` handshake/subscribe honors the same HTTP Basic header.
3. Cover-art endpoint auth behavior (header vs cookie) and proxy scope.

## Approved design decisions (author sign-off → v4)

- **Real-time**: CometD push, zero polling; progress bar ticks client-side
  between pushes (Material model).
- **Discovery**: HTTP sweep of the local subnet on `:9000`, validated via
  `serverstatus` (name from `_name`); manual `host:port` entry with a Test
  button is the guaranteed path; remembered-server list with auto-connect to
  last used. Phase 2: UDP 3483 probe if the sweep underperforms.
- **Player control**: dropdown selector (OmaOneDrive account-switcher
  pattern); per-player play/pause/next/prev, volume, seek, power.
- **Browsing**: panel search + hierarchical `menu:` browse + `lms-bridge pick`
  routed through fzf (numbered-list fallback); play now / add to queue /
  play on selected player.
- **No interactive install wizard** (Omarchy installs are non-interactive).
- **No keybinding writes in Phase 1** (`bindings.lua` is user-owned). Phase 2
  optional "Add media keys" toggle → `o.bind(XF86AudioPlay|Next|Prev)`,
  reversible via `hl.unbind`.
- **Marketplace**: category `Hardware`; 2–3 tags from the 13-tag taxonomy at
  packaging time, finalized against `registry.json`. No existing LMS plugin
  in the marketplace — niche open.
- **Security (password-protected servers)**: HTTP Basic auth on every
  `jsonrpc.js` + CometD request; keyring-only credential storage; localhost
  cover-art proxy (author decision — see Authentication above).

## Constraints (from the reference plugin bar, apply to this one)

- Python 3.11+, **standard library only** in the bridge. No npm/pip/venv at
  install; must remain installable with no first-run downloads.
- No secrets in config, none in process args. Token/credential flows through
  the keyring when auth exists.
- HTTP Basic auth on `jsonrpc.js` when server security is enabled (see
  Authentication above); keyring-stored, prompted at connect via the Test
  button.
- Exponential backoff on reconnect; stale-generation filtering on connection.

## Phase map & exit criteria

- **P1 — marketplace-ready**: bridge + CometD push + QML trio (Service /
  BarWidget / Panel) + discovery + player control + sync delay +
  browse/search + fzf picker + **Basic-auth support + keyring credential
  flow + localhost cover-art proxy** + manifest + self-check.
  *Exit: plays music on every player type; delay slider works on a synced
  player; auth flow works against a password-enabled server; tests pass.*
- **P2 — optional**: terminal TUI (Go + Bubble Tea) advanced console; UDP
  3483 probe; media-key toggle; CometD hardening. *Only if demand appears.*
- **P3 — deferred**: AI-agent bridge (YAGNI — agents call JSON-RPC directly).

## Open items to pin during Phase 1

1. CometD push payload shapes + server-wide channel names — the bridge
   re-queries the pushed player, so this is a record-only item, not a block.
2. `playerpref` sync-delay token name, range, and sign.
3. Subnet-sweep cost on real LANS (timeout/heuristics).
4. Whether Material's `/slim/player` vs `/player` matters for anything
   (both verified accepted; `/player` is the recommended spelling).
5. Auth behavior on a password-enabled server: failure signal (bridge treats
   a non-JSON `serverstatus` body as auth), `/cometd` Basic-auth acceptance,
   cover-art auth, proxy scope.

## Build status (Phase 1)

- `bin/lms-bridge` implemented, live-verified against `localhost:9000`
  (players list, now-playing re-query, cover proxy, command round-trip, CometD
  subscribe with reconnect/backoff, Basic-auth failure → `errorKind: auth`).
  Covered by `tests/fake_lms.py` + `tests/test_bridge.py` (no network/creds).
- QML trio + `CredentialManager.qml` + `manifest.json` written. `omarchy plugin
  validate .` passes; qmllint clean at reference parity; the plugin is
  discoverable via the shell catalog.
- Not yet built: sync-group UI (join/unsync + delay slider — the underlying
  `sync`/`syncgroups`/`playerpref` commands already work through the generic
  `cmd` op), search/browse panel, `pick` wired into the bar, marketplace
  packaging.

## Holds / directives from the author

- openHAB #6770: **hold** — do not file anything on it until the author revisits.