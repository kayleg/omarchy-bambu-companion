import QtQuick
import QtQuick.Effects
import qs.Commons

Item {
  id: icon

  BambuStyle { id: bambuStyle }

  property color tintColor: Color.foreground
  property url source

  implicitWidth: bambuStyle.barIconCanvas
  implicitHeight: bambuStyle.barIconCanvas

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
