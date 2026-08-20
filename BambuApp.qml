import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Commons

Item {
  id: root

  readonly property string moduleName: "io.github.ypmrg.bambu-companion"
  property var shell: null
  property var service: null
  property bool closingFromHost: false
  readonly property bool opened: appWindow.visible

  function focusWindow() {
    Hyprland.dispatch("focuswindow title:^(Bambu Companion)$")
  }

  function open(_) {
    var wasVisible = appWindow.visible
    root.closingFromHost = false
    appWindow.visible = true
    appWindow.minimized = false
    if (wasVisible) Qt.callLater(root.focusWindow)
  }

  function close() {
    root.closingFromHost = true
    appWindow.visible = false
    root.closingFromHost = false
  }

  function requestClose() {
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide(root.moduleName)
    else appWindow.visible = false
  }

  Connections {
    target: root.service

    function onAttentionRequested(mode, message) {
      if (appWindow.visible) dashboard.showAttention(mode, message)
    }
  }

  FloatingWindow {
    id: appWindow
    visible: false
    title: "Bambu Companion"
    color: Color.popups.background
    implicitWidth: 1000
    implicitHeight: 640
    minimumSize: Qt.size(420, 320)

    onVisibleChanged: {
      if (!visible && !root.closingFromHost && root.shell
          && typeof root.shell.hide === "function")
        root.shell.hide(root.moduleName)
    }

    BambuDashboard {
      id: dashboard
      anchors.fill: parent
      service: root.service
      viewportHeight: appWindow.height
      surfaceActive: appWindow.visible
      onCloseRequested: root.requestClose()
    }
  }
}
