import QtQuick
import QtQuick.Effects
import qs.Commons

Item {
  id: root

  property color foreground: Color.foreground
  property color accent: Color.accent
  property color errorColor: "#ff5f56"
  property color warningColor: "#ff9f43"
  property bool active: false
  property int unreadCount: 0
  property int unreadErrorCount: 0
  property int unreadWarningCount: 0
  property url iconSource: Qt.resolvedUrl("assets/list-restart.svg")

  signal clicked()

  readonly property color eventColor: root.unreadErrorCount > 0 ? root.errorColor
    : root.unreadWarningCount > 0 ? root.warningColor
    : root.active ? root.accent : root.foreground

  opacity: 1.0

  SequentialAnimation on opacity {
    running: root.unreadErrorCount > 0
    loops: Animation.Infinite
    NumberAnimation { to: 0.42; duration: 520; easing.type: Easing.InOutSine }
    NumberAnimation { to: 1.0; duration: 520; easing.type: Easing.InOutSine }
  }

  BambuButton {
    anchors.fill: parent
    text: ""
    tooltipText: root.unreadCount > 0
      ? root.unreadCount + " unread printer event" + (root.unreadCount === 1 ? "" : "s")
      : "EVENT LOG"
    foreground: root.eventColor
    accent: root.eventColor
    active: root.active || root.unreadErrorCount > 0
    bordered: true
    horizontalPadding: 0
    onClicked: root.clicked()

    Image {
      id: eventIconImage
      anchors.centerIn: parent
      width: Style.space(16)
      height: width
      source: root.iconSource
      sourceSize.width: width
      sourceSize.height: height
      visible: false
      layer.enabled: true
    }

    MultiEffect {
      anchors.fill: eventIconImage
      source: eventIconImage
      colorization: 1
      colorizationColor: root.eventColor
    }

    Rectangle {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(4)
      anchors.top: parent.top
      anchors.topMargin: Style.space(4)
      width: Style.space(5)
      height: width
      radius: width / 2
      visible: root.unreadCount > 0
      color: root.eventColor
    }
  }
}
