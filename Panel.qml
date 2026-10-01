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
  // Optimistic volume: what the slider shows while the server catches up.
  // Holds the commanded value from release until a pushed state confirms it,
  // so lagging pushes can't drag the knob back through intermediates.
  property real volumeShown: -1
  onRevisionChanged: {
    elapsed = serviceReady ? (lms.nowplaying.time || 0) : 0
    if (serviceReady && volumeShown >= 0
        && (lms.nowplaying.volume || 0) === Math.round(volumeShown))
      volumeShown = -1
  }
  readonly property real volumeDisplay: volumeShown >= 0
    ? volumeShown : (serviceReady ? (lms.nowplaying.volume || 0) : 0)

  function mmss(sec) {
    sec = Math.max(0, Math.round(sec || 0))
    var s = sec % 60
    return Math.floor(sec / 60) + ":" + (s < 10 ? "0" : "") + s
  }

  // ---- search mode ----
  property bool searchMode: false
  property string searchText: ""
  readonly property var searchHit: serviceReady ? lms.searchResults : null
  readonly property int searchRevision: serviceReady ? lms.searchRevision : 0
  readonly property bool searchBusy: searchHit === null && searchText !== ""

  function enterSearch() {
    if (!serviceReady || !lms.configured) return
    searchMode = true
    Qt.callLater(function() { if (root.searchMode) searchField.forceActiveFocus() })
  }
  function exitSearch() {
    searchMode = false
    searchText = ""
    if (serviceReady) lms.search("")
  }
  function runSearch(q) {
    if (serviceReady) lms.search(q)
  }
  // Play now: load the selection into the queue and start; then leave search
  // mode so the panel shows the now-playing card that just started.
  function playSelection(kind, id) {
    if (!serviceReady) return
    lms.sendCmd(["playlistcontrol", "cmd:load", kind + "_id:" + id], "search")
    lms.sendCmd(["mode", "play"], "search")
    exitSearch()
  }
  function enqueueSelection(kind, id) {
    if (serviceReady) lms.sendCmd(["playlistcontrol", "cmd:add", kind + "_id:" + id], "search")
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
      onCloseRequested: {
        if (root.searchMode) root.exitSearch()
        else root.close()
      }
      onTextKey: function(key) {
        if (String(key) === "/") root.enterSearch()
        else if (String(key).toLowerCase() === "s") root.openSettings()
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
                  iconText: "󰍉"    // md-magnify 
                  fontFamily: root.family
                  tooltipText: "Search (/)"
                  foreground: root.searchMode ? Color.accent : Qt.darker(root.fg, 1.4)
                  onClicked: root.searchMode ? root.exitSearch() : root.enterSearch()
                }
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

          // ---- search mode ----
          Column {
            id: searchCol
            width: parent.width
            spacing: Style.spacing.sm
            visible: root.serviceReady && root.searchMode

            TextField {
              id: searchField
              width: parent.width
              placeholderText: "Search albums, artists, playlists"
              color: root.fg
              font.family: root.family
              font.pixelSize: Style.font.body
              onTextChanged: {
                root.searchText = text
                searchDebounce.restart()
              }
              onAccepted: {
                searchDebounce.stop()
                root.runSearch(text)
              }
            }
            Timer {
              id: searchDebounce
              interval: 250
              onTriggered: root.runSearch(root.searchText)
            }

            // Results echo the query; ignore stale responses.
            readonly property var hits: root.searchHit && root.searchHit.q === root.searchText
              ? root.searchHit : null
            readonly property bool anyHits: hits && (hits.albums.length > 0
              || hits.artists.length > 0 || hits.playlists.length > 0)

            Text {
              width: parent.width
              visible: root.searchText !== "" && !searchCol.anyHits
              text: "No matches"
              color: root.dim
              font.pixelSize: Style.font.body
            }
            Text {
              width: parent.width
              visible: searchCol.anyHits
              text: "Enter plays now · + adds to queue"
              color: root.dim
              opacity: 0.7
              font.pixelSize: Style.font.caption
            }

            Repeater {
              model: searchCol.hits ? searchCol.hits.albums : []

              Row {
                id: albumRow
                required property var modelData
                width: parent.width
                spacing: Style.spacing.sm

                Rectangle {
                  width: Style.space(36)
                  height: Style.space(36)
                  radius: Style.cornerRadius
                  color: "black"
                  clip: true
                  Image {
                    anchors.fill: parent
                    source: root.lms.coverBase !== "" && albumRow.modelData.coverId
                      ? root.lms.coverBase + "/cover/" + albumRow.modelData.coverId + ".jpg" : ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    visible: status === Image.Ready
                  }
                  Text {
                    anchors.centerIn: parent
                    visible: albumRow.modelData.coverId === ""
                    text: root.glyphNote
                    color: root.dim
                    font.family: root.family
                    font.pixelSize: Style.space(18)
                  }
                }
                Column {
                  width: parent.width - Style.space(36 + 84)
                  spacing: 0
                  Text {
                    width: parent.width
                    text: albumRow.modelData.name || "—"
                    color: root.fg
                    font.bold: true
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }
                  Text {
                    width: parent.width
                    text: (albumRow.modelData.artist || "") + (albumRow.modelData.year ? " \u00B7 " + albumRow.modelData.year : "")
                    color: root.dim
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }
                PanelActionButton {
                  iconText: root.glyphPlay
                  size: Style.space(30)
                  fontFamily: root.family
                  foreground: root.fg
                  color: "transparent"
                  tooltipText: "Play now"
                  onClicked: root.playSelection("album", albumRow.modelData.id)
                }
                PanelActionButton {
                  iconText: "󰐕"    // md-plus
                  size: Style.space(30)
                  fontFamily: root.family
                  foreground: root.fg
                  color: "transparent"
                  tooltipText: "Add to queue"
                  onClicked: root.enqueueSelection("album", albumRow.modelData.id)
                }
              }
            }

            Repeater {
              model: searchCol.hits ? searchCol.hits.artists : []

              Row {
                id: artistRow
                required property var modelData
                width: parent.width
                spacing: Style.spacing.sm

                Text {
                  width: Style.space(36)
                  verticalAlignment: Text.AlignVCenter
                  text: root.glyphNote
                  color: root.dim
                  font.family: root.family
                  font.pixelSize: Style.space(18)
                }
                Text {
                  width: parent.width - Style.space(36 + 84)
                  verticalAlignment: Text.AlignVCenter
                  text: artistRow.modelData.name || "—"
                  color: root.fg
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }
                PanelActionButton {
                  iconText: root.glyphPlay
                  size: Style.space(30)
                  fontFamily: root.family
                  foreground: root.fg
                  color: "transparent"
                  tooltipText: "Play now"
                  onClicked: root.playSelection("artist", artistRow.modelData.id)
                }
              }
            }

            Repeater {
              model: searchCol.hits ? searchCol.hits.playlists : []

              Row {
                id: playlistRow
                required property var modelData
                width: parent.width
                spacing: Style.spacing.sm

                Text {
                  width: Style.space(36)
                  verticalAlignment: Text.AlignVCenter
                  text: "󰎆"    // md-playlist-play
                  color: root.dim
                  font.family: root.family
                  font.pixelSize: Style.space(18)
                }
                Text {
                  width: parent.width - Style.space(36 + 84)
                  verticalAlignment: Text.AlignVCenter
                  text: playlistRow.modelData.name || "—"
                  color: root.fg
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }
                PanelActionButton {
                  iconText: root.glyphPlay
                  size: Style.space(30)
                  fontFamily: root.family
                  foreground: root.fg
                  color: "transparent"
                  tooltipText: "Play now"
                  onClicked: root.playSelection("playlist", playlistRow.modelData.id)
                }
              }
            }
          }

          // ---- not configured / error ----
          Text {
            width: parent.width
            visible: !root.searchMode && (!root.serviceReady || !root.lms.configured)
            text: root.serviceReady ? "No Lyrion server configured" : "Service unavailable"
            color: root.fg
            wrapMode: Text.WordWrap
          }
          Text {
            width: parent.width
            visible: !root.searchMode && root.phase === "error" && root.lms && root.lms.lastError !== ""
            text: root.lms ? root.lms.lastError : ""
            color: bar ? bar.urgent : Color.urgent
            wrapMode: Text.WordWrap
          }

          // ---- player picker ----
          Column {
            width: parent.width
            spacing: Style.spacing.sm
            visible: !root.searchMode && root.serviceReady && root.lms.players.length > 0
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
            visible: !root.searchMode && root.serviceReady && root.lms.configured
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
              value: root.volumeDisplay
              minimum: 0
              maximum: 100
              integer: true
              onReleased: function(v) {
                root.volumeShown = v
                root.lms.setVolume(v)
              }
            }
          }

          // ---- album art ----
          Rectangle {
            width: parent.width
            height: width
            radius: Style.cornerRadius
            color: "black"
            clip: true
            visible: !root.searchMode && root.serviceReady && root.lms.configured
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
              visible: root.lms.coverUrl === ""
            }
          }

          // ---- progress ----
          Row {
            width: parent.width
            spacing: Style.spacing.sm
            visible: !root.searchMode && root.serviceReady && root.lms.configured
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
            visible: !root.searchMode && root.serviceReady && root.lms.configured
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
            visible: !root.searchMode && root.serviceReady && root.lms.configured && root.lms.players.length > 0
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