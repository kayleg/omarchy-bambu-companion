import qs.Commons
import qs.Ui

// Positive background insets keep every themed focus/hover border inside the
// TextField allocation instead of letting antialiasing touch adjacent cells.
TextField {
  readonly property real borderInset: Math.max(1, Style.space(1))

  leftInset: borderInset
  rightInset: borderInset
  topInset: borderInset
  bottomInset: borderInset
}
