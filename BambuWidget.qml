import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.ypmrg.bambu-companion"

  property bool popupOpen: false
  readonly property bool opened: popupOpen
  property string viewMode: "setup"
  property bool componentReady: false
  property bool initialViewResolved: false
  property bool installationIdentified: false
  property string installationId: ""
  property bool daemonReady: false
  property bool connected: false
  property bool connectionVerified: false
  property bool stale: true
  property bool secretRequired: false
  property bool secretStored: false
  property bool secretStatusKnown: false
  readonly property bool hasUsableSecret: root.secretStored
    || (root.secretStatusKnown && !root.secretRequired)
  property string gcodeState: "OFFLINE"
  property bool finishGraceExpired: false
  readonly property string displayGcodeState:
    root.finishGraceExpired && root.isFinishedState(root.gcodeState)
      ? "READY" : root.gcodeState
  property string subtaskName: ""
  property int percent: 0
  property real nozzleTemp: NaN
  property real nozzleTargetTemp: NaN
  property real bedTemp: NaN
  property real bedTargetTemp: NaN
  property int currentLayer: 0
  property int totalLayers: 0
  property int remainingMinutes: -1
  property int speedLevel: 0
  property int speedMagnitude: 0
  property string wifiSignal: ""
  property real coolingFanSpeed: NaN
  property real heatbreakFanSpeed: NaN
  property string lastUpdate: ""
  property string modelStatus: "idle"
  property string modelErrorCode: ""
  property string modelError: ""
  property real zCurrent: NaN
  property string zMode: "unknown"
  property string processError: ""
  property string processErrorReportUpdate: ""
  property int restartDelay: 1000
  property bool restartScheduled: false
  property bool pendingSecretWrite: false
  property bool persistingSettings: false
  property bool tlsProbePending: false
  property bool tlsApprovalRequired: false
  property bool tlsRejected: false
  property bool disconnectConfirmationOpen: false
  property bool disconnectPending: false
  property int disconnectRequestId: 0
  property int tlsProbeRequestId: 0
  property var pendingTlsDraft: ({})
  property var mqttTlsIdentity: ({})
  property var ftpsTlsIdentity: ({})
  readonly property int maxIpcLineChars: 1048576
  readonly property int maxPreviewBytes: 524288
  readonly property int maxPreviewPixels: 4194304
  readonly property int maxPreviewChunkChars: 49152
  property string stdoutBuffer: ""
  property bool stdoutDiscarding: false
  property string stderrBuffer: ""
  property bool stderrDiscarding: false

  property var geometryBundle: ({})
  property string selectedGeometrySource: "gcode"
  readonly property bool previewAvailable:
    !!root.geometryBundle.preview
      && String(root.geometryBundle.preview.url || "").startsWith("data:image/png;base64,")
  readonly property bool gcodeGeometryAvailable:
    !!root.geometryBundle.gcode
      && Array.isArray(root.geometryBundle.gcode.segments)
      && root.geometryBundle.gcode.segments.length > 0
  readonly property var activeSegments: {
    var geometry = root.geometryBundle.gcode
    return geometry && Array.isArray(geometry.segments) ? geometry.segments : []
  }
  readonly property var activeBounds: {
    var geometry = root.geometryBundle.gcode
    return geometry && geometry.bounds ? geometry.bounds : ({})
  }
  property int modelGeneration: -1
  property var pendingGeometry: ({})

  readonly property string printerName: String(setting("printerName", "3D Printer"))
  readonly property string host: String(setting("host", ""))
  readonly property int mqttPort: Number(setting("mqttPort", 8883))
  readonly property int ftpsPort: Number(setting("ftpsPort", 990))
  readonly property string serial: String(setting("serial", ""))
  readonly property string username: String(setting("username", "bblp"))
  readonly property int maxSegments: Number(setting("maxSegments", 40000))
  readonly property int explosionFactor: Math.max(0, Math.min(500,
    Math.round(finiteNumber(Number(setting("explosionFactor", 100)), 100))))
  readonly property bool autoRotate: setting("autoRotate", true) !== false
  readonly property bool showBarSummary: setting("showBarSummary", true) !== false
  readonly property string mqttTlsFingerprint:
    String(setting("mqttTlsFingerprint", ""))
  readonly property string ftpsTlsFingerprint:
    String(setting("ftpsTlsFingerprint", ""))
  readonly property string storedInstallationId: String(setting("installationId", ""))
  readonly property bool hasConnectionTarget: String(root.host).trim() !== ""
    && String(root.serial).trim() !== ""
  readonly property bool hasTrustedTlsPins:
    root.validTlsFingerprint(root.mqttTlsFingerprint)
      && root.validTlsFingerprint(root.ftpsTlsFingerprint)
  readonly property bool requiresSetupConfirmation: !root.hasConnectionTarget
    || !root.hasTrustedTlsPins || root.tlsRejected
    || (root.installationIdentified
        && root.storedInstallationId !== root.installationId)
  readonly property string securityModalMode:
    (root.disconnectConfirmationOpen || root.disconnectPending) ? "disconnect"
      : ((root.tlsProbePending || root.tlsApprovalRequired) ? "certificate" : "")
  readonly property string displayName: {
    var name = String(root.printerName || "").trim()
    return name || "3D Printer"
  }
  readonly property string backendConfigurationFingerprint: JSON.stringify(root.configuration())
  readonly property url printerIconSource: Qt.resolvedUrl("assets/printer-open-frame.svg")
  readonly property string backendPath: decodeURIComponent(
    String(Qt.resolvedUrl("bambu-companion")).replace(/^file:\/\//, "")
  )
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color successColor: "#39FF88"
  readonly property color errorColor: "#ff5f56"
  readonly property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.55)
  readonly property bool errorActive: root.printerHasError()
    || root.processError !== ""
  readonly property bool modelErrorActive: root.modelStatus === "error"
    && root.modelError !== ""
  readonly property bool barFinishActive: root.connected && !root.stale
    && root.isFinishedState(root.displayGcodeState)
  readonly property color printerIconColor: root.errorActive ? root.errorColor
    : (root.barFinishActive ? root.successColor : root.foreground)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function open() {
    popupOpen = true
    if (root.viewMode !== "settings") viewMode = nextIdleView()
    if (root.requiresSetupConfirmation) {
      viewMode = "setup"
      if (componentReady) settingsView.load(settingsDraft())
    }
  }

  function close() {
    if (root.disconnectPending) return
    root.cancelSecurityModal()
    popupOpen = false
    if (componentReady) settingsView.clearAccessCode()
    viewMode = nextIdleView()
  }

  function nextIdleView() {
    if (root.requiresSetupConfirmation) return "setup"
    if (root.connectionVerified) return "status"
    return "connecting"
  }

  // Quattro injects BarWidget.settings from Loader.onLoaded, after this
  // component's Component.onCompleted handler. Defer the first decision so a
  // persisted printer is never mistaken for an unconfigured installation.
  function resolveInitialView() {
    if (root.initialViewResolved) return
    initialViewResolved = true
    viewMode = nextIdleView()
    if (viewMode === "setup") settingsView.load(settingsDraft())
  }

  function focusPanelTop() {
    Qt.callLater(function() {
      panelScroll.contentY = 0
      keyCatcher.forceActiveFocus()
    })
  }

  function enterConnecting() {
    settingsView.clearAccessCode()
    viewMode = root.hasConnectionTarget ? "connecting" : "setup"
    root.focusPanelTop()
  }

  function settingsDraft() {
    return {
      printerName: root.printerName,
      host: root.host,
      mqttPort: root.mqttPort,
      ftpsPort: root.ftpsPort,
      serial: root.serial,
      username: root.username,
      maxSegments: root.maxSegments,
      explosionFactor: root.explosionFactor,
      autoRotate: root.autoRotate,
      showBarSummary: root.showBarSummary,
      mqttTlsFingerprint: root.mqttTlsFingerprint,
      ftpsTlsFingerprint: root.ftpsTlsFingerprint
    }
  }

  function openSettings() {
    settingsView.load(settingsDraft())
    viewMode = "settings"
    root.focusPanelTop()
  }

  function toggleSettings() {
    if (root.viewMode === "settings") {
      root.backToStatus()
      return
    }
    root.openSettings()
  }

  function backToStatus() {
    if (root.requiresSetupConfirmation) {
      viewMode = "setup"
      popupOpen = true
      root.focusPanelTop()
      return
    }
    if (!root.connectionVerified) {
      enterConnecting()
      return
    }
    settingsView.clearAccessCode()
    viewMode = "status"
    root.focusPanelTop()
  }

  function commitSettingsEntry(entry) {
    if (!root.bar || !root.bar.shell
        || typeof root.bar.shell.updateEntryInline !== "function") return false
    persistingSettings = true
    root.settings = entry
    root.bar.shell.updateEntryInline(root.moduleName, entry)
    persistingSettings = false
    return true
  }

  function persistSettings(draft) {
    var entry = { id: root.moduleName }
    entry.printerName = draft.printerName
    entry.host = draft.host
    entry.mqttPort = draft.mqttPort
    entry.ftpsPort = draft.ftpsPort
    entry.serial = draft.serial
    entry.username = draft.username
    entry.maxSegments = draft.maxSegments
    entry.explosionFactor = draft.explosionFactor
    entry.autoRotate = draft.autoRotate
    entry.showBarSummary = draft.showBarSummary
    entry.mqttTlsFingerprint = String(draft.mqttTlsFingerprint || "")
    entry.ftpsTlsFingerprint = String(draft.ftpsTlsFingerprint || "")
    entry.installationId = draft.installationId === undefined
      ? root.installationId : String(draft.installationId || "")
    return root.commitSettingsEntry(entry)
  }

  // The immediate toggle must not save partially edited printer credentials
  // or restart the printer session.
  function persistBarSummary(enabled) {
    var current = root.settings && typeof root.settings === "object"
      ? root.settings : ({})
    var entry = { id: root.moduleName }
    for (var key in current) {
      if (key !== "id") entry[key] = current[key]
    }
    entry["showBarSummary"] = enabled === true
    return root.commitSettingsEntry(entry)
  }

  function backendSettingsChanged(draft) {
    return String(draft.host) !== root.host
      || Number(draft.mqttPort) !== root.mqttPort
      || Number(draft.ftpsPort) !== root.ftpsPort
      || String(draft.serial) !== root.serial
      || String(draft.username) !== root.username
      || Number(draft.maxSegments) !== root.segmentLimit()
      || String(draft.mqttTlsFingerprint || "") !== root.mqttTlsFingerprint
      || String(draft.ftpsTlsFingerprint || "") !== root.ftpsTlsFingerprint
  }

  function saveSettings(draft, accessCode) {
    var replacement = String(accessCode || "")
    if (!replacement && !root.hasUsableSecret) {
      settingsView.reportError("Enter the LAN access code to connect")
      return
    }
    if (replacement && (!root.daemonReady || !sessionProcess.running)) {
      settingsView.reportError("Backend is not ready for the LAN code")
      return
    }
    if (root.requiresTlsProbe(draft)) {
      root.beginTlsProbe(draft)
      return
    }
    draft.mqttTlsFingerprint = root.mqttTlsFingerprint
    draft.ftpsTlsFingerprint = root.ftpsTlsFingerprint
    var backendChanged = backendSettingsChanged(draft)
    pendingSecretWrite = !!replacement
    if (!persistSettings(draft)) {
      pendingSecretWrite = false
      settingsView.reportError("Settings could not be saved by Omarchy Shell")
      return
    }
    if (!backendChanged && !replacement) {
      settingsView.clearAccessCode()
      viewMode = nextIdleView()
      root.focusPanelTop()
      return
    }
    enterConnecting()
    if (backendChanged) sendConfiguration(draft)
    if (!replacement) return
    Qt.callLater(function() {
      if (!setSecret(replacement)) {
        recoverSecretWrite("LAN code could not be sent. Enter it again")
      }
    })
  }

  function tlsTarget(draft) {
    return JSON.stringify({
      host: String(draft.host || "").trim(),
      mqttPort: Number(draft.mqttPort),
      ftpsPort: Number(draft.ftpsPort),
      serial: String(draft.serial || "").trim()
    })
  }

  function requiresTlsProbe(draft) {
    if (root.tlsRejected || !root.hasTrustedTlsPins) return true
    return root.tlsTarget(draft) !== root.tlsTarget(root.settingsDraft())
  }

  function clearTlsProbeState() {
    root.tlsProbePending = false
    root.tlsApprovalRequired = false
    root.pendingTlsDraft = ({})
    root.mqttTlsIdentity = ({})
    root.ftpsTlsIdentity = ({})
  }

  function cancelTlsApproval() {
    root.tlsProbeRequestId = (root.tlsProbeRequestId + 1) % 2147483647
    root.clearTlsProbeState()
  }

  function cancelSecurityModal() {
    if (root.disconnectConfirmationOpen) {
      root.disconnectConfirmationOpen = false
    } else if (root.tlsProbePending || root.tlsApprovalRequired) {
      root.cancelTlsApproval()
    }
    if (root.popupOpen) {
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }
  }

  function beginTlsProbe(draft) {
    if (!root.daemonReady || !sessionProcess.running) {
      settingsView.reportError("Backend is not ready to check the certificate")
      return false
    }
    root.tlsProbeRequestId = (root.tlsProbeRequestId + 1) % 2147483647
    root.clearTlsProbeState()
    root.pendingTlsDraft = JSON.parse(JSON.stringify(draft))
    root.tlsProbePending = true
    settingsView.reportError("")
    var probeConfig = root.configurationForDraft(draft)
    probeConfig.mqttTlsFingerprint = ""
    probeConfig.ftpsTlsFingerprint = ""
    var written = root.writeCommand({
      "op": "probe_tls", "protocol": 1,
      "requestId": root.tlsProbeRequestId, "config": probeConfig
    })
    if (!written) {
      root.tlsProbePending = false
      settingsView.reportError("Certificate check could not be started")
    }
    return written
  }

  function trustAndConnect(draft, accessCode) {
    if (!root.tlsApprovalRequired) return
    if (root.tlsTarget(draft) !== root.tlsTarget(root.pendingTlsDraft)) {
      root.clearTlsProbeState()
      root.saveSettings(draft, accessCode)
      return
    }
    var trusted = JSON.parse(JSON.stringify(draft))
    trusted.mqttTlsFingerprint = String(root.mqttTlsIdentity.fingerprint || "")
    trusted.ftpsTlsFingerprint = String(root.ftpsTlsIdentity.fingerprint || "")
    var replacement = String(accessCode || "")
    var backendChanged = backendSettingsChanged(trusted)
    pendingSecretWrite = !!replacement
    if (!persistSettings(trusted)) {
      pendingSecretWrite = false
      settingsView.reportError("Settings could not be saved by Omarchy Shell")
      return
    }
    root.clearTlsProbeState()
    root.tlsRejected = false
    root.processError = ""
    enterConnecting()
    if (backendChanged) sendConfiguration(trusted)
    if (!replacement) return
    Qt.callLater(function() {
      if (!setSecret(replacement)) {
        recoverSecretWrite("LAN code could not be sent. Enter it again")
      }
    })
  }

  function handleTlsMismatch(message) {
    if (root.tlsRejected) return
    root.tlsRejected = true
    root.clearTlsProbeState()
    root.openSettings()
    settingsView.reportError(message)
    root.popupOpen = true
  }

  // The non-secret address/identity settings remain useful when a printer is
  // temporarily offline. If the secret handoff itself fails, return to those
  // saved values and require the user to enter the code again.
  function recoverSecretWrite(message) {
    if (!root.pendingSecretWrite) return false
    pendingSecretWrite = false
    openSettings()
    settingsView.reportError(message)
    popupOpen = true
    return true
  }

  function handleAuthenticationFailure(message) {
    // A rejection from the previous session may arrive while a replacement is
    // already queued. Let that write complete; a rejection from the restarted
    // session will arrive after secret_status and reopen the form if necessary.
    if (root.pendingSecretWrite) return false
    pendingSecretWrite = false
    secretRequired = true
    secretStored = false
    secretStatusKnown = true
    openSettings()
    settingsView.reportError(message)
    popupOpen = true
    return true
  }

  function objectOrEmpty(value) {
    return value && typeof value === "object" && !Array.isArray(value) ? value : ({})
  }

  function finiteNumber(value, fallback) {
    if (value === null || value === undefined || value === "") return fallback
    var number = Number(value)
    return isFinite(number) ? number : fallback
  }

  function isNonNegativeInteger(value) {
    return typeof value === "number" && isFinite(value)
      && value >= 0 && Math.floor(value) === value
  }

  function selectGeometrySource(source) {
    if ((source === "preview" && root.previewAvailable)
        || (source === "gcode" && root.gcodeGeometryAvailable)) {
      selectedGeometrySource = source
      return true
    }
    return false
  }

  function validTlsFingerprint(value) {
    return /^[0-9A-Fa-f]{64}$/.test(String(value || ""))
  }

  function isValidSegment(segment) {
    if (!Array.isArray(segment) || segment.length !== 6) return false
    for (var index = 0; index < segment.length; index++) {
      if (typeof segment[index] !== "number" || !isFinite(segment[index])) return false
    }
    return true
  }

  function validPreview(preview) {
    preview = objectOrEmpty(preview)
    if (!isNonNegativeInteger(preview.byteCount) || preview.byteCount < 1
        || preview.byteCount > root.maxPreviewBytes
        || !isNonNegativeInteger(preview.width) || preview.width < 1
        || !isNonNegativeInteger(preview.height) || preview.height < 1
        || preview.width * preview.height > root.maxPreviewPixels
        || preview.mimeType !== "image/png") return false
    var expectedLength = 4 * Math.ceil(preview.byteCount / 3)
    return isNonNegativeInteger(preview.encodedLength)
      && preview.encodedLength === expectedLength
  }

  function isFinishedState(state) {
    var value = String(state || "").toUpperCase()
    return value === "FINISH" || value === "FINISHED"
      || value === "COMPLETE" || value === "COMPLETED"
  }

  function printerHasError() {
    var state = String(root.gcodeState || "").toUpperCase()
    return state === "ERROR" || state === "FAILED" || state.indexOf("ERROR") >= 0
  }

  function segmentLimit() {
    var configured = finiteNumber(root.maxSegments, 40000)
    return Math.max(0, Math.min(100000, Math.floor(configured)))
  }

  function formatTemp(value) {
    return isFinite(Number(value)) ? Math.round(Number(value)) + "°" : "--°"
  }

  function formatTempPair(current, target) {
    var currentText = root.formatTemp(current)
    if (!isFinite(Number(target))) return currentText
    return currentText + " / " + root.formatTemp(target)
  }

  function formatDuration(minutes) {
    var value = Math.floor(root.finiteNumber(minutes, -1))
    if (value < 0) return "--"
    var hours = Math.floor(value / 60)
    var rest = value % 60
    if (hours <= 0) return rest + " min"
    return hours + " h " + (rest < 10 ? "0" : "") + rest + " min"
  }

  function speedLabel() {
    var labels = ["UNKNOWN", "SILENT", "STANDARD", "SPORT", "LUDICROUS"]
    var level = Math.floor(root.finiteNumber(root.speedLevel, 0))
    var label = level >= 1 && level <= 4 ? labels[level] : "CUSTOM"
    return label + (root.speedMagnitude > 0 ? " · " + root.speedMagnitude + "%" : "")
  }

  function formatFan(value) {
    var level = root.finiteNumber(value, NaN)
    if (!isFinite(level)) return "--"
    return Math.round(Math.max(0, Math.min(15, level)) / 15 * 100) + "%"
  }

  function formatLastUpdate() {
    if (!root.lastUpdate) return "--"
    var timestamp = new Date(root.lastUpdate)
    return isNaN(timestamp.getTime()) ? root.lastUpdate
      : Qt.formatDateTime(timestamp, "HH:mm:ss")
  }

  function formatDimensions() {
    var bounds = root.activeBounds || ({})
    var width = root.finiteNumber(bounds.maxX, NaN) - root.finiteNumber(bounds.minX, NaN)
    var depth = root.finiteNumber(bounds.maxY, NaN) - root.finiteNumber(bounds.minY, NaN)
    var height = root.finiteNumber(bounds.maxZ, NaN) - root.finiteNumber(bounds.minZ, NaN)
    if (![width, depth, height].every(function(value) { return isFinite(value) && value >= 0 }))
      return "--"
    return width.toFixed(1) + " × " + depth.toFixed(1) + " × " + height.toFixed(1) + " mm"
  }

  function compactLabel() {
    if (!root.hasConnectionTarget) return "SETUP"
    if (!root.connectionVerified) return "WAIT"
    var state = root.connected ? root.displayGcodeState : "OFFLINE"
    return state + " " + root.percent + "% "
      + root.formatTemp(root.nozzleTemp) + "/" + root.formatTemp(root.bedTemp)
  }

  function configuration() {
    return {
      "host": root.host, "mqttPort": root.mqttPort,
      "ftpsPort": root.ftpsPort, "serial": root.serial,
      "username": root.username, "maxSegments": root.segmentLimit(),
      "mqttTlsFingerprint": root.mqttTlsFingerprint,
      "ftpsTlsFingerprint": root.ftpsTlsFingerprint
    }
  }

  function configurationForDraft(draft) {
    return {
      "host": String(draft.host || ""), "mqttPort": Number(draft.mqttPort),
      "ftpsPort": Number(draft.ftpsPort), "serial": String(draft.serial || ""),
      "username": String(draft.username || ""), "maxSegments": Number(draft.maxSegments),
      "mqttTlsFingerprint": String(draft.mqttTlsFingerprint || ""),
      "ftpsTlsFingerprint": String(draft.ftpsTlsFingerprint || "")
    }
  }

  function reportProcessError(message) {
    processError = String(message || "")
    processErrorReportUpdate = processError === "" ? "" : lastUpdate
  }

  function writeCommand(command) {
    if (!daemonReady || !sessionProcess.running) return false
    try {
      sessionProcess.write(JSON.stringify(command) + "\n")
      return true
    } catch (error) {
      reportProcessError("Backend command failed")
      return false
    }
  }

  function sendConfiguration(draft) {
    if (!daemonReady || !root.hasConnectionTarget) return
    var config = draft && typeof draft === "object"
      ? configurationForDraft(draft) : configuration()
    writeCommand({ "op": "configure", "protocol": 1, "config": config })
  }

  function setSecret(value) {
    var replacement = String(value || "")
    if (!replacement) return false
    return writeCommand({
      "op": "set_secret", "accessCode": replacement, "persist": true
    })
  }

  function clearSecret() {
    if (writeCommand({ "op": "clear_secret" })) settingsView.clearAccessCode()
  }

  function requestDisconnect() {
    if (!root.hasConnectionTarget && !root.hasUsableSecret) return
    root.disconnectConfirmationOpen = true
  }

  function failDisconnect(message) {
    root.disconnectPending = false
    root.viewMode = "settings"
    settingsView.reportError(message)
    root.popupOpen = true
  }

  function confirmDisconnect() {
    root.disconnectConfirmationOpen = false
    if (!root.daemonReady || !sessionProcess.running) {
      settingsView.reportError("Backend is not ready to disconnect the printer")
      return
    }
    root.disconnectRequestId = (root.disconnectRequestId + 1) % 2147483647
    root.disconnectPending = true
    if (!root.writeCommand({
      "op": "clear_secret", "requestId": root.disconnectRequestId
    })) {
      root.failDisconnect("Printer could not be disconnected")
    }
  }

  function completeDisconnect() {
    if (!root.disconnectPending) return
    var reset = {
      printerName: root.printerName,
      host: "",
      mqttPort: 8883,
      ftpsPort: 990,
      serial: "",
      username: "bblp",
      maxSegments: root.segmentLimit(),
      explosionFactor: root.explosionFactor,
      autoRotate: root.autoRotate,
      showBarSummary: root.showBarSummary,
      mqttTlsFingerprint: "",
      ftpsTlsFingerprint: "",
      installationId: ""
    }
    if (!root.persistSettings(reset)) {
      root.failDisconnect("Disconnected, but Omarchy Shell could not reset the settings")
      return
    }
    root.disconnectPending = false
    root.pendingSecretWrite = false
    root.tlsRejected = false
    root.resetOperationalState()
    settingsView.load(reset)
    root.viewMode = "setup"
    root.popupOpen = true
    root.focusPanelTop()
  }

  function refreshModel() {
    writeCommand({ "op": "refresh_model" })
  }

  function consumeStdoutChunk(chunk) {
    consumeStreamChunk(chunk, true)
  }

  function resetStreamBuffers() {
    stdoutBuffer = ""
    stdoutDiscarding = false
    stderrBuffer = ""
    stderrDiscarding = false
  }

  function handleProcessRunningChanged() {
    if (sessionProcess.running) {
      restartScheduled = false
      return
    }
    daemonReady = false
    resetOperationalState()
    if (root.disconnectPending) {
      root.failDisconnect("Backend stopped before disconnecting the printer")
    }
    resetStreamBuffers()
    recoverSecretWrite("Backend stopped before accepting the LAN code. Enter it again")
    if (restartScheduled) return
    restartScheduled = true
    sessionRestart.interval = restartDelay
    restartDelay = Math.min(60000, restartDelay * 2)
    sessionRestart.restart()
  }

  function consumeStderrChunk(chunk) {
    consumeStreamChunk(chunk, false)
  }

  function consumeStreamChunk(chunk, stdoutStream) {
    var buffer = stdoutStream ? stdoutBuffer : stderrBuffer
    var discarding = stdoutStream ? stdoutDiscarding : stderrDiscarding
    var text = String(chunk === null || chunk === undefined ? "" : chunk)
    var offset = 0
    while (offset < text.length) {
      var newlineIndex = text.indexOf("\n", offset)
      var end = newlineIndex < 0 ? text.length : newlineIndex
      var part = text.slice(offset, end)
      if (!discarding) {
        if (buffer.length + part.length > root.maxIpcLineChars) {
          buffer = ""
          discarding = true
        } else {
          buffer += part
        }
      }
      if (newlineIndex < 0) break
      if (!discarding) {
        var line = buffer.endsWith("\r") ? buffer.slice(0, -1) : buffer
        if (stdoutStream) handleLine(line)
        else handleErrorLine(line)
      }
      buffer = ""
      discarding = false
      offset = newlineIndex + 1
    }
    if (stdoutStream) {
      stdoutBuffer = buffer
      stdoutDiscarding = discarding
    } else {
      stderrBuffer = buffer
      stderrDiscarding = discarding
    }
  }

  function handleErrorLine(line) {
    var message = String(line || "").trim()
    if (message) reportProcessError(message)
  }

  function handleState(message) {
    message = objectOrEmpty(message)
    var printer = objectOrEmpty(message.printer)
    var model = objectOrEmpty(message.model)
    var nextGeneration = isNonNegativeInteger(model.generation) ? model.generation : -1
    if (nextGeneration !== modelGeneration) {
      geometryBundle = ({})
      selectedGeometrySource = "gcode"
      resetPendingGeometry()
      modelGeneration = nextGeneration
    }
    connected = printer.connected === true
    stale = printer.stale !== false
    var reportUpdate = String(printer.lastUpdate || "")
    var hasFreshReport = connected && printer.stale === false
      && reportUpdate !== ""
    if (hasFreshReport) {
      connectionVerified = true
      if (processError !== "" && reportUpdate !== processErrorReportUpdate) {
        processError = ""
        processErrorReportUpdate = ""
      }
      if (root.viewMode === "connecting") viewMode = "status"
    }
    gcodeState = String(printer.gcodeState || (connected ? "IDLE" : "OFFLINE"))
    subtaskName = String(printer.subtaskName || "")
    percent = Math.max(0, Math.min(100, Math.floor(finiteNumber(printer.percent, 0))))
    nozzleTemp = finiteNumber(printer.nozzleTemp, NaN)
    nozzleTargetTemp = finiteNumber(printer.nozzleTargetTemp, NaN)
    bedTemp = finiteNumber(printer.bedTemp, NaN)
    bedTargetTemp = finiteNumber(printer.bedTargetTemp, NaN)
    currentLayer = Math.max(0, Math.floor(finiteNumber(printer.layer, 0)))
    totalLayers = Math.max(0, Math.floor(finiteNumber(printer.totalLayers, 0)))
    remainingMinutes = Math.floor(finiteNumber(printer.remainingMinutes, -1))
    speedLevel = Math.max(0, Math.floor(finiteNumber(printer.speedLevel, 0)))
    speedMagnitude = Math.max(0, Math.floor(finiteNumber(printer.speedMagnitude, 0)))
    wifiSignal = String(printer.wifiSignal || "")
    coolingFanSpeed = finiteNumber(printer.coolingFanSpeed, NaN)
    heatbreakFanSpeed = finiteNumber(printer.heatbreakFanSpeed, NaN)
    lastUpdate = reportUpdate
    modelStatus = String(model.status || "idle")
    zCurrent = finiteNumber(model.zCurrent, NaN)
    zMode = String(model.zMode || "unknown")
    var error = objectOrEmpty(model.error)
    modelErrorCode = error.code === null || error.code === undefined
      ? "" : String(error.code)
    modelError = error.message === null || error.message === undefined
      ? "" : String(error.message)
    if (modelErrorCode === "certificate_changed") {
      handleTlsMismatch("FTPS certificate changed. Check and approve the printer again.")
    }
  }

  function resetPendingGeometry() {
    pendingGeometry = ({})
  }

  function resetOperationalState() {
    finishReadyTimer.stop()
    finishGraceExpired = false
    connected = false
    connectionVerified = false
    stale = true
    gcodeState = "OFFLINE"
    subtaskName = ""
    percent = 0
    nozzleTemp = NaN
    nozzleTargetTemp = NaN
    bedTemp = NaN
    bedTargetTemp = NaN
    currentLayer = 0
    totalLayers = 0
    remainingMinutes = -1
    speedLevel = 0
    speedMagnitude = 0
    wifiSignal = ""
    coolingFanSpeed = NaN
    heatbreakFanSpeed = NaN
    lastUpdate = ""
    modelStatus = "idle"
    modelErrorCode = ""
    modelError = ""
    zCurrent = NaN
    zMode = "unknown"
    processError = ""
    processErrorReportUpdate = ""
    secretRequired = false
    secretStored = false
    secretStatusKnown = false
    clearTlsProbeState()
    modelGeneration = -1
    geometryBundle = ({})
    selectedGeometrySource = "gcode"
    resetPendingGeometry()
    if (root.viewMode !== "settings"
        && (root.viewMode !== "setup" || root.hasConnectionTarget)) {
      viewMode = nextIdleView()
    }
  }

  function handleGeometry(message) {
    message = objectOrEmpty(message)
    var event = String(message.event || "")
    if (!isNonNegativeInteger(message.generation)) return
    var generation = message.generation
    if (generation !== modelGeneration) return
    if (event === "geometry_begin") beginGeometry(message, generation)
    else if (event === "geometry_chunk") appendGeometryChunk(message, generation)
    else if (event === "geometry_preview_chunk") appendPreviewChunk(message, generation)
    else if (event === "geometry_end") finishGeometry(message, generation)
  }

  function beginGeometry(message, generation) {
    if (!isNonNegativeInteger(message.segmentCount)
        || message.segmentCount > root.segmentLimit()) {
      resetPendingGeometry()
      return
    }
    var hasGcode = message.gcode !== null && message.gcode !== undefined
    var hasPreview = message.preview !== null && message.preview !== undefined
    var gcode = objectOrEmpty(message.gcode)
    if (hasGcode && (!isNonNegativeInteger(gcode.segmentCount)
        || gcode.segmentCount < 1 || gcode.segmentCount !== message.segmentCount)) {
      resetPendingGeometry()
      return
    }
    if (!hasGcode && message.segmentCount !== 0) {
      resetPendingGeometry()
      return
    }
    if (hasPreview && !validPreview(message.preview)) {
      resetPendingGeometry()
      return
    }
    if (!hasGcode && !hasPreview) {
      resetPendingGeometry()
      return
    }
    pendingGeometry = {
      generation: generation,
      gcode: hasGcode ? {
        expectedSegments: gcode.segmentCount,
        bounds: objectOrEmpty(gcode.bounds),
        segments: [],
        nextChunk: 0
      } : null,
      preview: hasPreview ? {
        byteCount: message.preview.byteCount,
        encodedLength: message.preview.encodedLength,
        width: message.preview.width,
        height: message.preview.height,
        parts: [],
        receivedLength: 0,
        nextChunk: 0
      } : null
    }
  }

  function appendGeometryChunk(message, generation) {
    var transaction = objectOrEmpty(pendingGeometry)
    if (generation !== transaction.generation) return
    var slot = transaction.gcode
    if (message.source !== "gcode" || !slot) {
      resetPendingGeometry()
      return
    }
    var chunk = message.segments
    if (!isNonNegativeInteger(message.index)
        || message.index !== slot.nextChunk || !Array.isArray(chunk)
        || chunk.length === 0
        || slot.segments.length + chunk.length > slot.expectedSegments) {
      resetPendingGeometry()
      return
    }
    for (var segmentIndex = 0; segmentIndex < chunk.length; segmentIndex++) {
      if (!isValidSegment(chunk[segmentIndex])) {
        resetPendingGeometry()
        return
      }
    }
    slot.segments = slot.segments.concat(chunk)
    slot.nextChunk += 1
  }

  function appendPreviewChunk(message, generation) {
    var transaction = objectOrEmpty(pendingGeometry)
    if (generation !== transaction.generation) return
    var slot = transaction.preview
    var data = message.data
    if (message.source !== "preview" || !slot
        || !isNonNegativeInteger(message.index)
        || message.index !== slot.nextChunk
        || typeof data !== "string" || data.length < 1
        || data.length > root.maxPreviewChunkChars
        || slot.receivedLength + data.length > slot.encodedLength
        || !/^[A-Za-z0-9+/]+={0,2}$/.test(data)
        || (data.indexOf("=") >= 0
          && slot.receivedLength + data.length !== slot.encodedLength)) {
      resetPendingGeometry()
      return
    }
    slot.parts.push(data)
    slot.receivedLength += data.length
    slot.nextChunk += 1
  }

  function finishGeometry(message, generation) {
    var transaction = objectOrEmpty(pendingGeometry)
    if (generation !== transaction.generation) return
    var expected = []
    if (transaction.gcode) expected.push("gcode")
    if (transaction.preview) expected.push("preview")
    var announced = message.sources
    var chunks = objectOrEmpty(message.chunks)
    var expectedChunkKeys = expected.length
    if (!Array.isArray(announced) || announced.length !== expected.length
        || Object.keys(chunks).length !== expectedChunkKeys) {
      resetPendingGeometry()
      return
    }
    for (var index = 0; index < expected.length; index++) {
      if (announced[index] !== expected[index]) {
        resetPendingGeometry()
        return
      }
    }
    var slot = transaction.gcode
    if (slot && (!isNonNegativeInteger(chunks.gcode)
        || slot.segments.length !== slot.expectedSegments
        || slot.nextChunk !== chunks.gcode)) {
      resetPendingGeometry()
      return
    }
    var preview = transaction.preview
    if (preview && (!isNonNegativeInteger(chunks.preview)
        || preview.nextChunk !== chunks.preview
        || preview.receivedLength !== preview.encodedLength)) {
      resetPendingGeometry()
      return
    }
    var nextBundle = ({})
    if (slot) nextBundle.gcode = {
      segments: slot.segments.slice(0), bounds: slot.bounds
    }
    if (preview) {
      var encoded = preview.parts.join("")
      var expectedPadding = preview.byteCount % 3 === 0
        ? 0 : 3 - preview.byteCount % 3
      var suffix = expectedPadding === 0 ? ""
        : (expectedPadding === 1 ? "=" : "==")
      if (!encoded.endsWith(suffix)
          || (expectedPadding > 0
            && encoded[encoded.length - expectedPadding - 1] === "=")) {
        resetPendingGeometry()
        return
      }
      nextBundle.preview = {
        url: "data:image/png;base64," + encoded,
        width: preview.width,
        height: preview.height
      }
    }
    geometryBundle = nextBundle
    selectedGeometrySource = nextBundle.gcode ? "gcode" : "preview"
    resetPendingGeometry()
  }

  function handleLine(line) {
    var message
    try {
      message = JSON.parse(String(line || ""))
    } catch (error) {
      return
    }
    if (!message || typeof message !== "object" || Array.isArray(message)) return
    if (message.event === "hello") {
      daemonReady = Number(message.protocol) === 1
      installationId = String(message.installationId || "")
      installationIdentified = installationId !== ""
      resetPendingGeometry()
      if (!daemonReady || !installationIdentified) {
        resetOperationalState()
        processError = "Unsupported backend protocol"
        return
      }
      restartDelay = 1000
      processError = ""
      processErrorReportUpdate = ""
      if (root.requiresSetupConfirmation) {
        viewMode = "setup"
        if (componentReady) settingsView.load(settingsDraft())
        sendConfiguration()
        return
      }
      sendConfiguration()
      return
    }
    if (!daemonReady) return
    if (message.event === "secret_required") {
      if (root.disconnectPending
          && message.requestId === root.disconnectRequestId) {
        root.completeDisconnect()
        return
      }
      secretRequired = true
      secretStored = false
      secretStatusKnown = false
      if (!root.pendingSecretWrite && root.viewMode === "connecting") {
        openSettings()
        settingsView.reportError("Enter the LAN access code to connect")
      }
    } else if (message.event === "secret_status") {
      pendingSecretWrite = false
      if (root.disconnectPending
          && message.requestId === root.disconnectRequestId
          && message.stored === false) {
        root.completeDisconnect()
        return
      }
      secretRequired = false
      secretStored = message.stored === true
      secretStatusKnown = true
    } else if (message.event === "tls_required") {
      tlsRejected = !root.hasTrustedTlsPins
      openSettings()
      settingsView.reportError("Approve the printer certificate before connecting")
      popupOpen = true
    } else if (message.event === "tls_identity") {
      if (message.requestId !== root.tlsProbeRequestId) return
      var mqttIdentity = objectOrEmpty(message.mqtt)
      var ftpsIdentity = objectOrEmpty(message.ftps)
      if (!root.validTlsFingerprint(mqttIdentity.fingerprint)
          || !root.validTlsFingerprint(ftpsIdentity.fingerprint)) {
        root.clearTlsProbeState()
        settingsView.reportError("Printer returned an invalid certificate identity")
        return
      }
      root.tlsProbePending = false
      root.tlsApprovalRequired = true
      root.mqttTlsIdentity = mqttIdentity
      root.ftpsTlsIdentity = ftpsIdentity
      settingsView.reportError("")
    } else if (message.event === "state") {
      handleState(message)
    } else if (String(message.event || "").indexOf("geometry_") === 0) {
      handleGeometry(message)
    } else if (message.event === "error") {
      if (root.disconnectPending
          && message.requestId === root.disconnectRequestId
          && message.scope === "secret") {
        if (message.code === "clear_failed") {
          root.failDisconnect("LAN access code could not be removed")
        } else {
          root.failDisconnect("Printer could not be disconnected")
        }
        Qt.callLater(root.sendConfiguration)
        return
      }
      if (message.scope === "tls" && message.code === "probe_failed") {
        if (message.requestId !== root.tlsProbeRequestId) return
        root.clearTlsProbeState()
        settingsView.reportError("Unable to read the printer certificate")
        return
      }
      reportProcessError(message.message)
      if (message.scope === "tls" && message.code === "certificate_changed") {
        handleTlsMismatch("Printer certificate changed. Check it before reconnecting.")
      } else if (message.scope === "mqtt" && message.code === "authentication") {
        handleAuthenticationFailure("LAN access code was rejected. Enter it again")
      } else {
        recoverSecretWrite("LAN code was rejected. Enter it again")
      }
    }
  }

  onPopupOpenChanged: {
    if (!componentReady) return
    if (!popupOpen) {
      root.cancelSecurityModal()
      settingsView.clearAccessCode()
      viewMode = nextIdleView()
    }
  }
  onGcodeStateChanged: {
    if (root.isFinishedState(root.gcodeState)) {
      if (!finishReadyTimer.running && !root.finishGraceExpired)
        finishReadyTimer.start()
      return
    }
    finishReadyTimer.stop()
    finishGraceExpired = false
  }
  onBackendConfigurationFingerprintChanged: {
    if (!componentReady || persistingSettings) return
    resetOperationalState()
    sendConfiguration()
  }
  Component.onCompleted: {
    componentReady = true
    Qt.callLater(root.resolveInitialView)
  }
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: sessionProcess
    command: [root.backendPath]
    stdinEnabled: true
    running: true
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { root.consumeStdoutChunk(chunk) }
    }
    stderr: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { root.consumeStderrChunk(chunk) }
    }
    onRunningChanged: root.handleProcessRunningChanged()
  }

  Timer {
    id: finishReadyTimer
    interval: 60000
    repeat: false
    onTriggered: {
      if (root.isFinishedState(root.gcodeState))
        root.finishGraceExpired = true
    }
  }

  Timer {
    id: sessionRestart
    interval: 1000
    repeat: false
    onTriggered: {
      root.restartScheduled = false
      if (!sessionProcess.running) sessionProcess.running = true
    }
  }

  component PrinterIcon: Item {
    id: iconRoot

    property color tintColor: root.foreground

    implicitWidth: Style.bar.iconCanvas
    implicitHeight: Style.bar.iconCanvas

    Image {
      id: printerIconImage
      anchors.fill: parent
      source: root.printerIconSource
      fillMode: Image.PreserveAspectFit
      visible: false
      layer.enabled: true
    }

    MultiEffect {
      anchors.fill: printerIconImage
      source: printerIconImage
      colorization: 1.0
      colorizationColor: iconRoot.tintColor
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    labelVisible: false
    hasVisualContent: true
    fixedWidth: root.vertical ? barSize : buttonContent.implicitWidth + scaledHorizontalMargin * 2
    fixedHeight: barSize
    foreground: root.foreground
    activeColor: root.accent
    active: root.popupOpen
    fontFamily: root.fontFamily
    fontSize: Style.font.caption
    tooltipText: root.displayName + " · "
      + (!root.hasConnectionTarget ? "SETUP"
        : (!root.connectionVerified ? "CONNECTING"
          : ((root.connected ? root.displayGcodeState : "OFFLINE") + " · " + root.percent + "% · "
            + root.formatTemp(root.nozzleTemp) + "/" + root.formatTemp(root.bedTemp))))
    onPressed: {
      if (root.popupOpen) root.close()
      else root.open()
    }

    Row {
      id: buttonContent
      anchors.centerIn: parent
      height: button.fixedHeight
      spacing: Style.space(5)

      PrinterIcon {
        anchors.verticalCenter: parent.verticalCenter
        tintColor: root.printerIconColor
      }

      Text {
        height: parent.height
        verticalAlignment: Text.AlignVCenter
        visible: !root.vertical && root.showBarSummary
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
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.popupOpen
    focusTarget: keyCatcher
    padding: 0
    contentWidth: fittedContentWidth(Style.space(860))
    contentHeight: fittedContentHeight(Style.space(520), Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      clip: true
      blocked: settingsView.inputActive || root.securityModalMode !== ""

      Rectangle {
        id: panelBackdrop
        anchors.fill: parent
        readonly property color baseColor: Color.popups.background
        color: Qt.rgba(
          baseColor.r * 0.94 + root.foreground.r * 0.06,
          baseColor.g * 0.94 + root.foreground.g * 0.06,
          baseColor.b * 0.94 + root.foreground.b * 0.06,
          1.0)
        border.width: 1
        border.color: Qt.rgba(root.foreground.r, root.foreground.g,
                              root.foreground.b, 0.18)
      }

      onCloseRequested: {
        if (root.securityModalMode !== "") root.cancelSecurityModal()
        else if (root.viewMode === "settings" && root.hasConnectionTarget
            && !root.requiresSetupConfirmation) root.backToStatus()
        else root.close()
      }

      Flickable {
        id: panelScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: dashboard.height
        flickableDirection: Flickable.VerticalFlick
        boundsBehavior: Flickable.StopAtBounds
        interactive: !dashboard.wideLayout
        clip: true

        Item {
          id: dashboard
          width: panelScroll.width
          height: wideLayout ? panelScroll.height
            : telemetryPane.height + dashboardLayout.spacing + modelPane.height
          readonly property bool wideLayout: width >= Style.space(640)
          readonly property real overlayX: wideLayout
            ? telemetryPane.width + dashboardLayout.spacing : 0
          readonly property real overlayY: wideLayout ? 0 : panelScroll.contentY
          readonly property real overlayWidth: wideLayout
            ? Math.max(0, width - overlayX) : width
          readonly property real overlayHeight: panelScroll.height

          Grid {
            id: dashboardLayout
            anchors.fill: parent
            columns: dashboard.wideLayout ? 2 : 1
            spacing: 1

            BambuTelemetryPane {
              id: telemetryPane
              width: dashboard.wideLayout
                ? Style.space(300)
                : dashboard.width
              height: dashboard.wideLayout ? dashboard.height : Style.space(500)
              foreground: root.foreground
              accent: root.accent
              dim: root.dim
              successColor: root.successColor
              errorColor: root.errorColor
              errorActive: root.errorActive
              modelErrorActive: root.modelErrorActive
              fontFamily: root.fontFamily
              printerIconSource: root.printerIconSource
              printerName: root.displayName
              online: root.connected && !root.stale
              printerState: root.displayGcodeState
              jobName: root.subtaskName || "NO ACTIVE PRINT"
              percent: root.percent
              remainingValue: root.formatDuration(root.remainingMinutes)
              nozzleValue: root.formatTempPair(root.nozzleTemp, root.nozzleTargetTemp)
              bedValue: root.formatTempPair(root.bedTemp, root.bedTargetTemp)
              layerValue: (root.currentLayer || "--") + " / " + (root.totalLayers || "--")
              zValue: isFinite(root.zCurrent) ? root.zCurrent.toFixed(2) + " mm"
                + (root.zMode === "estimated" ? " EST." : "") : "--"
              speedValue: root.speedLabel()
              fanValue: "PART " + root.formatFan(root.coolingFanSpeed)
                + " · HOTEND " + root.formatFan(root.heatbreakFanSpeed)
              hostValue: root.host || "--"
              portsValue: "MQTT " + root.mqttPort + " · FTPS " + root.ftpsPort
              wifiValue: root.wifiSignal || "--"
              reportValue: root.formatLastUpdate()
              segmentValue: root.activeSegments.length.toLocaleString(Qt.locale(), "f", 0)
                + " SEGMENTS"
              modelState: root.modelStatus.toUpperCase()
              dimensionsValue: root.formatDimensions()
              onSettingsRequested: root.toggleSettings()
            }

            BambuModelViewport {
              id: modelPane
              width: dashboard.wideLayout
                ? Math.max(0, dashboard.width - telemetryPane.width - dashboardLayout.spacing)
                : dashboard.width
              height: dashboard.wideLayout ? dashboard.height : Style.space(500)
              foreground: root.foreground
              accent: root.accent
              dim: root.dim
              errorColor: root.errorColor
              errorActive: root.errorActive || root.modelErrorActive
              fontFamily: root.fontFamily
              panelActive: root.popupOpen && root.viewMode === "status"
              daemonReady: root.daemonReady && sessionProcess.running
              printing: root.connected && root.gcodeState === "RUNNING"
              previewAvailable: root.previewAvailable
              gcodeAvailable: root.gcodeGeometryAvailable
              selectedSource: root.selectedGeometrySource
              previewSource: root.previewAvailable
                ? root.geometryBundle.preview.url : ""
              activeSegments: root.activeSegments
              activeBounds: root.activeBounds
              zCurrent: root.zCurrent
              autoRotateDefault: root.autoRotate
              explosionFactor: root.explosionFactor
              modelStatus: root.modelStatus
              modelError: root.modelError || root.processError
              onSourceRequested: function(source) {
                root.selectGeometrySource(source)
              }
              onReloadRequested: root.refreshModel()
            }
          }

          Rectangle {
            visible: dashboard.wideLayout
            x: telemetryPane.width
            y: 0
            width: 1
            height: dashboard.height
            color: Qt.rgba(root.foreground.r, root.foreground.g,
                           root.foreground.b, 0.12)
          }

          Rectangle {
            visible: root.viewMode === "setup" || root.viewMode === "settings"
            x: dashboard.overlayX
            y: dashboard.overlayY
            width: dashboard.overlayWidth
            height: dashboard.overlayHeight
            z: 20
            color: panelBackdrop.color
          }

          BambuSettingsView {
            id: settingsView
            visible: root.viewMode === "setup" || root.viewMode === "settings"
            x: dashboard.overlayX
            y: dashboard.overlayY
            width: dashboard.overlayWidth
            height: dashboard.overlayHeight
            z: 21
            foreground: root.foreground
            accent: root.accent
            errorColor: root.errorColor
            dim: root.dim
            fontFamily: root.fontFamily
            daemonReady: root.daemonReady && sessionProcess.running
            allowBack: true
            canDisconnect: root.hasConnectionTarget || root.hasUsableSecret
            requireAccessCode: !root.hasUsableSecret
            secretRequired: root.secretRequired
            secretStored: root.secretStored
            secretStatusKnown: root.secretStatusKnown
            onBackRequested: {
              if (root.requiresSetupConfirmation) root.close()
              else root.backToStatus()
            }
            onBarSummaryToggled: function(enabled) {
              if (!root.persistBarSummary(enabled)) {
                settingsView.showBarSummary = root.showBarSummary
                settingsView.reportError("Bar summary setting could not be saved")
              }
            }
            onForgetCodeRequested: root.clearSecret()
            onDisconnectRequested: root.requestDisconnect()
            onInputFocusReleased: keyCatcher.forceActiveFocus()
            onSaveRequested: function(draft, accessCode) {
              root.saveSettings(draft, accessCode)
            }
            onTrustRequested: function(draft, accessCode) {
              root.trustAndConnect(draft, accessCode)
            }
          }

          Item {
            visible: root.viewMode === "connecting"
            x: dashboard.overlayX
            y: dashboard.overlayY
            width: dashboard.overlayWidth
            height: dashboard.overlayHeight
            z: 22

            Rectangle {
              anchors.fill: parent
              color: panelBackdrop.color
            }

            Column {
              anchors.centerIn: parent
              width: Math.min(parent.width - Style.space(32), Style.space(320))
              spacing: Style.space(10)

              Item {
                width: Style.space(48)
                height: width
                anchors.horizontalCenter: parent.horizontalCenter

                PrinterIcon {
                  anchors.fill: parent
                  tintColor: root.foreground
                }

                RotationAnimator on rotation {
                  from: 0
                  to: 360
                  duration: 900
                  loops: Animation.Infinite
                  running: root.popupOpen && root.viewMode === "connecting"
                }
              }

              Text {
                width: parent.width
                text: "CONNECTING TO " + root.displayName.toUpperCase()
                color: root.foreground
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }

              Text {
                width: parent.width
                text: root.processError || "Waiting for a fresh printer report…"
                color: root.processError ? root.errorColor : root.dim
                wrapMode: Text.Wrap
                horizontalAlignment: Text.AlignHCenter
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              BambuButton {
                width: parent.width
                height: Style.space(34)
                clip: true
                text: "EDIT CONFIGURATION"
                foreground: root.foreground
                accent: root.accent
                bordered: true
                onClicked: root.openSettings()
              }
            }
          }

          BambuButton {
            visible: root.secretRequired && root.viewMode === "status"
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.space(54)
            z: 24
            width: Math.min(parent.width - Style.space(24), Style.space(320))
            text: "ENTER LAN CODE IN SETTINGS"
            foreground: root.foreground
            accent: root.accent
            bordered: true
            onClicked: root.openSettings()
          }
        }
      }

      BambuSecurityDialog {
        anchors.fill: parent
        z: 40
        mode: root.securityModalMode
        probing: root.tlsProbePending
        processing: root.disconnectPending
        mqttIdentity: root.mqttTlsIdentity
        ftpsIdentity: root.ftpsTlsIdentity
        foreground: root.foreground
        accent: root.accent
        errorColor: root.errorColor
        background: panelBackdrop.color
        fontFamily: root.fontFamily
        onCancelRequested: root.cancelSecurityModal()
        onTrustRequested: settingsView.submit(true)
        onDisconnectRequested: root.confirmDisconnect()
      }
    }
  }
}
