import QtQuick
import qs.Commons

// Gives qmllint concrete local types for Omarchy style groups. Omarchy keeps
// these tokens in nested QtObjects, whose members are available at runtime but
// are intentionally opaque to QML's generated type metadata.
QtObject {
  readonly property string fontFamily: Style.fontFamily

  // qmllint disable missing-property
  readonly property color popupBackground: Color.popups.background
  readonly property int captionFontSize: Style.font.caption
  readonly property int bodySmallFontSize: Style.font.bodySmall
  readonly property int bodyFontSize: Style.font.body
  readonly property int subtitleFontSize: Style.font.subtitle
  readonly property int controlPaddingX: Style.spacing.controlPaddingX
  readonly property int barIconCanvas: Style.bar.iconCanvas
  // qmllint enable missing-property
}
