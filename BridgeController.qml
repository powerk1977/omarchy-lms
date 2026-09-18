import QtQuick
import Quickshell.Io

// Owns the helper process and the only NDJSON write path. All commands from
// Service.qml flow through this write; the bridge never reads argv for
// connection state (demo mode is a field of the `config` op, not a launch
// flag), so the process command is static.
QtObject {
  id: root

  required property string executable
  readonly property bool running: process.running
  readonly property bool restarting: restartCommand !== null
  property var restartCommand: null

  signal line(string value)
  signal ready()
  signal failed(string message)

  function ensureStarted() {
    var wanted = [root.executable]
    if (process.running) {
      if (JSON.stringify(process.command) === JSON.stringify(wanted)
          && root.restartCommand === null) return true
      root.restartCommand = wanted
      process.signal(15)
      return false
    }
    process.command = wanted
    process.running = true
    return false
  }

  function send(command) {
    if (!process.running || root.restartCommand !== null) return false
    var payload = {}
    for (var key in command) payload[key] = command[key]
    payload.protocolVersion = 1
    process.write(JSON.stringify(payload) + "\n")
    return true
  }

  property Process process: Process {
    command: [root.executable]
    stdinEnabled: true

    stdout: SplitParser {
      onRead: function(value) { root.line(value) }
    }

    onStarted: {
      root.ready()
    }

    onExited: function(exitCode) {
      if (root.restartCommand !== null) {
        process.command = root.restartCommand
        root.restartCommand = null
        process.running = true
        return
      }
      root.failed("Bridge exited (code " + exitCode + ").")
    }
  }
}