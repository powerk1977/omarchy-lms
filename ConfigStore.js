.pragma library

// Persisted configuration for the Lyrion plugin. Only non-secret fields live
// here; credentials are in the system keyring (see CredentialManager.qml).

var KEYS = ["host", "port", "playerId", "demoMode"]

function hostName(value) {
  if (typeof value !== "string") return ""
  var v = value.trim()
  if (!v || v.length > 253) return ""
  if (!/^[A-Za-z0-9.\-]+$/.test(v)) return ""
  return v
}

function portNumber(value) {
  var n = parseInt(value, 10)
  if (!isFinite(n) || n < 1 || n > 65535) return 9000
  return n
}

function playerIdString(value) {
  if (typeof value !== "string") return ""
  var v = value.trim()
  if (!v || v.length > 100) return ""
  if (!/^[A-Za-z0-9:_\-\.]+$/.test(v)) return ""
  return v
}

function parse(text) {
  var obj = {}
  try {
    obj = JSON.parse(text || "{}")
  } catch (e) {
    obj = {}
  }
  if (!obj || typeof obj !== "object") obj = {}
  return {
    host: hostName(obj.host),
    port: portNumber(obj.port),
    playerId: playerIdString(obj.playerId),
    demoMode: obj.demoMode === true
  }
}

function serialize(config) {
  return JSON.stringify({
    host: hostName(config.host),
    port: portNumber(config.port),
    playerId: playerIdString(config.playerId),
    demoMode: config.demoMode === true
  }, null, 2) + "\n"
}
