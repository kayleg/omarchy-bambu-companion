import QtQuick
import QtQuick.Effects
import qs.Commons
import qs.Ui

Item {
  id: pane

  property color foreground: Color.foreground
  property color accent: Color.accent
  property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.55)
  property color neon: accent
  property color errorColor: Color.accent
  property bool errorActive: false
  property bool modelErrorActive: false
  property string fontFamily: Style.font.family
  property url printerIconSource
  property color iconColor: foreground

  property string printerName: "3D Printer"
  property bool online: false
  property string printerState: "OFFLINE"
  property string jobName: "NO ACTIVE PRINT"
  property int percent: 0
  property string remainingValue: "--"
  property string nozzleValue: "--°"
  property string bedValue: "--°"
  property string layerValue: "-- / --"
  property string zValue: "--"
  property string speedValue: "--"
  property string fanValue: "--"
  property string hostValue: "--"
  property string portsValue: "--"
  property string wifiValue: "--"
  property string reportValue: "--"
  property string segmentValue: "0 SEGMENTS"
  property string modelState: "IDLE"
  property string dimensionsValue: "--"

  signal settingsRequested()

  readonly property color surface: Qt.rgba(
    foreground.r, foreground.g, foreground.b, 0.035)
  readonly property int inset: Style.space(12)

  component SectionTitle: Item {
    width: parent ? parent.width : implicitWidth
    height: Style.space(22)

    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      height: 1
      color: Qt.rgba(pane.foreground.r, pane.foreground.g,
                     pane.foreground.b, 0.12)
    }

    Text {
      anchors.left: parent.left
      anchors.bottom: parent.bottom
      text: parent.objectName
      color: pane.dim
      font.family: pane.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1
    }
  }

  component MetricRow: Item {
    id: metric
    property string label: ""
    property string value: ""
    property color valueColor: pane.foreground

    width: parent ? parent.width : implicitWidth
    height: Math.max(metricLabel.implicitHeight, metricValue.implicitHeight)

    Text {
      id: metricLabel
      width: parent.width * 0.42
      text: metric.label
      color: pane.dim
      elide: Text.ElideRight
      font.family: pane.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      id: metricValue
      anchors.left: metricLabel.right
      anchors.right: parent.right
      text: metric.value
      color: metric.valueColor
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideRight
      font.family: pane.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  component SidebarPrinterIcon: Item {
    implicitWidth: Style.bar.iconCanvas
    implicitHeight: Style.bar.iconCanvas

    Image {
      id: sourceImage
      anchors.fill: parent
      source: pane.printerIconSource
      fillMode: Image.PreserveAspectFit
      visible: false
      layer.enabled: true
    }

    MultiEffect {
      anchors.fill: sourceImage
      source: sourceImage
      colorization: 1.0
      colorizationColor: pane.iconColor
    }
  }

  Rectangle {
    anchors.fill: parent
    color: pane.surface
  }

  Flickable {
    id: telemetryScroll
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.bottom: settingsButton.top
    anchors.margins: pane.inset
    anchors.bottomMargin: Style.space(8)
    contentWidth: width
    contentHeight: telemetryContent.implicitHeight
    flickableDirection: Flickable.VerticalFlick
    boundsBehavior: Flickable.StopAtBounds
    interactive: contentHeight > height + 1
    clip: true

    Column {
      id: telemetryContent
      width: telemetryScroll.width
      spacing: Style.space(3)

      Text {
        id: statusLine
        width: parent.width
        text: (pane.online ? "● ONLINE" : "○ OFFLINE")
          + "  ·  " + pane.printerState
        color: pane.errorActive ? pane.errorColor
          : (pane.online ? pane.neon : pane.dim)
        elide: Text.ElideRight
        font.family: pane.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      Row {
        id: printerIdentity
        width: parent.width
        height: Math.max(statusIcon.implicitHeight, printerNameText.implicitHeight)
        spacing: Style.space(6)

        SidebarPrinterIcon {
          id: statusIcon
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          id: printerNameText
          width: Math.max(0, parent.width - statusIcon.width - parent.spacing)
          height: parent.height
          text: pane.printerName.toUpperCase()
          color: pane.errorActive ? pane.errorColor : pane.foreground
          verticalAlignment: Text.AlignVCenter
          elide: Text.ElideRight
          font.family: pane.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }
      }

      Text {
        width: parent.width
        text: pane.jobName
        color: pane.dim
        elide: Text.ElideMiddle
        font.family: pane.fontFamily
        font.pixelSize: Style.font.caption
      }

      Rectangle {
        width: parent.width
        height: Style.space(8)
        color: Qt.rgba(pane.foreground.r, pane.foreground.g,
                       pane.foreground.b, 0.05)
        border.width: 1
        border.color: Qt.rgba(pane.foreground.r, pane.foreground.g,
                              pane.foreground.b, 0.12)

        Rectangle {
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          anchors.margins: 2
          width: Math.max(0, (parent.width - 4) * pane.percent / 100)
          color: pane.neon
        }
      }

      Item {
        width: parent.width
        height: Math.max(progressText.implicitHeight, remainingText.implicitHeight)
        Text {
          id: progressText
          anchors.left: parent.left
          text: pane.percent + "% COMPLETE"
          color: pane.neon
          font.family: pane.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }
        Text {
          id: remainingText
          anchors.right: parent.right
          text: pane.remainingValue + " LEFT"
          color: pane.dim
          font.family: pane.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      SectionTitle { objectName: "TEMPERATURES" }
      MetricRow { label: "NOZZLE"; value: pane.nozzleValue }
      MetricRow { label: "BED"; value: pane.bedValue }

      SectionTitle { objectName: "PRINT METRICS" }
      MetricRow { label: "LAYER"; value: pane.layerValue }
      MetricRow { label: "Z HEIGHT"; value: pane.zValue; valueColor: pane.neon }
      MetricRow { label: "REMAINING"; value: pane.remainingValue }
      MetricRow { label: "SPEED"; value: pane.speedValue }
      MetricRow { label: "FANS"; value: pane.fanValue }

      SectionTitle { objectName: "CONNECTION" }
      MetricRow { label: "ADDRESS"; value: pane.hostValue }
      MetricRow { label: "PORTS"; value: pane.portsValue }
      MetricRow { label: "WI-FI"; value: pane.wifiValue; valueColor: pane.online ? pane.neon : pane.dim }
      MetricRow { label: "REPORT"; value: pane.reportValue }

      SectionTitle { objectName: "MODEL DATA" }
      MetricRow { label: "GEOMETRY"; value: pane.segmentValue }
      MetricRow { label: "STATUS"; value: pane.modelState; valueColor: (pane.errorActive || pane.modelErrorActive) ? pane.errorColor : (pane.modelState === "READY" ? pane.neon : pane.foreground) }
      MetricRow { label: "SIZE"; value: pane.dimensionsValue }
    }
  }

  BambuButton {
    id: settingsButton
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.margins: pane.inset
    height: Style.space(36)
    clip: true
    text: "SETTINGS"
    foreground: pane.foreground
    accent: pane.accent
    bordered: true
    onClicked: pane.settingsRequested()
  }
}
