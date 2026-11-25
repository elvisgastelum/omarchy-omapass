import Quickshell
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Item {
  id: root

  property var shell: null
  property var manifest: null
  // Assigned once by the shell in onLoaded; null if the service registered later.
  property var service: null

  property bool opened: false

  // Follows the Omarchy language; bindings re-render on change.
  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property string pluginId: "elvisgastelum.omapass"
  // Looked up live so it follows the service if it registers late or reloads.
  readonly property var liveService: (root.shell && typeof root.shell.serviceFor === "function"
    ? root.shell.serviceFor(root.pluginId) : null) || root.service

  function open(payloadJson) {
    root.opened = true
    if (root.liveService && typeof root.liveService.overlayOpened === "function")
      root.liveService.overlayOpened()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide(root.pluginId)
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("")
  }

  OverlayWindow {
    id: panel
    shown: root.opened
    WlrLayershell.namespace: "omarchy-omapass"

    Rectangle {
      anchors.fill: parent
      color: Commons.Color.menu.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    Rectangle {
      id: card
      width: Style.space(240)
      height: Style.space(120)
      anchors.centerIn: parent
      radius: Style.cornerRadius
      color: Commons.Color.menu.background
      border.color: Commons.Color.menu.border
      border.width: Math.max(1, Style.space(2))

      MouseArea { anchors.fill: parent; onClicked: {} }

      Text {
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: root.liveService && root.liveService.skeletonValue === "service ok" ? strings.t("skeleton.serviceOk") : strings.t("skeleton.noService")
        color: Commons.Color.menu.text
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.body
      }
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          event.accepted = true
          root.dismiss()
        }
      }
    }
  }
}
