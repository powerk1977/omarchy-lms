# Omarchy LMS Plugin

Private repository: <https://github.com/powerk1977/omarchy-lms> (flipped public only at marketplace packaging / release candidate).

A first-party Omarchy plugin for Lyrion Music Server (LMS / Squeezebox):
discover servers on the local network, control any player connected to a
server, browse and select music, and manage sync groups including per-player
audio delay.

This repository is the design/planning home for the plugin. The approved
design lives in `docs/Tier3_Design_Plan_v4.1.docx`; all protocol research,
live-environment facts, and decisions are captured in `docs/RESEARCH.md`
so any agent (or human) can pick the project up without redoing discovery.

## Status

- Design plan v4 approved by the author — category **Hardware**, marketplace-listing ready.
- Scope includes password-protected servers: HTTP Basic auth on `jsonrpc.js`/CometD,
  keyring-only credentials, and a localhost cover-art proxy (still being verified
  against a live password-enabled server — see `docs/RESEARCH.md`).
- Held in a **private** GitHub repo (`powerk1977/omarchy-lms`) until the first release
  candidate; flipped public only at marketplace packaging.
- **Build not started.** Phase 1 (marketplace-ready plugin) is the next workstream.

## Documents

- `docs/Tier3_Design_Plan_v4.1.docx` — the approved plan (letter). v4.1 adds the
  authentication/secure-server section; the regenerable `.html` source sits alongside.
- `docs/Tier3_Design_Plan_v3.pdf` — the author's original plan (superseded reference).
- `docs/RESEARCH.md` — verified protocol facts, live environment, curl probes, decisions.
- `docs/REFERENCES.md` — local/remote reference architectures and what to copy from them.
- `research/` — working live LMS client code and openHAB Squeezebox-binding item definitions
  (real server/player IDs, JSON-RPC usage).

## Validation

Source validation once the plugin exists (per the reference repo):

```bash
omarchy plugin validate .
python3 tests/test_bridge.py
```