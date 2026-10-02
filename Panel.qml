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
  readonly property string glyphMusic: "󰝚"   // md-music-note (idle state)
  readonly property string glyphGear: "󰒓"    // md-cog
  readonly property string glyphQueue: "󰎆"   // md-playlist-play (queue toggle)
  readonly property string glyphClose: "󰅖"   // md-close (remove from queue)
  readonly property string glyphShuffle: "󰒝"   // md-shuffle (playmode on)
  readonly property string glyphSequence: "󰒞"  // md-shuffle-disabled (playmode off)
  readonly property string glyphClear: "󰗩"     // md-delete-sweep (clear queue)
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
  // Keyboard-driven result selection (arrow keys + Enter); reset on refresh.
  property int selectedIndex: 0
  readonly property var searchHit: serviceReady ? lms.searchResults : null
  readonly property int searchRevision: serviceReady ? lms.searchRevision : 0
  onSearchRevisionChanged: selectedIndex = 0
  // Keep the keyboard-selected result visible in the panel's scroll area.
  onSelectedIndexChanged: {
    if (!opened || !searchMode) return
    var row = resultsRepeater.itemAt(selectedIndex)
    if (!row) return
    var y = row.mapToItem(scroll, 0, 0).y
    if (y < 0) scroll.contentY += y
    else if (y + row.height > scroll.height) scroll.contentY += y + row.height - scroll.height
  }
  readonly property bool searchBusy: searchHit === null && searchText !== ""

  // ---- queue mode ----
  // Body swap, mutually exclusive with search mode. The Service owns the
  // queue projection; Panel just renders it and forwards index-based actions.
  property bool queueMode: false
  // Keyboard-driven queue selection (arrow keys + Enter). The Service
  // re-fetches the queue on playback pushes, so the list changes underneath
  // the cursor often; keep the selection put and just clamp it when the
  // queue shrinks (rather than resetting to the top mid-navigation).
  property int queueIndex: 0
  // Header action cursor: -1 = the list has the cursor, 0 = playmode toggle,
  // 1 = clear-all. Left/Right cycles these while Up/Down walks the list.
  property int queueButtonIndex: -1
  // Clear-all is only cycled to when there's something to clear.
  readonly property int queueButtonCount: root.queue.length > 0 ? 2 : 1
  // Clear-all is destructive, so it goes through a confirm dialog.
  property bool clearConfirmOpen: false

  readonly property var queue: {
    if (!serviceReady) return []
    var q = lms.queue
    return q ? q : []
  }
  readonly property int queueRevision: {
    if (!serviceReady || lms.queueRevision === undefined) return 0
    return lms.queueRevision
  }
  onQueueRevisionChanged: {
    if (queueIndex >= queue.length)
      queueIndex = Math.max(0, queue.length - 1)
  }

  // Playmode: Service exposes `playmode` (0 sequential, 1 shuffle songs,
  // 2 shuffle albums) plus `playmodeRevision`. Any non-zero mode counts as
  // shuffle-on for the toggle; toggling off returns to sequential.
  readonly property int playmode: {
    if (!serviceReady) return 0
    var rev = lms.playmodeRevision
    var v = lms.playmode
    return (v === undefined || v === null) ? 0 : v
  }
  readonly property bool shuffleOn: root.playmode !== 0
  // Passive indicator state for the main panel. typeof-guarded so it stays
  // false if the Service lane hasn't exposed `playmode` yet.
  readonly property bool shuffleIndicatorOn: serviceReady
    && typeof lms.playmode !== "undefined" && Number(lms.playmode) !== 0

  // Height of the normal (non-queue) body below the hero. Captured while the
  // normal view is on screen and frozen once queue/search mode takes over, so
  // the queue list caps itself to the same footprint. Without the freeze the
  // binding would cycle: the list height feeds content.implicitHeight, which
  // would feed the measurement straight back into the list.
  property real normalBodyHeight: 0
  Binding {
    target: root
    property: "normalBodyHeight"
    value: Math.max(0, content.implicitHeight - hero.height - content.spacing)
    when: root.opened && !root.searchMode && !root.queueMode
    restoreMode: Binding.RestoreNone
  }
  // List cap = normal body height minus the queue header/hint, so the whole
  // queue panel stays within the normal panel's footprint; overflow scrolls
  // inside the list.
  readonly property real queueListMaxHeight: {
    var body = root.normalBodyHeight > 0 ? root.normalBodyHeight : Style.space(520)
    var chrome = queueHeader.implicitHeight + queueHint.implicitHeight
      + queueCol.spacing * 2
    return Math.max(Style.space(120), body - chrome)
  }

  function enterQueue() {
    if (!serviceReady || !lms.configured) return
    if (searchMode) exitSearch()
    queueMode = true
    queueIndex = 0
    queueButtonIndex = -1
    buttonIndex = -1
    if (typeof lms.fetchQueue === "function") lms.fetchQueue()
    if (typeof lms.fetchPlaymode === "function") lms.fetchPlaymode()
    Qt.callLater(function() { if (root.queueMode) keyCatcher.forceActiveFocus() })
  }
  function exitQueue() {
    queueMode = false
    queueIndex = 0
    queueButtonIndex = -1
    buttonIndex = -1
    clearConfirmOpen = false
    Qt.callLater(function() { if (!root.queueMode) keyCatcher.forceActiveFocus() })
  }
  function moveQueueSelection(delta) {
    var n = queue.length
    if (n === 0) return
    queueIndex = (queueIndex + delta + n) % n
  }
  function cycleQueueButton(delta) {
    var n = root.queueButtonCount
    if (n === 0) return
    if (root.queueButtonIndex < 0) root.queueButtonIndex = delta > 0 ? 0 : n - 1
    else root.queueButtonIndex = (root.queueButtonIndex + delta + n) % n
  }
  function activateQueueSelection() {
    if (root.queueButtonIndex === 0) { root.togglePlaymode(); return }
    if (root.queueButtonIndex === 1) { root.openClearConfirm(); return }
    if (queue.length === 0) return
    jumpToQueue(queueIndex)
  }
  // Playlist index jump / delete. Wrapped so a divergent Service naming only
  // needs changing here; the typeof guards keep the panel inert until the
  // Service exposes them.
  function jumpToQueue(index) {
    if (serviceReady && typeof lms.queueJump === "function")
      lms.queueJump(index)
  }
  function removeQueueEntry(index) {
    if (serviceReady && typeof lms.queueDelete === "function")
      lms.queueDelete(index)
  }
  function togglePlaymode() {
    if (serviceReady && typeof lms.setPlaymode === "function")
      lms.setPlaymode(root.shuffleOn ? 0 : 1)
  }
  function openClearConfirm() {
    if (queue.length === 0) return
    queueButtonIndex = -1
    clearConfirmOpen = true
    Qt.callLater(function() { if (root.clearConfirmOpen) confirmLayer.forceActiveFocus() })
  }
  function closeClearConfirm() {
    clearConfirmOpen = false
    Qt.callLater(function() { if (root.queueMode) keyCatcher.forceActiveFocus() })
  }
  function confirmClearQueue() {
    clearConfirmOpen = false
    if (serviceReady && typeof lms.clearQueue === "function") lms.clearQueue()
    Qt.callLater(function() { if (root.queueMode) keyCatcher.forceActiveFocus() })
  }

  // ---- keyboard button selection (main view) ----
  // -1 = nothing selected. Arrows cycle the panel's actionable buttons in
  // visual order (hero search/queue/settings, then transport prev/play/next);
  // Enter activates the selection, or toggles play/pause when none is set.
  property int buttonIndex: -1
  readonly property bool transportVisible: !searchMode && !queueMode && serviceReady
    && lms.configured && lms.players.length > 0
  readonly property int buttonCount: 3 + (transportVisible ? 3 : 0)
  function cycleButton(delta) {
    var n = buttonCount
    if (n === 0) return
    if (buttonIndex < 0) buttonIndex = delta > 0 ? 0 : n - 1
    else buttonIndex = (buttonIndex + delta + n) % n
  }
  function activateButton() {
    if (buttonIndex < 0) {
      if (controlsActive) lms.togglePlay()
      return
    }
    if (buttonIndex === 0) { searchMode ? exitSearch() : enterSearch(); return }
    if (buttonIndex === 1) { queueMode ? exitQueue() : enterQueue(); return }
    if (buttonIndex === 2) { openSettings(); return }
    if (buttonIndex === 3) { if (controlsActive) lms.previous(); return }
    if (buttonIndex === 4) { if (controlsActive) lms.togglePlay(); return }
    if (buttonIndex === 5) { if (controlsActive) lms.next(); return }
  }

  function enterSearch() {
    if (!serviceReady || !lms.configured) return
    if (queueMode) exitQueue()
    searchMode = true
    buttonIndex = -1
    Qt.callLater(function() { if (root.searchMode) searchField.forceActiveFocus() })
  }
  function exitSearch() {
    searchMode = false
    searchText = ""
    buttonIndex = -1
    if (serviceReady) lms.search("")
    // Hand focus back to the key catcher: the hidden field must not keep
    // active focus, or every later keypress (including "/") goes nowhere.
    Qt.callLater(function() { if (!root.searchMode) keyCatcher.forceActiveFocus() })
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

  onOpenedChanged: {
    if (opened && root.serviceReady) root.lms.refresh()
    // Leaving the panel resets any in-progress search so a fresh open
    // starts on the now-playing view, not a stale query.
    if (!opened) {
      root.buttonIndex = -1
      root.clearConfirmOpen = false
      if (root.searchMode) root.exitSearch()
      if (root.queueMode) root.exitQueue()
    }
  }

  // Bar chrome: icon always; when the panel is closed and something is
  // playing, a marquee of "title · artist" scrolls next to it.
  readonly property bool showBarLabel: !opened && serviceReady && lms.playing
    && (lms.title !== "" || lms.artist !== "") && !(bar && bar.vertical)
  property real maxLabelWidth: 200

  implicitWidth: barRow.implicitWidth
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

  Row {
    id: barRow
    anchors.centerIn: parent
    spacing: Style.space(6)

    BarIconButton {
      id: button
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

    Item {
      id: scrollClip
      width: root.showBarLabel ? Math.min(root.maxLabelWidth, labelText.implicitWidth) : 0
      height: button.implicitHeight
      clip: true
      visible: root.showBarLabel
      anchors.verticalCenter: parent.verticalCenter

      // Restart the marquee whenever the label text, its width, or the
      // clip geometry/visibility changes. A declarative `running` binding
      // left x parked at a stale negative offset when the text changed
      // mid-flight (or when the panel opened/closed), so the label froze
      // off-screen or stopped scrolling. Stop, reset to the resting
      // position, then (re)start only when the text actually overflows.
      function restartMarquee() {
        marquee.stop()
        labelText.x = 0
        if (labelText.needsScroll && !root.opened && !(root.bar && root.bar.vertical))
          marquee.restart()
      }
      onWidthChanged: restartMarquee()
      onVisibleChanged: restartMarquee()

      Text {
        id: labelText
        x: 0
        textFormat: Text.PlainText
        text: (root.lms ? (root.lms.title || "") : "")
          + (root.lms && root.lms.artist ? "  ·  " + root.lms.artist : "")
        color: root.barIconColor
        font.family: root.family
        font.pixelSize: Style.font.body
        anchors.verticalCenter: parent.verticalCenter

        property bool needsScroll: implicitWidth > scrollClip.width
        onImplicitWidthChanged: scrollClip.restartMarquee()
        onTextChanged: scrollClip.restartMarquee()
      }

      NumberAnimation {
        id: marquee
        target: labelText
        property: "x"
        running: false
        loops: Animation.Infinite
        duration: Math.max(6000, labelText.implicitWidth * 25)
        from: scrollClip.width
        to: -labelText.implicitWidth
        easing.type: Easing.Linear
        onStopped: labelText.x = 0
      }
    }
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
      // The clear-all confirmation owns the keyboard while it's up.
      blocked: root.clearConfirmOpen
      // Main view: arrows cycle the actionable buttons; Enter activates the
      // selection (or toggles play/pause when none is set). Search mode keeps
      // arrows/Enter for its own result list via the field's handlers; queue
      // mode routes Up/Down to the list and Left/Right to the header actions.
      onMoveRequested: function(dx, dy) {
        if (root.searchMode) return
        if (root.queueMode) {
          if (dx !== 0) { root.cycleQueueButton(dx); return }
          root.queueButtonIndex = -1
          root.moveQueueSelection(dy)
          return
        }
        root.cycleButton(dx !== 0 ? dx : dy)
      }
      onActivateRequested: {
        if (root.queueMode) root.activateQueueSelection()
        else if (!root.searchMode) root.activateButton()
      }
      // Tab always escapes to the neighbouring panel, search mode included.
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onCloseRequested: {
        if (root.searchMode) root.exitSearch()
        else if (root.queueMode) root.exitQueue()
        else root.close()
      }
      onTextKey: function(key) {
        if (String(key) === "/") root.enterSearch()
        else if (String(key).toLowerCase() === "s") root.openSettings()
      }

      Flickable {
        id: scroll
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
            id: hero
            width: parent.width
            title: "OmaLMS"
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
                  hasCursor: root.buttonIndex === 0
                  hoverColor: root.buttonIndex === 0
                    ? Color.accent : Qt.darker(root.fg, 1.4)
                  onClicked: {
                    root.buttonIndex = -1
                    root.searchMode ? root.exitSearch() : root.enterSearch()
                  }
                }
                PanelActionButton {
                  iconText: root.glyphQueue
                  fontFamily: root.family
                  tooltipText: "Queue"
                  foreground: root.queueMode ? Color.accent : Qt.darker(root.fg, 1.4)
                  hasCursor: root.buttonIndex === 1
                  hoverColor: root.buttonIndex === 1
                    ? Color.accent : Qt.darker(root.fg, 1.4)
                  onClicked: {
                    root.buttonIndex = -1
                    root.queueMode ? root.exitQueue() : root.enterQueue()
                  }
                }
                PanelActionButton {
                  iconText: root.glyphGear
                  fontFamily: root.family
                  tooltipText: "Settings"
                  foreground: Qt.darker(root.fg, 1.4)
                  hasCursor: root.buttonIndex === 2
                  hoverColor: root.buttonIndex === 2
                    ? Color.accent : Qt.darker(root.fg, 1.4)
                  onClicked: {
                    root.buttonIndex = -1
                    root.openSettings()
                  }
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
              // Enter plays the selected result; with nothing selected yet it
              // forces the search (covers the no-results-yet case).
              onAccepted: searchCol.playSelectedOrSearch()
              Keys.onDownPressed: searchCol.moveSelection(1)
              Keys.onUpPressed: searchCol.moveSelection(-1)
              Keys.onEscapePressed: root.exitSearch()
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                  event.accepted = true
                  root.switchPanel(event.key === Qt.Key_Backtab ? -1 : 1)
                  return
                }
                if (event.key === Qt.Key_Slash && !event.text) return
                if (event.key === Qt.Key_Slash) {
                  event.accepted = true
                  root.exitSearch()
                }
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
            // Flat, display-ordered result list (albums, then artists, then
            // playlists) so arrow-key selection is a single index over one model.
            readonly property var flatResults: {
              if (!hits) return []
              var out = []
              var albums = hits.albums || [], artists = hits.artists || [],
                  playlists = hits.playlists || []
              for (var i = 0; i < albums.length; i++)
                out.push({ kind: "album", id: albums[i].id, name: albums[i].name,
                           artist: albums[i].artist, year: albums[i].year,
                           coverId: albums[i].coverId })
              for (var j = 0; j < artists.length; j++)
                out.push({ kind: "artist", id: artists[j].id, name: artists[j].name })
              for (var k = 0; k < playlists.length; k++)
                out.push({ kind: "playlist", id: playlists[k].id, name: playlists[k].name })
              return out
            }
            readonly property bool anyHits: flatResults.length > 0

            function moveSelection(delta) {
              var n = flatResults.length
              if (n === 0) return
              root.selectedIndex = (root.selectedIndex + delta + n) % n
            }
            function playSelectedOrSearch() {
              if (flatResults.length === 0) {
                searchDebounce.stop()
                root.runSearch(root.searchText)
                return
              }
              var hit = flatResults[root.selectedIndex]
              root.playSelection(hit.kind, hit.id)
            }

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
              text: "\u2191\u2193 select \u00B7 Enter plays now \u00B7 + adds to queue"
              color: root.dim
              opacity: 0.7
              font.pixelSize: Style.font.caption
            }

            Repeater {
              id: resultsRepeater
              model: searchCol.flatResults

              Rectangle {
                id: resultRow
                required property var modelData
                required property int index
                width: searchCol.width
                height: resultInner.implicitHeight + Style.space(12)
                radius: Style.cornerRadius
                color: resultRow.index === root.selectedIndex
                  ? root.selectedFill : "transparent"

                // Row click plays directly; declared first so the play/add
                // buttons on top keep their own clicks.
                MouseArea {
                  anchors.fill: parent
                  onClicked: {
                    root.selectedIndex = resultRow.index
                    root.playSelection(resultRow.modelData.kind, resultRow.modelData.id)
                  }
                }

                Row {
                  id: resultInner
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(6)
                  anchors.rightMargin: Style.space(6)
                  spacing: Style.spacing.sm

                  Rectangle {
                    width: Style.space(36)
                    height: Style.space(36)
                    radius: Style.cornerRadius
                    color: "black"
                    clip: true
                    visible: resultRow.modelData.kind === "album"
                    Image {
                      anchors.fill: parent
                      source: root.lms.coverBase !== "" && resultRow.modelData.coverId
                        ? root.lms.coverBase + "/cover/" + resultRow.modelData.coverId + ".jpg" : ""
                      fillMode: Image.PreserveAspectCrop
                      asynchronous: true
                      visible: status === Image.Ready
                    }
                    Text {
                      anchors.centerIn: parent
                      visible: resultRow.modelData.coverId === ""
                      text: root.glyphNote
                      color: root.dim
                      font.family: root.family
                      font.pixelSize: Style.space(18)
                    }
                  }
                  Text {
                    width: Style.space(36)
                    height: Style.space(36)
                    verticalAlignment: Text.AlignVCenter
                    horizontalAlignment: Text.AlignHCenter
                    visible: resultRow.modelData.kind === "artist"
                    text: root.glyphNote
                    color: root.dim
                    font.family: root.family
                    font.pixelSize: Style.space(18)
                  }
                  Text {
                    width: Style.space(36)
                    height: Style.space(36)
                    verticalAlignment: Text.AlignVCenter
                    horizontalAlignment: Text.AlignHCenter
                    visible: resultRow.modelData.kind === "playlist"
                    text: "󰎆"    // md-playlist-play
                    color: root.dim
                    font.family: root.family
                    font.pixelSize: Style.space(18)
                  }

                  Column {
                    width: parent.width - Style.space(36 + 84)
                    spacing: 0
                    Text {
                      width: parent.width
                      text: resultRow.modelData.name || "\u2014"
                      color: root.fg
                      font.bold: resultRow.modelData.kind === "album"
                      font.pixelSize: Style.font.body
                      elide: Text.ElideRight
                    }
                    Text {
                      width: parent.width
                      visible: resultRow.modelData.kind === "album"
                      text: (resultRow.modelData.artist || "") + (resultRow.modelData.year ? " \u00B7 " + resultRow.modelData.year : "")
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
                    onClicked: root.playSelection(resultRow.modelData.kind, resultRow.modelData.id)
                  }
                  PanelActionButton {
                    visible: resultRow.modelData.kind === "album"
                    iconText: "󰐕"    // md-plus
                    size: Style.space(30)
                    fontFamily: root.family
                    foreground: root.fg
                    color: "transparent"
                    tooltipText: "Add to queue"
                    onClicked: root.enqueueSelection(resultRow.modelData.kind, resultRow.modelData.id)
                  }
                }
              }
            }
          }

          // ---- queue mode ----
          // Body swap mirroring search: a flat list of queue entries. Click
          // jumps to the track (playlist index jump); the per-row ✕ removes it.
          // The currently playing entry is accent-highlighted independently of
          // the keyboard cursor fill. The list is capped to the normal panel
          // body height and scrolls internally, with the header carrying the
          // playmode toggle and the (confirmed) clear-all.
          Column {
            id: queueCol
            width: parent.width
            spacing: Style.spacing.sm
            visible: root.serviceReady && root.queueMode

            Item {
              id: queueHeader
              width: parent.width
              implicitHeight: Math.max(queueHeaderLabel.implicitHeight, Style.space(30))

              PanelSectionHeader {
                id: queueHeaderLabel
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "Queue" + (root.queue.length > 0
                  ? " \u00B7 " + root.queue.length
                    + (root.queue.length === 1 ? " track" : " tracks")
                  : "")
                color: root.fg
              }

              Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.spacing.xs

                // Sequential / shuffle. Any shuffle mode is accent-filled so
                // the current mode reads at a glance.
                PanelActionButton {
                  id: playmodeButton
                  iconText: root.shuffleOn ? root.glyphShuffle : root.glyphSequence
                  fontFamily: root.family
                  tooltipText: root.playmode === 2 ? "Shuffle albums"
                    : (root.playmode === 1 ? "Shuffle songs" : "Play in order")
                  foreground: root.shuffleOn
                    ? Color.accent : Qt.darker(root.fg, 1.4)
                  hasCursor: root.queueMode && root.queueButtonIndex === 0
                  hoverColor: root.queueButtonIndex === 0
                    ? Color.accent : Qt.darker(root.fg, 1.4)
                  onClicked: {
                    root.queueButtonIndex = -1
                    root.togglePlaymode()
                  }
                }

                // Clear-all: destructive, so it keeps the urgent tint and is
                // tucked in the header rather than beside the per-row ✕
                // buttons. Disabled when there is nothing to clear.
                PanelActionButton {
                  id: clearButton
                  iconText: root.glyphClear
                  fontFamily: root.family
                  tooltipText: "Clear queue"
                  enabled: root.queue.length > 0
                  foreground: root.queue.length > 0
                    ? (root.bar ? root.bar.urgent : Color.urgent)
                    : Qt.darker(root.fg, 2.0)
                  hasCursor: root.queueMode && root.queueButtonIndex === 1
                  hoverColor: root.bar ? root.bar.urgent : Color.urgent
                  onClicked: {
                    root.queueButtonIndex = -1
                    root.openClearConfirm()
                  }
                }
              }
            }

            Text {
              id: queueHint
              width: parent.width
              visible: root.queue.length > 0
              text: "\u2191\u2193 select \u00B7 Enter plays \u00B7 \u2190\u2192 actions \u00B7 \u2715 removes"
              color: root.dim
              opacity: 0.7
              font.pixelSize: Style.font.caption
            }

            Text {
              width: parent.width
              visible: root.queue.length === 0
              text: "Queue is empty"
              color: root.dim
              font.pixelSize: Style.font.body
            }

            // Capped to the normal body height; the ScrollBar appears only
            // when there are more rows than fit. positionViewAtIndex keeps the
            // keyboard-selected row in view as Up/Down walk past the window.
            ListView {
              id: queueList
              width: parent.width
              height: Math.min(contentHeight, root.queueListMaxHeight)
              visible: root.queue.length > 0
              spacing: Style.spacing.xs
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              interactive: contentHeight > height
              model: root.queue
              currentIndex: root.queueIndex
              onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)
              ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

              delegate: Rectangle {
                id: queueRow
                required property var modelData
                required property int index
                width: queueList.width
                height: queueInner.implicitHeight + Style.space(12)
                radius: Style.cornerRadius
                color: queueRow.index === root.queueIndex
                  ? root.selectedFill
                  : (queueRow.modelData.current
                    ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06)
                    : "transparent")

                // Row click jumps to the track directly; declared first so the
                // remove button on top keeps its own click.
                MouseArea {
                  anchors.fill: parent
                  onClicked: {
                    root.queueButtonIndex = -1
                    root.queueIndex = queueRow.index
                    root.jumpToQueue(queueRow.index)
                  }
                }

                Row {
                  id: queueInner
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(6)
                  // Leave room for the scrollbar when it's showing so the
                  // per-row ✕ never sits under it.
                  anchors.rightMargin: queueList.contentHeight > queueList.height
                    ? Style.space(14) : Style.space(6)
                  spacing: Style.spacing.sm

                  Text {
                    width: Style.space(36)
                    height: Style.space(36)
                    verticalAlignment: Text.AlignVCenter
                    horizontalAlignment: Text.AlignHCenter
                    text: queueRow.modelData.current ? root.glyphPlay : root.glyphNote
                    color: queueRow.modelData.current ? Color.accent : root.dim
                    font.family: root.family
                    font.pixelSize: Style.space(18)
                  }

                  Column {
                    width: parent.width - Style.space(36 + 44)
                    spacing: 0
                    Text {
                      width: parent.width
                      text: queueRow.modelData.title || "\u2014"
                      color: queueRow.modelData.current ? Color.accent : root.fg
                      font.bold: queueRow.modelData.current
                      font.pixelSize: Style.font.body
                      elide: Text.ElideRight
                    }
                    Text {
                      width: parent.width
                      visible: (queueRow.modelData.artist || "") !== ""
                      text: queueRow.modelData.artist || ""
                      color: root.dim
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }

                  PanelActionButton {
                    iconText: root.glyphClose
                    size: Style.space(30)
                    fontFamily: root.family
                    foreground: root.fg
                    color: "transparent"
                    hoverColor: root.bar ? root.bar.urgent : Color.urgent
                    tooltipText: "Remove from queue"
                    onClicked: root.removeQueueEntry(queueRow.index)
                  }
                }
              }
            }
          }

          // ---- not configured / error ----
          Text {
            width: parent.width
            visible: !root.searchMode && !root.queueMode && (!root.serviceReady || !root.lms.configured)
            text: root.serviceReady ? "No Lyrion server configured" : "Service unavailable"
            color: root.fg
            wrapMode: Text.WordWrap
          }
          Text {
            width: parent.width
            visible: !root.searchMode && !root.queueMode && root.phase === "error" && root.lms && root.lms.lastError !== ""
            text: root.lms ? root.lms.lastError : ""
            color: bar ? bar.urgent : Color.urgent
            wrapMode: Text.WordWrap
          }

          // ---- player picker ----
          Column {
            width: parent.width
            spacing: Style.spacing.sm
            visible: !root.searchMode && !root.queueMode && root.serviceReady && root.lms.players.length > 0
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
            visible: !root.searchMode && !root.queueMode && root.serviceReady && root.lms.configured
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
            visible: !root.searchMode && !root.queueMode && root.serviceReady && root.lms.configured
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
            visible: !root.searchMode && !root.queueMode && root.serviceReady && root.lms.configured
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
            visible: !root.searchMode && !root.queueMode && root.serviceReady && root.lms.configured
            // Title row reserves a slot on the right for the passive shuffle
            // indicator, so showing/hiding it never shifts the title. The
            // glyph is hover-only: no click, not part of the button cycle.
            Item {
              id: titleRow
              width: parent.width
              height: titleText.implicitHeight

              Text {
                id: titleText
                width: parent.width - shuffleMark.width
                text: root.lms.title || "—"
                color: root.fg
                elide: Text.ElideRight
                font.bold: true
                font.pixelSize: Style.font.body
              }

              Item {
                id: shuffleMark
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                // Glyph plus a small gap so elided titles don't butt up
                // against the indicator.
                width: shuffleGlyph.implicitWidth + Style.space(6)
                height: shuffleGlyph.implicitHeight

                Text {
                  id: shuffleGlyph
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.glyphShuffle
                  color: root.dim
                  opacity: root.shuffleIndicatorOn ? 1 : 0
                  font.family: root.family
                  font.pixelSize: Style.font.caption
                }

                HoverHandler {
                  id: shuffleHover
                  enabled: root.shuffleIndicatorOn
                }

                PanelToolTip {
                  visible: shuffleHover.hovered && root.shuffleIndicatorOn
                  text: "Shuffle on"
                  fontFamily: root.family
                }
              }
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
            visible: !root.searchMode && !root.queueMode && root.serviceReady && root.lms.configured && root.lms.players.length > 0
            PanelActionButton {
              iconText: root.glyphPrev            // previous
              size: Style.space(40)
              bordered: true
              fontFamily: root.family
              foreground: root.fg
              color: "transparent"
              enabled: root.controlsActive
              hasCursor: root.buttonIndex === 3
              hoverColor: root.buttonIndex === 3 ? Color.accent : root.fg
              onClicked: {
                root.buttonIndex = -1
                root.lms.previous()
              }
            }
            PanelActionButton {
              iconText: root.lms.playing ? root.glyphPause : root.glyphPlay
              size: Style.space(40)
              bordered: true
              fontFamily: root.family
              foreground: root.fg
              color: "transparent"
              enabled: root.controlsActive
              hasCursor: root.buttonIndex === 4
              hoverColor: root.buttonIndex === 4 ? Color.accent : root.fg
              onClicked: {
                root.buttonIndex = -1
                root.lms.togglePlay()
              }
            }
            PanelActionButton {
              iconText: root.glyphNext            // next
              size: Style.space(40)
              bordered: true
              fontFamily: root.family
              foreground: root.fg
              color: "transparent"
              enabled: root.controlsActive
              hasCursor: root.buttonIndex === 5
              hoverColor: root.buttonIndex === 5 ? Color.accent : root.fg
              onClicked: {
                root.buttonIndex = -1
                root.lms.next()
              }
            }
          }
        }
      }

      // Clear-all confirmation. Sits above the whole body; the key catcher is
      // blocked while it's up, so this layer owns Escape / Left-Right / Enter.
      Item {
        id: confirmLayer
        anchors.fill: parent
        z: 50
        visible: root.clearConfirmOpen
        focus: root.clearConfirmOpen
        Keys.onPressed: function(event) {
          if (clearConfirm.handleKey(event)) event.accepted = true
        }

        ConfirmDialog {
          id: clearConfirm
          anchors.fill: parent
          opened: root.clearConfirmOpen
          message: "Clear the entire queue? This removes every track."
          cancelText: "Cancel"
          confirmText: "Clear"
          // Default to Cancel so a stray Enter can't wipe the queue.
          selectedIndex: 0
          background: Color.popups.background
          foreground: root.fg
          fontFamily: root.family
          onCanceled: root.closeClearConfirm()
          onConfirmed: root.confirmClearQueue()
        }
      }
    }
  }
}