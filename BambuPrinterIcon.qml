import QtQuick
import QtQuick.Effects
import qs.Commons

Item {
  id: icon

  property color tintColor: Color.foreground
  property url source

  implicitWidth: Style.bar.iconCanvas
  implicitHeight: Style.bar.iconCanvas

  Image {
    id: sourceImage
    anchors.fill: parent
    source: icon.source
    fillMode: Image.PreserveAspectFit
    visible: false
    layer.enabled: true
  }

  MultiEffect {
    anchors.fill: sourceImage
    source: sourceImage
    colorization: 1.0
    colorizationColor: icon.tintColor
  }
}
