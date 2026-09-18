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
        text: root.lms && root.lms.playing ? "\u25B6" : "\u266B"
        color: root.barIconColor
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
              value: root.lms.activePlayerId
              options: {
                var out = []
                var players = root.lms.players
                for (var i = 0; i < players.length; i++) {
                  var p = players[i]
                  out.push({ value: p.playerid,
                    label: (p.isplaying ? "\u25B6 " : "") + p.name
                      + (p.isgroup ? "  (group)" : "") })
                }
                return out
              }
              onChanged: function(v) { root.lms.selectPlayer(v) }
            }
          }

          // ---- now playing ----
          Row {
            width: parent.width
            spacing: Style.spacing.md
            visible: root.serviceReady && root.lms.configured
            Rectangle {
              width: Style.space(64)
              height: Style.space(64)
              radius: Style.cornerRadius
              color: Style.hoverFillFor(root.fg, Color.accent)
              clip: true
              Image {
                anchors.fill: parent
                source: root.lms.coverUrl
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                visible: root.lms.coverUrl !== ""
              }
              Text {
                anchors.centerIn: parent
                text: "\u266A"
                color: root.dim
                font.pixelSize: Style.space(24)
                visible: root.lms.coverUrl === ""
              }
            }
            Column {
              width: parent.width - Style.space(74)
              spacing: Style.spacing.xs
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
          }

          // ---- transport ----
          Row {
            width: parent.width
            spacing: Style.spacing.lg
            visible: root.serviceReady && root.lms.configured && root.lms.players.length > 0
            PanelActionButton {
              iconText: "\u23EE"          // previous
              size: Style.space(40)
              bordered: true
              onClicked: root.lms.previous()
            }
            PanelActionButton {
              iconText: root.lms.playing ? "\u23F8" : "\u25B6"   // pause / play
              size: Style.space(40)
              bordered: true
              onClicked: root.lms.togglePlay()
            }
            PanelActionButton {
              iconText: "\u23ED"          // next
              size: Style.space(40)
              bordered: true
              onClicked: root.lms.next()
            }
          }

          // ---- volume ----
          Row {
            width: parent.width
            spacing: Style.spacing.md
            visible: root.serviceReady && root.lms.configured
            Text {
              // md-volume_high / md-volume_off (MDI via Nerd Font, same set as the openhab lightbulb)
              text: (root.lms.nowplaying.volume || 0) === 0 ? "\U000F0581" : "\U000F057E"
              color: root.fg
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

          // ---- actions ----
          Row {
            width: parent.width
            spacing: Style.spacing.md
            Button {
              bordered: true
              text: "Refresh"
              foreground: root.fg
              onClicked: root.lms.refresh()
            }
            Button {
              bordered: true
              text: "Settings"
              foreground: root.fg
              onClicked: root.openSettings()
            }
          }
        }
      }
    }
  }
}