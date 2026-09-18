import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

// Connection settings for the Lyrion Music plugin.
//
// Summoned by the shell: omarchy-shell shell summon io.github.powerk1977.lms
// The bar widget owns the IPC target, so the overlay talks to the service
// through the injected `service` property instead of its own IpcHandler.
Item {
  id: root

  // Injected by the shell's panel loader.
  property var shell: null
  property var manifest: null
  property var service: null

  property bool opened: false
  property string tab: "connection"

  property string hostDraft: ""
  property int portDraft: 9000
  property string userDraft: ""
  property string passwordDraft: ""
  property bool demoDraft: false

  readonly property string family: Style.font.family
  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property var borderSpec: Border.surfaceSpec(
    "menu", "border", Color.menu.border, Math.max(1, Style.space(2)))

  readonly property bool canForget: root.service && root.service.origin !== ""
    && !root.service.demoMode

  function open(payloadJson) {
    root.opened = true
    root.tab = "connection"
    root.resetDrafts()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function") {
      root.shell.hide((root.manifest && root.manifest.id) || "io.github.powerk1977.lms")
    }
  }

  function resetDrafts() {
    if (!root.service) return
    root.hostDraft = root.service.host
    root.portDraft = root.service.port
    root.demoDraft = root.service.demoMode
    // Stored credentials never come back to screen; blank means "keep".
    root.userDraft = ""
    root.passwordDraft = ""
  }

  function applyConnection() {
    if (!root.service) return
    root.service.applyConnection(root.hostDraft.trim(), root.portDraft,
                                 root.userDraft, root.passwordDraft, root.demoDraft)
    root.userDraft = ""
    root.passwordDraft = ""
  }

  function forgetCredential() {
    if (root.service) root.service.forgetCredential()
  }

  function useServer(item) {
    root.hostDraft = item.host
    root.portDraft = item.port || 9000
  }

  PanelWindow {
    id: window
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "lms-settings"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: Color.menu.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      anchors.centerIn: parent
      width: Math.min(Style.space(560), window.width - Style.gapsOut * 2)
      height: Math.min(Style.space(560), window.height - Style.gapsOut * 2)
      radius: Style.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding

      MouseArea { anchors.fill: parent }

      PanelKeyCatcher {
        id: keyCatcher
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        anchors.rightMargin: card.contentRightInset
        onCloseRequested: root.dismiss()

        Flickable {
          anchors.fill: parent
          contentHeight: column.implicitHeight
          clip: true

          Column {
            id: column
            width: parent.width
            spacing: Style.spacing.lg

            PanelSectionHeader {
              text: "Lyrion Music Server"
              fontSize: Style.font.subtitle
              color: root.foreground
            }

            // ---- server fields ----
            Column {
              width: parent.width
              spacing: Style.spacing.md

              Row {
                width: parent.width
                spacing: Style.spacing.md
                Text {
                  width: Style.space(90)
                  verticalAlignment: Text.AlignVCenter
                  text: "Host"
                  color: root.foreground
                  opacity: 0.8
                  font.family: root.family
                  font.pixelSize: Style.font.body
                }
                TextField {
                  width: parent.width - Style.space(90)
                  text: root.hostDraft
                  onTextChanged: root.hostDraft = text
                  placeholderText: "192.168.1.50"
                }
              }

              Row {
                width: parent.width
                spacing: Style.spacing.md
                Text {
                  width: Style.space(90)
                  verticalAlignment: Text.AlignVCenter
                  text: "Port"
                  color: root.foreground
                  opacity: 0.8
                  font.family: root.family
                  font.pixelSize: Style.font.body
                }
                NumberField {
                  width: parent.width - Style.space(90)
                  label: ""
                  value: root.portDraft
                  from: 1
                  to: 65535
                  onModified: function(v) { root.portDraft = v }
                }
              }

              Row {
                width: parent.width
                spacing: Style.spacing.md
                Text {
                  width: Style.space(90)
                  verticalAlignment: Text.AlignVCenter
                  text: "Username"
                  color: root.foreground
                  opacity: 0.8
                  font.family: root.family
                  font.pixelSize: Style.font.body
                }
                TextField {
                  width: parent.width - Style.space(90)
                  text: root.userDraft
                  onTextChanged: root.userDraft = text
                  placeholderText: "optional"
                }
              }

              Row {
                width: parent.width
                spacing: Style.spacing.md
                Text {
                  width: Style.space(90)
                  verticalAlignment: Text.AlignVCenter
                  text: "Password"
                  color: root.foreground
                  opacity: 0.8
                  font.family: root.family
                  font.pixelSize: Style.font.body
                }
                TextField {
                  width: parent.width - Style.space(90)
                  text: root.passwordDraft
                  onTextChanged: root.passwordDraft = text
                  password: true
                  placeholderText: "keyring-only"
                }
              }

              Toggle {
                label: "Demo mode"
                checked: root.demoDraft
                onClicked: root.demoDraft = !root.demoDraft
              }
            }

            // ---- actions ----
            Row {
              spacing: Style.spacing.md
              Button {
                bordered: true
                text: "Connect"
                onClicked: root.applyConnection()
              }
              Button {
                bordered: true
                text: "Discover"
                onClicked: function() { if (root.service) root.service.discover() }
              }
              Button {
                bordered: true
                text: "Forget password"
                enabled: root.canForget
                onClicked: root.forgetCredential()
              }
            }

            // ---- discovery results ----
            Column {
              width: parent.width
              spacing: Style.spacing.sm
              visible: root.service && root.service.serversFound
                && root.service.serversFound.length > 0
              PanelSectionHeader {
                text: "Discovered servers (tap to fill)"
                color: root.foreground
              }
              Repeater {
                model: root.service ? root.service.serversFound : []
                delegate: Button {
                  required property var modelData
                  width: parent.width
                  text: modelData.name + "  " + modelData.host + ":"
                    + (modelData.port || 9000)
                    + (modelData.authRequired ? "  (password)" : "")
                  leftAlign: true
                  onClicked: root.useServer(modelData)
                }
              }
            }

            // ---- status ----
            Text {
              width: parent.width
              visible: root.service && root.service.phase !== ""
              text: {
                var s = root.service
                if (!s) return ""
                return "Status: " + s.phase
                  + (s.lastError ? " — " + s.lastError : "")
              }
              color: root.service && root.service.phase === "error"
                ? Color.urgent : root.foreground
              font.family: root.family
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }
          }
        }
      }
    }
  }
}