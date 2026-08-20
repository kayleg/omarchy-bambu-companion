import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.ypmrg.bambu-companion"

  property bool popupOpen: false
  readonly property bool opened: popupOpen
  readonly property var service: root.bar && root.bar.shell
    ? root.bar.shell.serviceFor(root.moduleName) : null

  readonly property color foreground: root.bar ? root.bar.foreground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color successColor: "#39FF88"
  readonly property color errorColor: "#ff5f56"
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
  readonly property color printerIconColor: !root.service ? root.foreground
    : (root.service.barErrorActive ? root.errorColor
      : (root.service.barFinishActive ? root.successColor : root.foreground))

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
    if (!root.bar || !root.bar.shell) return false
    root.close()
    return root.bar.shell.summon(root.moduleName, "{}")
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
      if (!root.bar || !root.bar.shell || !root.bar.findPanelWidget) return
      if (root.bar.shell.isPluginOpen(root.moduleName)) return
      if (root.bar.findPanelWidget(root.moduleName) === root)
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
    fontSize: Style.font.caption
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
        font.pixelSize: Style.font.caption
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
