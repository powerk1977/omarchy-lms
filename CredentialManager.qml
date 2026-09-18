import QtQuick
import Quickshell.Io

// Serialized system-keyring adapter. It owns every short-lived plaintext copy
// of a token and never places one in argv. Service.qml decides whether the
// origin returned by a completed operation is still the active connection.
QtObject {
  id: root

  readonly property bool busy: writePending || clearPending
    || lookupPending

  property bool writePending: false
  property bool writeStarted: false
  property string writeToken: ""
  property string writeOrigin: ""

  property bool clearPending: false
  property bool clearStarted: false
  property string clearOrigin: ""

  property bool lookupPending: false
  property bool lookupStarted: false
  property string lookupOrigin: ""
  property string lookupToken: ""

  signal tokenReady(string token, string origin)
  signal cleared(string origin)
  signal failed(string message, string origin)

  function store(token, origin) {
    if (root.busy || !token || !origin) {
      root.failed("A keyring operation is already in progress.", origin || "")
      return false
    }
    root.writeToken = String(token)
    root.writeOrigin = String(origin)
    root.writePending = true
    root.writeStarted = false
    storeProcess.command = [
      "secret-tool", "store", "--label=Lyrion Music (Omarchy)",
      "service", "omarchy-lms", "origin", root.writeOrigin
    ]
    storeProcess.stdinEnabled = true
    storeProcess.running = true
    writeStartTimeout.restart()
    return true
  }

  function clear(origin) {
    if (root.busy || !origin) {
      root.failed("A keyring operation is already in progress.", origin || "")
      return false
    }
    root.clearOrigin = String(origin)
    root.clearPending = true
    root.clearStarted = false
    clearProcess.command = [
      "secret-tool", "clear", "service", "omarchy-lms", "origin", root.clearOrigin
    ]
    clearProcess.running = true
    clearStartTimeout.restart()
    return true
  }

  function lookup(origin) {
    if (root.busy || !origin) return false
    root.lookupOrigin = String(origin)
    root.lookupToken = ""
    root.lookupPending = true
    root.lookupStarted = false
    lookupProcess.command = [
      "secret-tool", "lookup", "service", "omarchy-lms", "origin", root.lookupOrigin
    ]
    lookupProcess.running = true
    lookupStartTimeout.restart()
    return true
  }

  property Timer writeStartTimeout: Timer {
    interval: 5000
    onTriggered: {
      if (!root.writePending || root.writeStarted) return
      var origin = root.writeOrigin
      root.writeToken = ""
      root.writeOrigin = ""
      root.writePending = false
      root.failed("Could not start secret-tool to store the token.", origin)
      if (storeProcess.running) storeProcess.signal(15)
    }
  }

  property Timer clearStartTimeout: Timer {
    interval: 5000
    onTriggered: {
      if (!root.clearPending || root.clearStarted) return
      var origin = root.clearOrigin
      root.clearOrigin = ""
      root.clearPending = false
      root.failed("Could not start secret-tool to remove the token.", origin)
      if (clearProcess.running) clearProcess.signal(15)
    }
  }

  property Timer lookupStartTimeout: Timer {
    interval: 5000
    onTriggered: {
      if (!root.lookupPending || root.lookupStarted) return
      var origin = root.lookupOrigin
      root.lookupPending = false
      root.failed("Could not start secret-tool to read the token.", origin)
      if (lookupProcess.running) lookupProcess.signal(15)
    }
  }

  property Process storeProcess: Process {
    command: []
    stdinEnabled: true
    onStarted: {
      if (!root.writePending) {
        storeProcess.signal(15)
        return
      }
      root.writeStarted = true
      writeStartTimeout.stop()
      storeProcess.write(root.writeToken + "\n")
      storeProcess.stdinEnabled = false
    }
    onExited: function(exitCode) {
      if (!root.writePending) return
      writeStartTimeout.stop()
      var token = root.writeToken
      var origin = root.writeOrigin
      root.writeToken = ""
      root.writeOrigin = ""
      root.writePending = false
      root.writeStarted = false
      if (exitCode !== 0) {
        root.failed("Could not write the credential to the keyring.", origin)
        return
      }
      root.tokenReady(token, origin)
    }
  }

  property Process clearProcess: Process {
    command: []
    onStarted: {
      if (!root.clearPending) {
        clearProcess.signal(15)
        return
      }
      root.clearStarted = true
      clearStartTimeout.stop()
    }
    onExited: function(exitCode) {
      if (!root.clearPending) return
      clearStartTimeout.stop()
      var origin = root.clearOrigin
      root.clearOrigin = ""
      root.clearPending = false
      root.clearStarted = false
      // Exit 1 means no matching item; the desired state is already reached.
      if (exitCode !== 0 && exitCode !== 1) {
        root.failed("Could not remove the token from the keyring. Retry removal.",
                    origin)
        return
      }
      root.cleared(origin)
    }
  }

  property Process lookupProcess: Process {
    command: []
    stdout: SplitParser {
      onRead: function(value) {
        if (root.lookupPending && !root.lookupToken) {
          root.lookupToken = String(value || "").trim()
        }
      }
    }
    onStarted: {
      if (!root.lookupPending) {
        lookupProcess.signal(15)
        return
      }
      root.lookupStarted = true
      lookupStartTimeout.stop()
    }
    onExited: function(exitCode) {
      if (!root.lookupPending) return
      lookupStartTimeout.stop()
      var origin = root.lookupOrigin
      root.lookupPending = false
      root.lookupStarted = false
      var token = exitCode === 0 ? root.lookupToken : ""
      root.lookupToken = ""
      if (token) root.tokenReady(token, origin)
      else root.failed(
        "No credential stored for this Lyrion server.", origin)
    }
  }
}