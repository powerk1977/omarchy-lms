import QtQuick
import QtQuick.Controls
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

  function openSettings() {
    if (!bar || !bar.shell || typeof bar.shell.summon !== "function") return
    close()
    bar.shell.summon("io.github.powerk1977.lms", JSON.stringify({ tab: "connection" }))
  }

  readonly property color iconColor: {
    var base = bar ? bar.barForeground : Color.foreground
    return root.phase === "connected" ? base : Qt.darker(base, 1.5)
  }
  readonly property color barIconColor: root.phase === "error"
    ? (bar ? bar.urgent : Color.urgent) : root.iconColor

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
          spacing: Style.space(10)

          // ---- not configured / error ----
          Text {
            width: parent.width
            visible: !root.serviceReady || !root.lms.configured
            text: root.serviceReady ? "No Lyrion server configured" : "Service unavailable"
            color: Color.foreground
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
            spacing: Style.space(4)
            visible: root.serviceReady && root.lms.players.length > 0
            Repeater {
              model: root.serviceReady ? root.lms.players : []
              delegate: Rectangle {
                required property var modelData
                width: parent.width
                height: Style.space(32)
                radius: Style.space(6)
                color: modelData.playerid === root.lms.activePlayerId
                  ? (bar ? bar.urgent : Color.accent) : "transparent"
                Row {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(8)
                  anchors.rightMargin: Style.space(8)
                  spacing: Style.space(6)
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.isgroup ? "\u2637" : (modelData.isplaying ? "\u25B6" : "\u25A0")
                    color: Color.foreground
                  }
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.name + (modelData.isgroup ? "  (group)" : "")
                    color: Color.foreground
                  }
                }
                MouseArea {
                  anchors.fill: parent
                  onClicked: root.lms.selectPlayer(modelData.playerid)
                }
              }
            }
          }

          // ---- now playing ----
          Row {
            width: parent.width
            spacing: Style.space(10)
            visible: root.serviceReady && root.lms.configured
            Image {
              width: Style.space(64)
              height: Style.space(64)
              source: root.lms.coverUrl
              fillMode: Image.PreserveAspectFit
              asynchronous: true
            }
            Column {
              width: parent.width - Style.space(74)
              spacing: Style.space(2)
              Text {
                width: parent.width
                text: root.lms.title || "—"
                color: Color.foreground
                elide: Text.ElideRight
                font.bold: true
              }
              Text {
                width: parent.width
                text: root.lms.artist || ""
                color: Color.foreground
                opacity: 0.7
                elide: Text.ElideRight
              }
              Text {
                width: parent.width
                text: root.lms.nowplaying.album || ""
                color: Color.foreground
                opacity: 0.5
                elide: Text.ElideRight
              }
            }
          }

          // ---- transport ----
          Row {
            width: parent.width
            spacing: Style.space(16)
            visible: root.serviceReady && root.lms.configured
            Repeater {
              model: [
                { glyph: "\u23EE", tag: "prev" },
                { glyph: root.lms.playing ? "\u23F8" : "\u25B6", tag: "play" },
                { glyph: "\u23ED", tag: "next" }
              ]
              delegate: Text {
                required property var modelData
                text: modelData.glyph
                color: Color.foreground
                font.pixelSize: Style.space(22)
                MouseArea {
                  anchors.fill: parent
                  anchors.margins: -Style.space(4)
                  onClicked: {
                    if (modelData.tag === "prev") root.lms.previous()
                    else if (modelData.tag === "next") root.lms.next()
                    else root.lms.togglePlay()
                  }
                }
              }
            }
          }

          // ---- volume ----
          Row {
            width: parent.width
            spacing: Style.space(8)
            visible: root.serviceReady && root.lms.configured
            Text { text: "\U0001F50A"; color: Color.foreground }
            Slider {
              id: volume
              width: parent.width - Style.space(40)
              from: 0
              to: 100
              value: root.lms.nowplaying.volume || 0
              onMoved: root.lms.setVolume(value)
            }
          }

          // ---- actions ----
          Row {
            width: parent.width
            spacing: Style.space(16)
            Text {
              text: "Refresh"
              color: Color.foreground
              opacity: 0.8
              MouseArea { anchors.fill: parent; onClicked: root.lms.refresh() }
            }
            Text {
              text: "Settings"
              color: Color.foreground
              opacity: 0.8
              MouseArea { anchors.fill: parent; onClicked: root.openSettings() }
            }
          }
        }
      }
    }
  }
}
