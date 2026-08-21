import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.ypmrg.bambu-companion"

  BambuStyle { id: bambuStyle }

  property bool popupOpen: false
  readonly property bool opened: popupOpen
  readonly property var barShell: root.barMember("shell")
  readonly property var service: root.barShell
    ? root.barShell.serviceFor(root.moduleName) : null

  readonly property color foreground: root.barMember("foreground") !== undefined
    ? root.barMember("foreground") : Color.foreground
  readonly property color accent: Color.accent
  readonly property color successColor: "#39FF88"
  readonly property color errorColor: "#ff5f56"
  readonly property string fontFamily: root.barMember("fontFamily") !== undefined
    ? String(root.barMember("fontFamily")) : bambuStyle.fontFamily
  readonly property color printerIconColor: !root.service ? root.foreground
    : (root.service.barErrorActive ? root.errorColor
      : (root.service.barFinishActive ? root.successColor : root.foreground))

  function barMember(name) {
    return root.bar ? root.bar[name] : undefined
  }

  function open() {
    if (!root.service) return
    root.popupOpen = true
  }

  function close() {
    if (!root.service || root.service.disconnectPending) return
    root.popupOpen = false
  }

  function openAttention(mode, message) {
    root.popupOpen = true
    dashboard.showAttention(mode, message)
  }

  function openApp() {
    if (!root.barShell) return false
    if (!root.barShell.summon(root.moduleName, "{}")) return false
    root.close()
    return true
  }

  function compactLabel() {
    if (!root.service) return "STARTING"
    return root.service.statusSummary(" ")
  }

  function tooltipText() {
    if (!root.service) return "Bambu Companion · STARTING"
    return root.service.displayName + " · " + root.service.statusSummary(" · ")
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Connections {
    target: root.service

    function onAttentionRequested(mode, message) {
      var findPanelWidget = root.barMember("findPanelWidget")
      if (!root.barShell || typeof findPanelWidget !== "function") return
      if (root.barShell.isPluginOpen(root.moduleName)) return
      if (findPanelWidget.call(root.bar, root.moduleName) === root)
        root.openAttention(mode, message)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    labelVisible: false
    hasVisualContent: true
    fixedWidth: root.vertical ? barSize
      : buttonContent.implicitWidth + scaledHorizontalMargin * 2
    fixedHeight: barSize
    foreground: root.foreground
    activeColor: root.accent
    active: root.popupOpen
    fontFamily: root.fontFamily
    fontSize: bambuStyle.captionFontSize
    tooltipText: root.tooltipText()
    onPressed: {
      if (root.popupOpen) root.close()
      else root.open()
    }

    Row {
      id: buttonContent
      anchors.centerIn: parent
      height: button.fixedHeight
      spacing: Style.space(5)

      BambuPrinterIcon {
        anchors.verticalCenter: parent.verticalCenter
        source: root.service ? root.service.printerIconSource
          : Qt.resolvedUrl("assets/printer-open-frame.svg")
        tintColor: root.printerIconColor
      }

      Text {
        height: parent.height
        verticalAlignment: Text.AlignVCenter
        visible: !root.vertical && (!root.service || root.service.showBarSummary)
        width: Math.min(implicitWidth, Style.space(220))
        text: root.compactLabel()
        color: root.foreground
        elide: Text.ElideRight
        font.family: root.fontFamily
        font.pixelSize: bambuStyle.captionFontSize
        renderType: Text.NativeRendering
      }
    }
  }

  KeyboardPanel {
    id: popupPanel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.popupOpen
    focusTarget: dashboard.focusTarget
    padding: 0
    contentWidth: fittedContentWidth(Style.space(860))
    contentHeight: fittedContentHeight(dashboard.preferredViewportHeight)

    BambuDashboard {
      id: dashboard
      anchors.fill: parent
      service: root.service
      viewportHeight: Math.max(0, popupPanel.contentHeight
                               - popupPanel.verticalContentInset)
      surfaceActive: root.popupOpen
      showOpenAppButton: true
      onCloseRequested: root.close()
      onOpenAppRequested: root.openApp()
    }
  }
}
