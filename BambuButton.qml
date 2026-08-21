import QtQuick
import qs.Commons
import qs.Ui

// Keeps Omarchy's native button styling while reserving a small visual gutter
// around its dynamic border. Hover/focus borders therefore remain inside the
// control's layout cell even when a theme uses antialiased or wider strokes.
Item {
  id: root

  BambuStyle { id: bambuStyle }

  property string text: ""
  property string tooltipText: ""
  property color foreground: Color.foreground
  property color background: "transparent"
  property color accent: Color.accent
  property bool bordered: false
  property bool active: false
  property real fontSize: bambuStyle.bodyFontSize
  property real horizontalPadding: bambuStyle.controlPaddingX
  readonly property real borderInset: Math.max(1, Style.space(1))

  signal clicked()

  clip: true
  implicitWidth: button.implicitWidth + borderInset * 2
  implicitHeight: button.implicitHeight + borderInset * 2

  Button {
    id: button
    anchors.fill: parent
    anchors.margins: root.borderInset
    enabled: root.enabled
    text: root.text
    tooltipText: root.tooltipText
    foreground: root.foreground
    background: root.background
    accent: root.accent
    bordered: root.bordered
    active: root.active
    selected: false
    focusable: false
    fontSize: root.fontSize
    horizontalPadding: root.horizontalPadding
    onClicked: root.clicked()
  }
}
