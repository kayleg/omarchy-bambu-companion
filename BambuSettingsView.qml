import QtQuick
import QtQuick.Controls
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
  property bool canDisconnect: false
  property bool secretRequired: false
  property bool secretStored: false
  property bool secretStatusKnown: false
  property bool autoRotate: true
  property bool showBarSummary: true
  property bool desktopEntryInstalled: false
  property bool desktopEntryBusy: false
  property string desktopEntryError: ""
  property string validationError: ""

  readonly property bool inputActive: hostInput.activeFocus
    || mqttPortInput.activeFocus || ftpsPortInput.activeFocus
    || accessCodeInput.activeFocus || printerNameInput.activeFocus
    || serialInput.activeFocus || usernameInput.activeFocus
    || maxSegmentsInput.activeFocus || explosionFactorInput.activeFocus

  signal backRequested()
  signal saveRequested(var draft, string accessCode)
  signal trustRequested(var draft, string accessCode)
  signal disconnectRequested()
  signal forgetCodeRequested()
  signal barSummaryToggled(bool enabled)
  signal desktopEntryToggled(bool enabled)
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
    explosionFactorInput.text = String(values.explosionFactor === undefined
      ? 100 : values.explosionFactor)
    autoRotate = values.autoRotate !== false
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

  function parseInteger(text, label, minimum, maximum) {
    var raw = String(text || "").trim()
    var number = Number(raw)
    if (!/^\d+$/.test(raw) || !isFinite(number)
        || Math.floor(number) !== number
        || number < minimum || number > maximum) {
      validationError = label + " must be between " + minimum + " and " + maximum
      return -1
    }
    return number
  }

  function submit(trustCertificate) {
    validationError = ""
    var nextHost = String(hostInput.text || "").trim()
    if (!nextHost || nextHost.length > 255 || /[\x00-\x1f\x7f]/.test(nextHost)) {
      validationError = "Enter a valid printer address"
      return
    }

    var nextMqtt = parseInteger(mqttPortInput.text, "MQTT port", 1, 65535)
    if (nextMqtt < 0) return
    var nextFtps = parseInteger(ftpsPortInput.text, "FTPS port", 1, 65535)
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

    var nextSegments = parseInteger(
      maxSegmentsInput.text, "Wireframe limit", 1000, 1000000)
    if (nextSegments < 0) return
    var nextExplosionFactor = parseInteger(
      explosionFactorInput.text, "Explode factor", 0, 500)
    if (nextExplosionFactor < 0) return

    var draft = {
      printerName: nextName,
      host: nextHost,
      mqttPort: nextMqtt,
      ftpsPort: nextFtps,
      serial: nextSerial,
      username: nextUsername,
      maxSegments: nextSegments,
      explosionFactor: nextExplosionFactor,
      autoRotate: form.autoRotate,
      showBarSummary: form.showBarSummary
    }
    if (trustCertificate === true) {
      trustRequested(draft, String(accessCodeInput.text || ""))
    } else {
      saveRequested(draft, String(accessCodeInput.text || ""))
    }
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

  component SectionLabel: Text {
    width: parent ? parent.width : implicitWidth
    height: implicitHeight + Style.space(8)
    verticalAlignment: Text.AlignBottom
    color: form.accent
    font.family: form.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
    font.letterSpacing: 1
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
    ScrollBar.vertical: ScrollBar {
      policy: settingsScroll.interactive
        ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
    }

    Column {
      id: settingsContent
      width: Math.max(0, settingsScroll.width
        - (settingsScroll.interactive ? Style.space(20) : 0))
      spacing: Style.space(8)

      SectionLabel { text: "PRINTER" }

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

      SectionLabel { text: "NETWORK" }

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
          onAccepted: form.submit(false)
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

      SectionLabel { text: "DISPLAY" }

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
            maximumLength: 7
            inputMethodHints: Qt.ImhDigitsOnly
            foreground: form.foreground
            accent: form.accent
          }
        }

        Column {
          width: preferencesGrid.cellWidth
          spacing: Style.space(4)
          FieldLabel { text: "EXPLODE FACTOR" }
          BambuTextField {
            id: explosionFactorInput
            width: parent.width
            clip: true
            maximumLength: 3
            inputMethodHints: Qt.ImhDigitsOnly
            placeholderText: "100"
            foreground: form.foreground
            accent: form.accent
          }
        }

      }

      Column {
        width: parent.width
        spacing: Style.space(4)

        Column {
          width: parent.width
          spacing: Style.space(4)
          FieldLabel { text: "AUTO-ROTATE BY DEFAULT" }

          ToggleSwitch {
            cursorPad: 0
            anchors.left: parent.left
            checked: form.autoRotate
            foreground: form.foreground
            accent: form.accent
            onToggled: form.autoRotate = !form.autoRotate
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(4)
          FieldLabel { text: "BAR SUMMARY" }

          ToggleSwitch {
            cursorPad: 0
            anchors.left: parent.left
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

      SectionLabel { text: "DESKTOP" }

      Column {
        width: parent.width
        spacing: Style.space(6)

        Text {
          width: parent.width
          text: form.desktopEntryInstalled
            ? "● AVAILABLE IN THE APP LAUNCHER"
            : "○ NOT IN THE APP LAUNCHER"
          color: form.desktopEntryInstalled ? form.foreground : form.dim
          wrapMode: Text.Wrap
          font.family: form.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        Text {
          width: parent.width
          text: "Installs a standard desktop entry. The app opens as a normal tiled window."
          color: form.dim
          wrapMode: Text.Wrap
          font.family: form.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        BambuButton {
          width: parent.width
          height: Style.space(36)
          enabled: !form.desktopEntryBusy
          clip: true
          text: form.desktopEntryBusy ? "UPDATING APP LAUNCHER…"
            : (form.desktopEntryInstalled
              ? "REMOVE FROM APP LAUNCHER" : "ADD TO APP LAUNCHER")
          foreground: form.foreground
          accent: form.accent
          bordered: true
          onClicked: form.desktopEntryToggled(!form.desktopEntryInstalled)
        }

        Text {
          visible: form.desktopEntryError !== ""
          width: parent.width
          text: form.desktopEntryError
          color: form.errorColor
          wrapMode: Text.Wrap
          font.family: form.fontFamily
          font.pixelSize: Style.font.bodySmall
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

    Row {
      anchors.fill: parent
      anchors.margins: Style.space(12)
      spacing: Style.space(8)

      BambuButton {
        width: Math.max(0, (parent.width - parent.spacing) / 2)
        height: parent.height
        clip: true
        enabled: form.canDisconnect
        text: "DISCONNECT PRINTER"
        foreground: enabled ? form.errorColor : form.dim
        accent: form.errorColor
        bordered: true
        onClicked: form.disconnectRequested()
      }

      BambuButton {
        width: Math.max(0, (parent.width - parent.spacing) / 2)
        height: parent.height
        clip: true
        text: "SAVE & CONNECT"
        foreground: form.foreground
        accent: form.accent
        bordered: true
        onClicked: form.submit(false)
      }
    }
  }
}
