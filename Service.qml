import QtQuick
import Quickshell
import Quickshell.Io
import "ConfigStore.js" as ConfigStore

// Session-wide facade for the Lyrion Music plugin. Owns configuration, the
// keyring credential lifecycle, the bridge process, and the player/now-playing
// state projected to Panel.qml and Settings.qml.
QtObject {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string pluginDir: home + "/.config/omarchy/plugins/io.github.powerk1977.lms"
  readonly property string configDir: home + "/.config/omarchy/lms"
  readonly property string configPath: configDir + "/config.json"

  // ------------------------------------------------------------ connection

  property string phase: "idle"
  property string lastError: ""
  property string lastErrorKind: ""
  readonly property bool connected: phase === "connected"

  property string host: ""
  property int port: 9000
  property string playerId: ""
  property bool demoMode: false
  readonly property bool configured: root.demoMode || root.host !== ""
  readonly property string origin: root.host ? (root.host + ":" + root.port) : ""

  property string username: ""
  property string password: ""
  // 'userpass' | '' — shape of the credential currently in the keyring.
  property string storedCredentialForm: ""

  property int generation: 0

  // ------------------------------------------------------------ credentials

  property CredentialManager credentials: CredentialManager {
    id: credentials
    onTokenReady: function(token, origin) {
      if (origin !== root.origin || !token) return
      var parts = String(token).split("\t")
      root.username = parts.length > 1 ? parts[0] : ""
      root.password = parts.length > 1 ? parts.slice(1).join("\t") : parts[0]
      root.storedCredentialForm = root.password ? "userpass" : ""
      root.pushConfig()
    }
    onCleared: function(origin) {
      if (origin !== root.origin) return
      root.username = ""
      root.password = ""
      root.storedCredentialForm = ""
    }
    onFailed: function(message, origin) {
      if (origin && origin !== root.origin) return
      // A keyring miss is expected during unauthenticated connect; the bridge
      // surfaces the "auth required" signal if the server actually needs one.
      // Credential write/clear errors still surface.
      if (String(message).indexOf("No credential stored") === 0) return
      root.lastError = message
      root.lastErrorKind = "credential"
    }
  }

  readonly property bool credentialBusy: credentials.busy

  // ------------------------------------------------------------ players

  property var players: []
  property string activePlayerId: root.playerId
  property var nowplaying: ({})
  property string coverBase: ""
  property int stateRevision: 0

  readonly property var activePlayer: {
    for (var i = 0; i < root.players.length; i++) {
      if (root.players[i].playerid === root.activePlayerId) return root.players[i]
    }
    return null
  }
  readonly property bool playing: root.nowplaying.mode === "play"
  readonly property string title: root.nowplaying.title || ""
  readonly property string artist: root.nowplaying.artist || ""
  readonly property string coverUrl: {
    if (!root.coverBase || !root.activePlayerId) return ""
    return root.coverBase + "/now/" + encodeURIComponent(root.activePlayerId) + ".jpg"
  }

  // ------------------------------------------------------------ config file

  property FileView configFile: FileView {
    path: root.configPath
    watchChanges: true
    printErrors: false
    atomicWrites: true
    onLoaded: root.applyConfig(text())
    onLoadFailed: root.applyConfig("")
    onFileChanged: reload()
  }

  property Process dirCreator: Process {
    command: ["mkdir", "-p", root.configDir]
    running: false
  }

  function currentConfig() {
    return {
      host: root.host,
      port: root.port,
      playerId: root.playerId,
      demoMode: root.demoMode
    }
  }

  function saveConfig(patch) {
    var next = root.currentConfig()
    for (var k in patch) next[k] = patch[k]
    if (!dirCreator.running) dirCreator.running = true
    configFile.setText(ConfigStore.serialize(next))
  }

  function applyConfig(text) {
    var cfg = ConfigStore.parse(text)
    // Skip reconciliation when the file echoes the current settings
    // (saveConfig's own write hits onFileChanged) so a player selection or
    // connect doesn't tear down and redial the bridge for nothing.
    var dirty = cfg.host !== root.host || cfg.port !== root.port
      || cfg.playerId !== root.playerId || cfg.demoMode !== root.demoMode
    root.host = cfg.host
    root.port = cfg.port
    root.playerId = cfg.playerId
    root.demoMode = cfg.demoMode
    if (cfg.playerId) root.activePlayerId = cfg.playerId
    if (dirty) root.reconcile()
  }

  // ------------------------------------------------------------ reconciliation

  function reconcile() {
    root.generation += 1
    if (!root.configured) {
      root.phase = "idle"
      bridgeController.ensureStarted()
      bridgeController.send({ op: "disconnect" })
      return
    }
    bridgeController.ensureStarted()
    // Connect with whatever is in memory. With no password, connect
    // unauthenticated right away (if LMS requires auth the bridge reports
    // errorKind "auth") and look the keyring up in parallel to upgrade later.
    root.pushConfig()
    if (!root.demoMode && root.origin && !root.password)
      credentials.lookup(root.origin)
  }

  function pushConfig() {
    // Wait until the process is running; ensureStarted() is asynchronous.
    if (!bridgeController.running) return
    bridgeController.send({
      op: "config",
      generation: root.generation,
      host: root.host,
      port: root.port,
      playerId: root.activePlayerId,
      username: root.username,
      password: root.password,
      demoMode: root.demoMode
    })
  }

  function applyConnection(host, port, username, password, demo) {
    var nextHost = ConfigStore.hostName(host)
    var nextPort = ConfigStore.portNumber(port)
    var nextUser = String(username || "")
    var nextPass = String(password || "")
    root.host = nextHost
    root.port = nextPort
    root.username = nextUser
    root.password = nextPass
    root.demoMode = demo === true
    root.activePlayerId = root.playerId
    root.saveConfig({ host: nextHost, port: nextPort, demoMode: root.demoMode })
    if (!root.demoMode && nextHost && (nextPass || nextUser)) {
      var token = nextUser + "\t" + nextPass
      credentials.store(token, nextHost + ":" + nextPort)
      root.storedCredentialForm = nextPass ? "userpass" : ""
    }
    root.reconcile()
  }

  function forgetCredential() {
    if (root.origin) credentials.clear(root.origin)
  }

  function refresh() {
    bridgeController.send({ op: "refresh" })
  }

  function discover() {
    bridgeController.send({ op: "discover" })
  }

  function selectPlayer(id) {
    root.activePlayerId = String(id || "")
    root.playerId = root.activePlayerId
    root.saveConfig({ playerId: root.playerId })
    bridgeController.send({ op: "selectPlayer", player: root.activePlayerId })
  }

  function sendCmd(cli, tag) {
    bridgeController.send({
      op: "cmd",
      player: root.activePlayerId,
      cli: cli,
      tag: tag || ""
    })
  }

  function togglePlay() {
    root.sendCmd([root.playing ? "pause" : "play"], "transport")
  }
  function next() { root.sendCmd(["playlist", "index", "+1"], "transport") }
  function previous() { root.sendCmd(["playlist", "index", "-1"], "transport") }
  function setVolume(percent) { root.sendCmd(["mixer", "volume", Math.round(percent)], "volume") }

  // ------------------------------------------------------------ bridge

  property BridgeController bridgeController: BridgeController {
    executable: root.pluginDir + "/bin/lms-bridge"
    onReady: if (root.configured) root.pushConfig()
    onLine: function(value) { root.handleEvent(value) }
    onStderrLine: function(line) {
      // Surface bridge tracebacks into lastError while not connected —
      // quiet in happy path (bridge writes nothing to stderr normally).
      if (!root.connected) {
        root.lastError = line.trim()
        root.lastErrorKind = "network"
      }
    }
    onFailed: function(message) {
      root.phase = "error"
      root.lastError = message
      root.lastErrorKind = "network"
    }
  }

  function handleEvent(line) {
    var ev
    try {
      ev = JSON.parse(line)
    } catch (e) {
      return
    }
    if (!ev || typeof ev !== "object") return
    if (ev.generation !== undefined && ev.generation < root.generation) return
    switch (ev.ev) {
    case "phase":
      root.phase = ev.phase
      root.lastError = ev.error || ""
      root.lastErrorKind = ev.errorKind || ""
      break
    case "players":
      root.players = ev.items || []
      if (!root.activePlayerId && root.players.length) root.activePlayerId = root.players[0].playerid
      break
    case "state":
      if (ev.player === root.activePlayerId) {
        root.nowplaying = ev.nowplaying || {}
        root.stateRevision += 1
      }
      break
    case "coverbase":
      root.coverBase = ev.url || ""
      break
    case "servers":
      root.serversFound = ev.items || []
      break
    case "log":
      break
    }
  }

  property var serversFound: []

  function playerLabel(id) {
    for (var i = 0; i < root.players.length; i++)
      if (root.players[i].playerid === id) return root.players[i].name
    return id
  }
}
