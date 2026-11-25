import QtQuick
import qs.Commons

Item {
  id: root

  // Injected by the shell after createObject; never read at construction.
  property var shell: null
  property var manifest: null

  readonly property string pluginId: "elvisgastelum.omapass"
  readonly property string skeletonValue: "service ok"

  function toggleOverlay() {
    if (root.shell && typeof root.shell.toggle === "function")
      root.shell.toggle(root.pluginId, "")
  }

  function openOverlay() {
    if (root.shell && typeof root.shell.summon === "function")
      root.shell.summon(root.pluginId, "")
  }

  function closeOverlay() {
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide(root.pluginId)
  }

  ShellIpc {
    target: "omapass"

    function toggle(): void { root.toggleOverlay() }
    function open(): void { root.openOverlay() }
    function close(): void { root.closeOverlay() }
  }
}
