import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: form

  clip: true

  property color foreground: Color.foreground
  property color accent: Color.accent
  property color errorColor: Color.accent
  property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.55)
  property string fontFamily: Style.font.family
  property bool daemonReady: false
  property bool allowBack: true
  property bool requireAccessCode: false
  property bool secretRequired: false
  property bool secretStored: false
  property bool secretStatusKnown: false
  property bool showBarSummary: true
  property string validationError: ""

  readonly property bool inputActive: hostInput.activeFocus
    || mqttPortInput.activeFocus || ftpsPortInput.activeFocus
    || accessCodeInput.activeFocus || printerNameInput.activeFocus
    || serialInput.activeFocus || usernameInput.activeFocus
    || maxSegmentsInput.activeFocus || accentColorInput.activeFocus

  signal backRequested()
  signal saveRequested(var draft, string accessCode)
  signal forgetCodeRequested()
  signal barSummaryToggled(bool enabled)
  signal inputFocusReleased()

  implicitHeight: Style.space(500)

  Keys.onEscapePressed: function(event) {
    inputFocusReleased()
    event.accepted = true
  }

  function load(draft) {
    var values = draft && typeof draft === "object" ? draft : ({})
    printerNameInput.text = String(values.printerName || "3D Printer")
    hostInput.text = String(values.host || "")
    mqttPortInput.text = String(values.mqttPort || "")
    ftpsPortInput.text = String(values.ftpsPort || "")
    serialInput.text = String(values.serial || "")
    usernameInput.text = String(values.username || "bblp")
    maxSegmentsInput.text = String(values.maxSegments || "")
    accentColorInput.text = String(values.accentColor || "#39FF88")
    showBarSummary = values.showBarSummary !== false
    validationError = ""
    clearAccessCode()
    resetScroll()
  }

  function clearAccessCode() {
    accessCodeInput.text = ""
  }

  function resetScroll() {
    settingsScroll.contentY = 0
  }

  function reportError(message) {
    validationError = String(message || "")
  }

  function parsePort(text, label) {
    var raw = String(text || "").trim()
    var number = Number(raw)
    if (!/^\d+$/.test(raw) || !isFinite(number)
        || Math.floor(number) !== number || number < 1 || number > 65535) {
      validationError = label + " must be between 1 and 65535"
      return -1
    }
    return number
  }

  function submit() {
    validationError = ""
    var nextHost = String(hostInput.text || "").trim()
    if (!nextHost || nextHost.length > 255 || /[\x00-\x1f\x7f]/.test(nextHost)) {
      validationError = "Enter a valid printer address"
      return
    }

    var nextMqtt = parsePort(mqttPortInput.text, "MQTT port")
    if (nextMqtt < 0) return
    var nextFtps = parsePort(ftpsPortInput.text, "FTPS port")
    if (nextFtps < 0) return

    var nextName = String(printerNameInput.text || "").trim()
    var nextSerial = String(serialInput.text || "").trim()
    var nextUsername = String(usernameInput.text || "").trim()
    if (nextName.length > 80) {
      validationError = "Printer name is too long"
      return
    }
    if (!nextSerial) {
      validationError = "Serial is required"
      return
    }
    if (!nextUsername) {
      validationError = "Username is required"
      return
    }
    if (form.requireAccessCode && String(accessCodeInput.text || "").trim() === "") {
      validationError = "Enter the LAN access code to connect"
      return
    }
    if (nextSerial && (nextSerial.length > 128 || !/^[A-Za-z0-9_-]+$/.test(nextSerial))) {
      validationError = "Serial contains unsupported characters"
      return
    }
    if (nextUsername.length > 128 || !/^[A-Za-z0-9_.:-]+$/.test(nextUsername)) {
      validationError = "Username contains unsupported characters"
      return
    }

    var segmentText = String(maxSegmentsInput.text || "").trim()
    var nextSegments = Number(segmentText)
    if (!/^\d+$/.test(segmentText) || !isFinite(nextSegments)
        || Math.floor(nextSegments) !== nextSegments
        || nextSegments < 1000 || nextSegments > 100000) {
      validationError = "Wireframe limit must be between 1000 and 100000"
      return
    }

    var nextAccentColor = String(accentColorInput.text || "").trim()
    if (!/^#[0-9A-Fa-f]{6}$/.test(nextAccentColor)) {
      validationError = "Accent color must use #RRGGBB"
      return
    }
    nextAccentColor = nextAccentColor.toUpperCase()

    var draft = {
      printerName: nextName,
      host: nextHost,
      mqttPort: nextMqtt,
      ftpsPort: nextFtps,
      serial: nextSerial,
      username: nextUsername,
      maxSegments: nextSegments,
      accentColor: nextAccentColor,
      showBarSummary: form.showBarSummary
    }
    saveRequested(draft, String(accessCodeInput.text || ""))
  }

  component FieldLabel: Text {
    width: parent ? parent.width : implicitWidth
    color: form.dim
    wrapMode: Text.Wrap
    font.family: form.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
    font.letterSpacing: 0.5
  }

  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(form.foreground.r, form.foreground.g,
                   form.foreground.b, 0.035)
  }

  Rectangle {
    id: settingsHeader
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    height: Style.space(36)
    color: Qt.rgba(form.foreground.r, form.foreground.g,
                   form.foreground.b, 0.025)

    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: 1
      color: Qt.rgba(form.foreground.r, form.foreground.g,
                     form.foreground.b, 0.12)
    }

    Text {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(12)
      anchors.right: settingsClose.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: "SETTINGS"
      color: form.foreground
      elide: Text.ElideRight
      font.family: form.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1
    }

    BambuButton {
      id: settingsClose
      visible: form.allowBack
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(64)
      height: Style.space(30)
      text: "CLOSE"
      foreground: form.foreground
      accent: form.accent
      bordered: false
      onClicked: form.backRequested()
    }
  }

  Flickable {
    id: settingsScroll
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: settingsHeader.bottom
    anchors.bottom: settingsFooter.top
    anchors.margins: Style.space(12)
    contentWidth: width
    contentHeight: settingsContent.implicitHeight
    flickableDirection: Flickable.VerticalFlick
    boundsBehavior: Flickable.StopAtBounds
    interactive: contentHeight > height + 1
    clip: true

    Column {
      id: settingsContent
      width: settingsScroll.width
      spacing: Style.space(5)

      Column {
        width: parent.width
        spacing: Style.space(4)
        FieldLabel { text: "PRINTER NAME" }
        BambuTextField {
          id: printerNameInput
          width: parent.width
          clip: true
          maximumLength: 80
          placeholderText: "Shown in the widget"
          foreground: form.foreground
          accent: form.accent
        }
      }

      Grid {
        id: identityGrid
        width: parent.width
        columns: width >= Style.space(420) ? 2 : 1
        columnSpacing: Style.space(8)
        rowSpacing: Style.space(7)
        readonly property real cellWidth: columns === 2
          ? Math.max(0, (width - columnSpacing) / 2) : width

        Column {
          width: identityGrid.cellWidth
          spacing: Style.space(4)
          FieldLabel { text: "PRINTER ADDRESS" }
          BambuTextField {
            id: hostInput
            width: parent.width
            clip: true
            maximumLength: 255
            placeholderText: "IPv4, IPv6 or hostname"
            foreground: form.foreground
            accent: form.accent
          }
        }

        Column {
          width: identityGrid.cellWidth
          spacing: Style.space(4)
          FieldLabel { text: "SERIAL NUMBER" }
          BambuTextField {
            id: serialInput
            width: parent.width
            clip: true
            maximumLength: 128
            placeholderText: "Printer network screen"
            foreground: form.foreground
            accent: form.accent
          }
        }
      }

      Grid {
        id: networkGrid
        width: parent.width
        columns: width >= Style.space(420) ? 3 : (width >= Style.space(260) ? 2 : 1)
        columnSpacing: Style.space(8)
        rowSpacing: Style.space(7)
        readonly property real cellWidth: Math.max(0,
          (width - columnSpacing * (columns - 1)) / columns)

        Column {
          width: networkGrid.cellWidth
          spacing: Style.space(4)
          FieldLabel { text: "MQTT TLS PORT" }
          BambuTextField {
            id: mqttPortInput
            width: parent.width
            clip: true
            maximumLength: 5
            inputMethodHints: Qt.ImhDigitsOnly
            placeholderText: "8883"
            foreground: form.foreground
            accent: form.accent
          }
        }

        Column {
          width: networkGrid.cellWidth
          spacing: Style.space(4)
          FieldLabel { text: "FTPS PORT" }
          BambuTextField {
            id: ftpsPortInput
            width: parent.width
            clip: true
            maximumLength: 5
            inputMethodHints: Qt.ImhDigitsOnly
            placeholderText: "990"
            foreground: form.foreground
            accent: form.accent
          }
        }

        Column {
          width: networkGrid.cellWidth
          spacing: Style.space(4)
          FieldLabel { text: "MQTT / FTPS USERNAME" }
          BambuTextField {
            id: usernameInput
            width: parent.width
            clip: true
            maximumLength: 128
            placeholderText: "bblp"
            foreground: form.foreground
            accent: form.accent
          }
        }
      }

      Item {
        id: lanCodeHeader
        width: parent.width
        height: Math.max(lanCodeLabel.implicitHeight, lanCodeStatus.implicitHeight)

        FieldLabel {
          id: lanCodeLabel
          anchors.left: parent.left
          anchors.right: lanCodeStatus.left
          anchors.rightMargin: Style.space(8)
          text: form.requireAccessCode
            ? "LAN ACCESS CODE" : "NEW LAN ACCESS CODE (OPTIONAL)"
          elide: Text.ElideRight
        }

        Text {
          id: lanCodeStatus
          anchors.right: parent.right
          text: form.secretStatusKnown && form.secretStored
            ? "● CODE SAVED IN GNOME KEYRING"
            : (form.secretStatusKnown && !form.secretStored && !form.secretRequired
              ? "● CODE ACTIVE FOR THIS SESSION"
              : (form.secretRequired ? "○ NO LAN CODE SAVED"
                : "○ CHECKING LAN CODE STATUS"))
          color: form.secretStatusKnown && (form.secretStored || !form.secretRequired)
            ? form.foreground : (form.secretRequired ? form.accent : form.dim)
          elide: Text.ElideRight
          font.family: form.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }

      Row {
        id: accessCodeRow
        width: parent.width
        spacing: Style.space(8)

        BambuTextField {
          id: accessCodeInput
          width: Math.max(0, parent.width - forgetCodeInline.width - parent.spacing)
          clip: true
          password: true
          maximumLength: 256
          placeholderText: form.requireAccessCode
            ? "Required to connect"
            : "Leave blank to keep the current code"
          foreground: form.foreground
          accent: form.accent
          onAccepted: form.submit()
        }

        BambuButton {
          id: forgetCodeInline
          width: Math.min(Style.space(126), parent.width * 0.38)
          height: accessCodeInput.height
          clip: true
          enabled: form.daemonReady
          text: "FORGET CODE"
          foreground: form.dim
          accent: form.accent
          bordered: true
          onClicked: form.forgetCodeRequested()
        }
      }

      Grid {
        id: preferencesGrid
        width: parent.width
        columns: width >= Style.space(260) ? 2 : 1
        columnSpacing: Style.space(8)
        rowSpacing: Style.space(7)
        readonly property real cellWidth: Math.max(0,
          (width - columnSpacing * (columns - 1)) / columns)

        Column {
          width: preferencesGrid.cellWidth
          spacing: Style.space(4)
          FieldLabel { text: "WIREFRAME SEGMENT LIMIT" }
          BambuTextField {
            id: maxSegmentsInput
            width: parent.width
            clip: true
            maximumLength: 6
            inputMethodHints: Qt.ImhDigitsOnly
            foreground: form.foreground
            accent: form.accent
          }
        }

        Column {
          width: preferencesGrid.cellWidth
          spacing: Style.space(4)
          FieldLabel { text: "ACCENT COLOR" }
          BambuTextField {
            id: accentColorInput
            width: parent.width
            clip: true
            maximumLength: 7
            placeholderText: "#39FF88"
            foreground: form.foreground
            accent: form.accent
          }
        }

        Column {
          id: barSummaryColumn
          width: preferencesGrid.cellWidth
          spacing: Style.space(4)
          FieldLabel { text: "BAR SUMMARY" }

          Item {
            width: parent.width
            height: accentColorInput.height

            ToggleSwitch {
              id: barSummarySwitch
              cursorPad: Math.max(0, Math.min(6,
                (parent.height - trackHeight) / 2))
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              checked: form.showBarSummary
              foreground: form.foreground
              accent: form.accent
              onToggled: {
                form.showBarSummary = !form.showBarSummary
                form.barSummaryToggled(form.showBarSummary)
              }
            }
          }
        }
      }

      Text {
        visible: form.validationError !== ""
        width: parent.width
        text: form.validationError
        color: form.errorColor
        wrapMode: Text.Wrap
        horizontalAlignment: Text.AlignHCenter
        font.family: form.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  Rectangle {
    id: settingsFooter
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    height: Style.space(60)
    color: Qt.rgba(form.foreground.r, form.foreground.g,
                   form.foreground.b, 0.025)

    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      height: 1
      color: Qt.rgba(form.foreground.r, form.foreground.g,
                     form.foreground.b, 0.12)
    }

    BambuButton {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.margins: Style.space(12)
      height: Style.space(36)
      clip: true
      text: "SAVE & CONNECT"
      foreground: form.foreground
      accent: form.accent
      bordered: true
      onClicked: form.submit()
    }
  }
}
