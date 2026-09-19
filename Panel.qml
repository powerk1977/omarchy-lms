import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Bar button plus popup: player list, now-playing, transport, and volume for
// Lyrion Music Server. The service owns the connection and the player state.
Panel {
  id: root
  moduleName: "io.github.powerk1977.lms"
  ipcTarget: "io.github.powerk1977.lms"
  manageIpc: false

  readonly property var lms: bar && bar.shell ? bar.shell.serviceFor("io.github.powerk1977.lms") : null
  readonly property bool serviceReady: lms !== null
  readonly property string phase: serviceReady ? lms.phase : "idle"

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property color selectedFill: Style.selectedFillFor(fg, Color.accent)

  // Nerd Font (MDI) glyphs — same literals the omarchy.media plugin uses.
  // String.fromCharCode would truncate these past-BMP codepoints to their
  // low 16 bits (hence the old "f"-looking gear), so keep them as literals.
  readonly property string family: bar ? bar.fontFamily : Style.font.family
  readonly property string glyphPlay: "󰐊"    // md-play
  readonly property string glyphPause: "󰏤"   // md-pause
  readonly property string glyphPrev: "󰒮"    // md-skip-previous
  readonly property string glyphNext: "󰒭"    // md-skip-next
  readonly property string glyphNote: "󰝚"    // md-music (cover placeholder)
  readonly property string glyphMusic: "󰐉"   // md-music-note (idle state)
  readonly property string glyphGear: "󰒓"    // md-cog
  readonly property string glyphVolHi: "󰕾"   // md-volume-high
  readonly property string glyphVolOff: "󰖁"  // md-volume-off
  readonly property bool controlsActive: serviceReady && lms.connected

  // Elapsed playhead, seconds. Re-synced from every pushed state (server is
  // authoritative); ticks locally between pushes.
  readonly property int revision: serviceReady ? lms.stateRevision : 0
  property real elapsed: 0
  onRevisionChanged: elapsed = serviceReady ? (lms.nowplaying.time || 0) : 0

  function mmss(sec) {
    sec = Math.max(0, Math.round(sec || 0))
    var s = sec % 60
    return Math.floor(sec / 60) + ":" + (s < 10 ? "0" : "") + s
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.serviceReady && root.lms.playing
      && (root.lms.nowplaying.duration || 0) > 0
    onTriggered: root.elapsed = Math.min(root.lms.nowplaying.duration || 0,
                                         root.elapsed + 1)
  }

  function openSettings() {
    if (!bar || !bar.shell || typeof bar.shell.summon !== "function") return
    close()
    bar.shell.summon("io.github.powerk1977.lms", JSON.stringify({ tab: "connection" }))
  }

  readonly property color iconColor: phase === "connected" ? fg : Qt.darker(fg, 1.5)
  readonly property color barIconColor: phase === "error"
    ? (bar ? bar.urgent : Color.urgent) : iconColor

  onOpenedChanged: if (opened && root.serviceReady) root.lms.refresh()

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  IpcHandler {
    target: "io.github.powerk1977.lms"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { if (root.serviceReady) root.lms.refresh() }

    function status(): string {
      if (!root.serviceReady) return "service: UNREACHABLE"
      return "phase=" + root.lms.phase + " players=" + root.lms.players.length
        + " playing=" + root.lms.playing + " title=" + root.lms.title
        + (root.lms.lastError ? " error=" + root.lms.lastError : "")
    }

    function playPause(): string {
      if (!root.serviceReady) return "service unavailable"
      root.lms.togglePlay()
      return "ok"
    }

    function next(): string {
      if (!root.serviceReady) return "service unavailable"
      root.lms.next()
      return "ok"
    }

    function previous(): string {
      if (!root.serviceReady) return "service unavailable"
      root.lms.previous()
      return "ok"
    }

    function settings(): void { root.openSettings() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Text {
        anchors.centerIn: parent
        text: root.lms && root.lms.playing ? root.glyphPlay : root.glyphMusic
        color: root.barIconColor
        font.family: root.family
        font.pixelSize: Style.bar.iconCanvas * 0.8
      }
    }
    foreground: root.barIconColor
    active: root.phase === "error"
    onPressed: root.toggle()
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTextKey: function(key) {
        if (String(key).toLowerCase() === "s") root.openSettings()
      }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: content
          width: parent.width
          spacing: Style.spacing.md

          PanelHero {
            width: parent.width
            title: "Lyrion"
            meta: root.phase
            foreground: root.fg
            iconOpacity: root.phase === "connected" ? 1.0 : 0.55
            iconComponent: Component {
              Text {
                color: root.phase === "error"
                  ? (bar ? bar.urgent : Color.urgent) : root.fg
                font.family: root.family
                font.pixelSize: Style.font.display
                text: root.lms && root.lms.playing ? root.glyphPlay : root.glyphMusic
              }
            }
            trailingControl: Component {
              Row {
                spacing: Style.spacing.xs
                PanelActionButton {
                  iconText: root.glyphGear
                  fontFamily: root.family
                  tooltipText: "Settings"
                  foreground: Qt.darker(root.fg, 1.4)
                  onClicked: root.openSettings()
                }
              }
            }
          }

          // ---- not configured / error ----
          Text {
            width: parent.width
            visible: !root.serviceReady || !root.lms.configured
            text: root.serviceReady ? "No Lyrion server configured" : "Service unavailable"
            color: root.fg
            wrapMode: Text.WordWrap
          }
          Text {
            width: parent.width
            visible: root.phase === "error" && root.lms && root.lms.lastError !== ""
            text: root.lms ? root.lms.lastError : ""
            color: bar ? bar.urgent : Color.urgent
            wrapMode: Text.WordWrap
          }

          // ---- player picker ----
          Column {
            width: parent.width
            spacing: Style.spacing.sm
            visible: root.serviceReady && root.lms.players.length > 0
            PanelSectionHeader {
              text: "Players"
              color: root.fg
            }
            Dropdown {
              width: parent.width
              foreground: root.fg
              accent: root.fg
              value: root.lms.activePlayerId
              options: {
                var out = []
                var players = root.lms.players
                for (var i = 0; i < players.length; i++) {
                  var p = players[i]
                  out.push({ value: p.playerid,
                    label: (p.isplaying ? root.glyphPlay + " " : "") + p.name
                      + (p.isgroup ? "  (group)" : "") })
                }
                return out
              }
              onChanged: function(v) { root.lms.selectPlayer(v) }
            }
          }

          // ---- volume ----
          Row {
            width: parent.width
            spacing: Style.spacing.md
            visible: root.serviceReady && root.lms.configured
            Text {
              text: (root.lms.nowplaying.volume || 0) === 0
                ? root.glyphVolOff : root.glyphVolHi
              color: root.fg
              font.family: root.family
              font.pixelSize: Style.font.body
              verticalAlignment: Text.AlignVCenter
            }
            PanelSlider {
              id: volume
              width: parent.width - Style.space(28)
              bar: root.bar
              value: root.lms.nowplaying.volume || 0
              minimum: 0
              maximum: 100
              integer: true
              onMoved: function(v) { root.lms.setVolume(v) }
            }
          }

          // ---- album art ----
          Rectangle {
            width: parent.width
            height: width
            radius: Style.cornerRadius
            color: Style.hoverFillFor(root.fg, Color.accent)
            clip: true
            visible: root.serviceReady && root.lms.configured
            Image {
              id: coverImg
              anchors.fill: parent
              source: root.lms.coverUrl
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
              sourceSize.width: width
              sourceSize.height: height
              // Hide while (re)loading so a previous cover can never linger
              visible: root.lms.coverUrl !== "" && coverImg.status === Image.Ready
            }
            Text {
              anchors.centerIn: parent
              text: root.glyphNote
              color: root.dim
              font.family: root.family
              font.pixelSize: Style.space(40)
              visible: root.lms.coverUrl === "" || coverImg.status !== Image.Ready
            }
          }

          // ---- progress ----
          Row {
            width: parent.width
            spacing: Style.spacing.sm
            visible: root.serviceReady && root.lms.configured
              && (root.lms.nowplaying.duration || 0) > 0
            Text {
              text: root.mmss(progress.dragging ? progress.liveValue : root.elapsed)
              color: root.dim
              font.family: root.family
              font.pixelSize: Style.font.caption
              verticalAlignment: Text.AlignVCenter
            }
            PanelSlider {
              id: progress
              width: parent.width - Style.space(84)
              bar: root.bar
              value: root.elapsed
              minimum: 0
              maximum: Math.max(1, root.lms.nowplaying.duration || 1)
              integer: true
              onReleased: function(v) {
                root.elapsed = v
                root.lms.seek(v)
              }
            }
            Text {
              text: root.mmss(root.lms.nowplaying.duration || 0)
              color: root.dim
              font.family: root.family
              font.pixelSize: Style.font.caption
              verticalAlignment: Text.AlignVCenter
            }
          }

          // ---- song info ----
          Column {
            width: parent.width
            spacing: Style.spacing.xs
            visible: root.serviceReady && root.lms.configured
            Text {
              width: parent.width
              text: root.lms.title || "—"
              color: root.fg
              elide: Text.ElideRight
              font.bold: true
              font.pixelSize: Style.font.body
            }
            Text {
              width: parent.width
              text: root.lms.artist || ""
              color: root.dim
              elide: Text.ElideRight
              font.pixelSize: Style.font.body
            }
            Text {
              width: parent.width
              text: root.lms.nowplaying.album || ""
              color: root.dim
              opacity: 0.7
              elide: Text.ElideRight
              font.pixelSize: Style.font.caption
            }
          }

          // ---- transport ----
          Row {
            width: parent.width
            spacing: Style.spacing.lg
            visible: root.serviceReady && root.lms.configured && root.lms.players.length > 0
            PanelActionButton {
              iconText: root.glyphPrev            // previous
              size: Style.space(40)
              bordered: true
              fontFamily: root.family
              foreground: root.fg
              color: "transparent"
              enabled: root.controlsActive
              onClicked: root.lms.previous()
            }
            PanelActionButton {
              iconText: root.lms.playing ? root.glyphPause : root.glyphPlay
              size: Style.space(40)
              bordered: true
              fontFamily: root.family
              foreground: root.fg
              color: "transparent"
              enabled: root.controlsActive
              onClicked: root.lms.togglePlay()
            }
            PanelActionButton {
              iconText: root.glyphNext            // next
              size: Style.space(40)
              bordered: true
              fontFamily: root.family
              foreground: root.fg
              color: "transparent"
              enabled: root.controlsActive
              onClicked: root.lms.next()
            }
          }
        }
      }
    }
  }
}