# frozen_string_literal: true

require_relative "test_helper"
require "json"

class QmlContractTest < Minitest::Test
  def setup
    @root = File.expand_path("..", __dir__)
    @source = File.read(File.join(@root, "BambuWidget.qml"))
    @settings_source = File.read(File.join(@root, "BambuSettingsView.qml"))
    @telemetry_source = File.read(File.join(@root, "BambuTelemetryPane.qml"))
    @viewport_source = File.read(File.join(@root, "BambuModelViewport.qml"))
    @button_source = File.read(File.join(@root, "BambuButton.qml"))
  end

  def test_button_wrapper_exposes_only_options_used_by_the_plugin
    refute_match(/property bool selected:/, @button_source)
    refute_match(/property bool focusable:/, @button_source)
    assert_match(/^\s*selected: false$/m, @button_source)
    assert_match(/^\s*focusable: false$/m, @button_source)
  end

  def test_widget_does_not_keep_unused_panel_margin_state
    refute_includes @source, "panelHorizontalMargin"
  end

  def test_quattro_widget_and_process_contract
    assert_includes @source, "BarWidget {"
    assert_includes @source, 'moduleName: "io.github.ypmrg.bambu-companion"'
    assert_match(/function open\(\)/, @source)
    assert_match(/function close\(\)/, @source)
    assert_includes @source, "readonly property bool opened"
    assert_includes @source, "Process {"
    assert_includes @source, "stdout: SplitParser"
    assert_includes @source, "stdinEnabled: true"
    assert_includes @source, "command: [root.backendPath]"
    assert_includes @source, "implicitWidth: button.implicitWidth"
    assert_includes @source, "implicitHeight: button.implicitHeight"
    assert_match(/restartDelay = Math\.min\(60000, restartDelay \* 2\)/, @source)
    assert_includes @source, "sessionRestart.restart()"
  end

  def test_widget_does_not_override_qquickitem_final_layer_property
    refute_match(/^\s*property\s+\w+\s+layer\s*:/, @source)
    assert_includes @source, "property int currentLayer: 0"
    assert_match(/currentLayer = Math\.max\(0, Math\.floor\(finiteNumber\(printer\.layer, 0\)\)\)/,
                 @source)
    assert_match(/layerValue:\s*\(root\.currentLayer \|\| "--"\) \+ " \/ " \+ \(root\.totalLayers \|\| "--"\)/,
                 @source)
  end

  def test_process_lifecycle_resets_state_and_schedules_one_restart
    assert_includes @source, "property bool restartScheduled: false"
    assert_includes @source, "function resetStreamBuffers()"
    assert_match(/function handleProcessRunningChanged\(\).*if \(sessionProcess\.running\).*restartScheduled = false.*return.*daemonReady = false.*resetOperationalState\(\).*resetStreamBuffers\(\).*recoverSecretWrite\(.*\).*if \(restartScheduled\) return.*restartScheduled = true.*sessionRestart\.restart\(\)/m,
                 @source)
    assert_includes @source, "onRunningChanged: root.handleProcessRunningChanged()"
    refute_includes @source, "onExited:"
    assert_match(/onTriggered:.*root\.restartScheduled = false.*sessionProcess\.running = true/m,
                 @source)
  end

  def test_finished_status_settles_to_ready_after_one_minute
    assert_includes @source, "property bool finishGraceExpired: false"
    assert_match(/function isFinishedState\(state\).*FINISH.*FINISHED.*COMPLETE.*COMPLETED/m,
                 @source)
    assert_match(/readonly property string displayGcodeState:.*finishGraceExpired.*isFinishedState\(root\.gcodeState\).*\? "READY" : root\.gcodeState/m,
                 @source)
    assert_match(/onGcodeStateChanged:.*if \(root\.isFinishedState\(root\.gcodeState\)\).*if \(!finishReadyTimer\.running && !root\.finishGraceExpired\).*finishReadyTimer\.start\(\).*return.*finishReadyTimer\.stop\(\).*finishGraceExpired = false/m,
                 @source)
    assert_match(/Timer \{\s*id: finishReadyTimer\s*interval: 60000\s*repeat: false\s*onTriggered:.*if \(root\.isFinishedState\(root\.gcodeState\)\).*root\.finishGraceExpired = true/m,
                 @source)

    assert_match(/function compactLabel\(\).*var state = root\.connected \? root\.displayGcodeState : "OFFLINE"/m,
                 @source)
    assert_match(/tooltipText:.*root\.displayGcodeState/m, @source)
    assert_match(/printerState: root\.displayGcodeState/, @source)
    assert_match(/function resetOperationalState\(\).*finishReadyTimer\.stop\(\).*finishGraceExpired = false/m,
                 @source)
  end

  def test_configuration_is_sent_only_after_hello
    assert_match(/function sendConfiguration\(draft\)\s*{\s*if \(!daemonReady \|\| !root\.hasConnectionTarget\) return/m, @source)
    assert_match(/message\.event === "hello".*daemonReady = Number\(message\.protocol\) === 1.*installationId = String\(message\.installationId \|\| ""\).*sendConfiguration\(\)/m,
                 @source)
    assert_includes @source, '"op": "configure"'
    assert_match(/message\.event === "hello".*if \(!daemonReady \|\| !installationIdentified\).*resetOperationalState\(\).*processError = "Unsupported backend protocol".*return.*restartDelay = 1000.*sendConfiguration\(\).*if \(!daemonReady\) return/m,
                 @source)
  end

  def test_only_backend_configuration_changes_reset_and_reconfigure
    configuration = @source[/function configuration\(\)\s*{.*?\n  }/m]
    refute_nil configuration
    refute_includes configuration, "printerName"
    assert_includes @source,
                    "readonly property string backendConfigurationFingerprint: JSON.stringify(root.configuration())"
    assert_includes @source, "property bool componentReady: false"
    assert_match(/Component\.onCompleted:\s*\{.*componentReady = true.*Qt\.callLater\(root\.resolveInitialView\)/m, @source)
    assert_match(/onPopupOpenChanged:.*if \(!popupOpen\).*settingsView\.clearAccessCode\(\).*viewMode = nextIdleView\(\)/m,
                 @source)
    refute_includes @source, "onSettingsChanged:"
    assert_match(/onBackendConfigurationFingerprintChanged:.*if \(!componentReady \|\| persistingSettings\) return.*resetOperationalState\(\).*sendConfiguration\(\)/m,
                 @source)
    assert_match(/function resetOperationalState\(\).*connected = false.*gcodeState = "OFFLINE".*percent = 0.*nozzleTemp = NaN.*modelError = "".*processError = "".*secretRequired = false.*secretStored = false.*secretStatusKnown = false.*modelGeneration = -1.*geometryBundle = \(\{\}\).*selectedGeometrySource = "gcode".*resetPendingGeometry\(\).*viewMode = nextIdleView\(\)/m,
                 @source)
  end

  def test_raw_process_chunks_are_reassembled_with_a_hard_line_limit
    match = @source.match(/readonly property int maxIpcLineChars:\s*(\d+)/)
    refute_nil match
    assert_operator match[1].to_i, :>=, 262_144
    assert_operator match[1].to_i, :<=, 4_194_304
    assert_includes @source, 'property string stdoutBuffer: ""'
    assert_includes @source, "property bool stdoutDiscarding: false"
    assert_includes @source, 'property string stderrBuffer: ""'
    assert_includes @source, "property bool stderrDiscarding: false"
    assert_includes @source, "function consumeStreamChunk(chunk, stdoutStream)"
    assert_match(/buffer\.length \+ part\.length > root\.maxIpcLineChars.*buffer = "".*discarding = true/m,
                 @source)
    assert_match(/newlineIndex < 0\) break.*if \(!discarding\).*handleLine/m, @source)
    assert_match(/discarding = false.*offset = newlineIndex \+ 1/m, @source)
    assert_equal 2, @source.scan('splitMarker: ""').length
    assert_match(/stdout: SplitParser.*onRead: function\(chunk\) \{ root\.consumeStdoutChunk\(chunk\) \}/m,
                 @source)
    assert_match(/stderr: SplitParser.*onRead: function\(chunk\) \{ root\.consumeStderrChunk\(chunk\) \}/m,
                 @source)
  end

  def test_secret_and_geometry_safety_contract
    refute_match(/command:\s*\[[^\]]*accessCode/m, @source)
    refute_match(/setting\("(?:accessCode|password|secret)"/, @source)
    refute_match(/(?:accessCode|password|secret)\s*[:=]\s*"12345678"/i, @source)
    assert_includes @source, '"op": "set_secret"'
    assert_includes @settings_source, "password: true"
    assert_includes @settings_source, "maximumLength: 256"
    assert_includes @source, "pendingGeometry"
    assert_includes @source, "geometryBundle"
    assert_includes @source, "activeSegments"
    assert_includes @source, "geometry_begin"
    assert_includes @source, "geometry_end"
    assert_includes @source, "nextChunk"
  end

  def test_actions_require_a_ready_process_and_clear_secret_only_after_accepted_write
    assert_match(/function writeCommand\(command\).*if \(!daemonReady \|\| !sessionProcess\.running\) return false.*try.*sessionProcess\.write.*return true.*catch \(error\).*return false/m,
                 @source)
    assert_match(/function setSecret\(value\).*writeCommand\(\{.*"op": "set_secret"/m,
                 @source)
    assert_match(/function clearSecret\(\).*writeCommand\(\{ "op": "clear_secret" \}\)/m,
                 @source)
    assert_match(/function refreshModel\(\)\s*{\s*writeCommand\(\{ "op": "refresh_model" \}\)\s*}/m,
                 @source)
    assert_includes @source, "onReloadRequested: root.refreshModel()"
    assert_match(/BambuModelViewport\s*{.*daemonReady: root\.daemonReady && sessionProcess\.running/m,
                 @source)
    assert_includes @viewport_source, "enabled: viewport.daemonReady"
  end

  def test_geometry_is_transactional_ordered_and_bounded
    assert_includes @source, "function resetPendingGeometry()"
    assert_includes @source, "function isNonNegativeInteger(value)"
    assert_includes @source, "function validPreview(preview)"
    assert_includes @source, "readonly property int maxPreviewBytes: 524288"
    assert_match(/function handleGeometry\(message\).*if \(!isNonNegativeInteger\(message\.generation\)\).*if \(event === "geometry_begin"\)/m,
                 @source)
    assert_includes @source,
                    'else if (event === "geometry_preview_chunk") appendPreviewChunk(message, generation)'
    assert_match(/function beginGeometry\(message, generation\).*message\.segmentCount > root\.segmentLimit\(\).*var hasGcode = message\.gcode !== null.*var hasPreview = message\.preview !== null/m,
                 @source)
    assert_match(/hasGcode.*gcode\.segmentCount !== message\.segmentCount.*hasPreview && !validPreview\(message\.preview\).*if \(!hasGcode && !hasPreview\)/m,
                 @source)
    assert_match(/pendingGeometry = \{.*generation: generation.*gcode: hasGcode.*preview: hasPreview/m,
                 @source)
    assert_match(/function appendGeometryChunk\(message, generation\).*generation !== transaction\.generation.*message\.source !== "gcode".*message\.index !== slot\.nextChunk.*slot\.segments\.length \+ chunk\.length > slot\.expectedSegments/m,
                 @source)
    assert_match(/function finishGeometry\(message, generation\).*Object\.keys\(chunks\)\.length !== expectedChunkKeys.*slot\.segments\.length !== slot\.expectedSegments.*slot\.nextChunk !== chunks\.gcode/m,
                 @source)
    assert_match(/geometryBundle = nextBundle.*selectedGeometrySource = nextBundle\.gcode \? "gcode" : "preview".*resetPendingGeometry\(\)/m,
                 @source)
  end

  def test_geometry_is_scoped_to_the_generation_announced_by_state
    assert_includes @source, "property int modelGeneration: -1"
    assert_match(/function handleState\(message\).*var nextGeneration = isNonNegativeInteger\(model\.generation\).*if \(nextGeneration !== modelGeneration\).*resetPendingGeometry\(\).*modelGeneration = nextGeneration/m,
                 @source)
    assert_match(/if \(nextGeneration !== modelGeneration\).*geometryBundle = \(\{\}\).*selectedGeometrySource = "gcode".*resetPendingGeometry\(\).*modelGeneration = nextGeneration/m,
                 @source)
    assert_match(/function handleGeometry\(message\).*if \(!isNonNegativeInteger\(message\.generation\)\) return.*if \(generation !== modelGeneration\) return.*if \(event === "geometry_begin"\)/m,
                 @source)
  end

  def test_fresh_printer_report_clears_recovered_process_error
    assert_includes @source, 'property string processErrorReportUpdate: ""'
    assert_match(/function reportProcessError\(message\).*processError = String\(message \|\| ""\).*processErrorReportUpdate = processError === "" \? "" : lastUpdate/m,
                 @source)
    assert_match(/var reportUpdate = String\(printer\.lastUpdate \|\| ""\).*if \(hasFreshReport\) \{\s*connectionVerified = true\s*if \(processError !== "" && reportUpdate !== processErrorReportUpdate\) \{\s*processError = ""\s*processErrorReportUpdate = ""/m,
                 @source)
  end

  def test_each_geometry_segment_has_six_finite_numeric_coordinates
    assert_match(/function isValidSegment\(segment\).*Array\.isArray\(segment\).*segment\.length !== 6.*typeof segment\[index\] !== "number".*!isFinite\(segment\[index\]\).*return false.*return true/m,
                 @source)
    assert_match(/function handleGeometry\(message\).*slot\.segments\.length \+ chunk\.length > slot\.expectedSegments.*for \(var segmentIndex = 0; segmentIndex < chunk\.length; segmentIndex\+\+\).*if \(!isValidSegment\(chunk\[segmentIndex\]\)\).*resetPendingGeometry\(\).*return.*slot\.segments = slot\.segments\.concat\(chunk\)/m,
                 @source)
  end

  def test_geometry_source_selection_uses_only_complete_available_sources
    assert_includes @source, 'property string selectedGeometrySource: "gcode"'
    assert_match(/readonly property bool previewAvailable:\s*!!root\.geometryBundle\.preview.*data:image\/png;base64/m,
                 @source)
    assert_match(/readonly property bool gcodeGeometryAvailable:\s*!!root\.geometryBundle\.gcode.*segments\.length > 0/m,
                 @source)
    assert_match(/function selectGeometrySource\(source\).*source === "preview".*previewAvailable.*source === "gcode".*gcodeGeometryAvailable.*selectedGeometrySource = source/m,
                 @source)
    assert_match(/readonly property var activeSegments:.*geometryBundle\.gcode.*segments/m,
                 @source)
    assert_match(/BambuModelViewport\s*\{.*previewAvailable: root\.previewAvailable.*gcodeAvailable: root\.gcodeGeometryAvailable.*selectedSource: root\.selectedGeometrySource.*previewSource: root\.previewAvailable.*onSourceRequested: function\(source\).*root\.selectGeometrySource\(source\)/m,
                 @source)
  end

  def test_state_and_json_line_parsing_are_null_safe
    assert_includes @source, "function objectOrEmpty(value)"
    assert_match(/JSON\.parse.*if \(!message \|\| typeof message !== "object"/m,
                 @source)
    assert_match(/var printer = objectOrEmpty\(message\.printer\)/, @source)
    assert_match(/var model = objectOrEmpty\(message\.model\)/, @source)
  end

  def test_detailed_status_panel_consumes_all_exposed_live_telemetry
    %w[nozzleTargetTemp bedTargetTemp remainingMinutes speedLevel speedMagnitude
       wifiSignal coolingFanSpeed heatbreakFanSpeed lastUpdate].each do |property|
      assert_match(/property\s+\w+\s+#{property}:/, @source)
    end
    %w[nozzleTargetTemp bedTargetTemp remainingMinutes speedLevel speedMagnitude
       wifiSignal coolingFanSpeed heatbreakFanSpeed].each do |field|
      assert_match(/#{field}\s*=.*printer\.#{field}/, @source)
    end
    assert_match(/var reportUpdate = String\(printer\.lastUpdate \|\| ""\).*lastUpdate = reportUpdate/m,
                 @source)
    assert_includes @telemetry_source, 'objectName: "TEMPERATURES"'
    assert_includes @telemetry_source, 'objectName: "PRINT METRICS"'
    assert_includes @telemetry_source, 'objectName: "CONNECTION"'
    assert_includes @telemetry_source, 'objectName: "MODEL DATA"'
  end

  def test_status_panel_is_landscape_and_reflows_before_it_can_overflow
    assert_match(/contentWidth:\s*fittedContentWidth\(Style\.space\(860\)\)/, @source)
    assert_includes @source, "id: dashboardLayout"
    assert_match(/columns:\s*dashboard\.wideLayout \? 2 : 1/, @source)
    assert_match(/readonly property bool wideLayout:\s*width >= Style\.space\(640\)/,
                 @source)
    assert_includes @source, "id: telemetryPane"
    assert_includes @source, "id: modelPane"
    assert_match(/width:\s*dashboard\.wideLayout\s*\? Style\.space\(300\)\s*:\s*dashboard\.width/m,
                 @source)
    assert_match(/width:\s*dashboard\.wideLayout\s*\? Math\.max\(0, dashboard\.width - telemetryPane\.width - dashboardLayout\.spacing\)\s*:\s*dashboard\.width/m,
                 @source)
  end

  def test_original_printer_svg_is_safe_and_symbolic
    path = File.join(@root, "assets", "printer-open-frame.svg")
    assert File.file?(path), "expected an original printer SVG at #{path}"

    svg = File.read(path)
    root_tag = svg[/\A<svg\b[^>]*>/m]
    refute_nil root_tag
    assert_match(/\bxmlns="http:\/\/www\.w3\.org\/2000\/svg"/, root_tag)
    assert_match(/\bviewBox="0 0 24 24"/, root_tag)
    assert_match(/\bfill="none"/, root_tag)
    assert_match(/\bstroke="#ffffff"/i, root_tag)
    refute_match(/\bstroke="(?:black|#000(?:000)?)"/i, root_tag)
    refute_match(/\bstroke="currentColor"/i, root_tag)
    assert_match(/\bstroke-linecap="round"/, root_tag)
    assert_match(/\bstroke-linejoin="round"/, root_tag)
    assert_match(%r{</svg>\s*\z}, svg)
    paths = svg.scan(/<path\b[^>]*>/m)
    assert_operator paths.length, :>=, 4
    paths.each { |tag| assert_match(%r{/\s*>\z}, tag) }
    refute_match(/<(?:script|text|image|foreignObject)\b/i, svg)
    refute_match(/\b(?:href|xlink:href)\s*=|url\s*\(/i, svg)
    refute_match(/bambu|bbl/i, svg)
  end

  def test_symbolic_printer_icon_participates_in_bar_layout
    assert_includes @source, "import QtQuick.Effects"
    assert_includes @source,
                    'readonly property url printerIconSource: Qt.resolvedUrl("assets/printer-open-frame.svg")'
    assert_match(/readonly property color printerIconColor: root\.errorActive \? root\.errorColor\s*: \(!root\.connectionVerified\s*\|\| !root\.connected \|\| root\.stale\s*\? root\.dim : \(root\.gcodeState === "RUNNING" \? root\.neon : root\.foreground\)\)/m,
                 @source)
    assert_includes @source, "component PrinterIcon: Item {"
    assert_match(/Image\s*{.*id: printerIconImage.*source: root\.printerIconSource.*visible: false.*layer\.enabled: true/m,
                 @source)
    assert_match(/MultiEffect\s*{.*source: printerIconImage.*colorization: 1\.0.*colorizationColor: iconRoot\.tintColor/m,
                 @source)
    assert_match(/WidgetButton\s*{.*id: button.*text: "".*labelVisible: false.*hasVisualContent: true.*fixedWidth: root\.vertical \? barSize : buttonContent\.implicitWidth \+ scaledHorizontalMargin \* 2.*fixedHeight: barSize/m,
                 @source)
    assert_match(/Row\s*{.*id: buttonContent.*height: button\.fixedHeight.*PrinterIcon\s*{.*anchors\.verticalCenter: parent\.verticalCenter.*tintColor: root\.printerIconColor.*Text\s*{.*height: parent\.height.*verticalAlignment: Text\.AlignVCenter.*visible: !root\.vertical.*text: root\.compactLabel\(\)/m,
                 @source)
    assert_operator @source.scan("PrinterIcon {").length, :>=, 2
    refute_includes @source, "󰐫"
  end


  def test_status_identity_and_error_semantics_are_visually_explicit
    assert_match(/property color errorColor:/, @telemetry_source)
    assert_includes @telemetry_source, "property bool errorActive: false"
    assert_includes @telemetry_source, "property bool modelErrorActive: false"
    assert_match(/Column\s*{\s*id: telemetryContent.*Text\s*{\s*id: statusLine.*Row\s*{\s*id: printerIdentity.*SidebarPrinterIcon\s*{.*anchors\.verticalCenter: parent\.verticalCenter.*Text\s*{\s*id: printerNameText.*verticalAlignment: Text\.AlignVCenter/m,
                 @telemetry_source)
    assert_match(/id: statusLine.*color: pane\.errorActive \? pane\.errorColor/m,
                 @telemetry_source)
    assert_match(/function printerHasError\(\).*state === "ERROR".*state === "FAILED"/m,
                 @source)
    assert_match(/printerState: root\.displayGcodeState/, @source)
    assert_match(/label: "STATUS"; value: pane\.modelState; valueColor: \(pane\.errorActive \|\| pane\.modelErrorActive\) \? pane\.errorColor/m,
                 @telemetry_source)

    assert_includes @source, 'readonly property color errorColor: "#ff5f56"'
    assert_match(/readonly property bool errorActive: root\.printerHasError\(\)\s*\|\| root\.processError !== ""/m,
                 @source)
    global_error_definition = @source[
      /readonly property bool errorActive:.*?(?=\n  readonly property)/m
    ]
    refute_nil global_error_definition
    refute_includes global_error_definition, "modelStatus"
    assert_includes @source,
                    'readonly property bool modelErrorActive: root.modelStatus === "error"'
    assert_match(/BambuTelemetryPane\s*{.*errorColor: root\.errorColor.*errorActive: root\.errorActive.*modelErrorActive: root\.modelErrorActive/m,
                 @source)
    assert_match(/BambuModelViewport\s*{.*errorColor: root\.errorColor.*errorActive: root\.errorActive \|\| root\.modelErrorActive.*printing: root\.connected && root\.gcodeState === "RUNNING"/m,
                 @source)
    assert_match(/BambuSettingsView\s*{.*errorColor: root\.errorColor/m, @source)
    assert_match(/text: root\.processError \|\| "Waiting for a fresh printer report…".*color: root\.processError \? root\.errorColor : root\.dim/m,
                 @source)
    assert_match(/text: form\.validationError\s*color: form\.errorColor/m,
                 @settings_source)
  end

  def test_vertical_bar_is_icon_only
    assert_match(/function compactLabel\(\).*if \(!root\.hasConnectionTarget\) return "SETUP".*if \(!root\.connectionVerified\) return "WAIT"/m,
                 @source)
    assert_match(/Text\s*{.*height: parent\.height.*verticalAlignment: Text\.AlignVCenter.*visible: !root\.vertical && root\.showBarSummary\s*width: Math\.min\(implicitWidth, Style\.space\(220\)\)\s*text: root\.compactLabel\(\)/m,
                 @source)
    assert_match(/formatTemp\(root\.nozzleTemp\).*formatTemp\(root\.bedTemp\)/m, @source)
    assert_match(/tooltipText:.*!root\.connectionVerified \? "CONNECTING".*root\.percent.*formatTemp\(root\.nozzleTemp\).*formatTemp\(root\.bedTemp\)/m,
                 @source)
  end

  def test_key_catcher_uses_the_panels_inset_content_area
    assert_match(/PanelKeyCatcher\s*{.*anchors\.fill: parent.*clip: true/m, @source)
    refute_match(/PanelKeyCatcher\s*{.*width: panel\.contentWidth/m, @source)
    refute_match(/PanelKeyCatcher\s*{.*height: panel\.contentHeight/m, @source)
  end

  def test_panel_views_stay_inside_horizontal_margins
    assert_match(/contentWidth:\s*(?:panel\.)?fittedContentWidth\(Style\.space\(860\)\)/m,
                 @source)
    assert_match(/contentHeight:\s*(?:panel\.)?fittedContentHeight\(Style\.space\(520\), Style\.space\(620\)\)/m,
                 @source)
    assert_match(/Flickable\s*{.*id: panelScroll.*flickableDirection: Flickable\.VerticalFlick.*clip: true/m,
                 @source)
    assert_match(/id: dashboard\s*width: panelScroll\.width\s*height: wideLayout \? panel\.contentHeight\s*:\s*telemetryPane\.height \+ dashboardLayout\.spacing \+ modelPane\.height/m,
                 @source)
    assert_match(/BambuTelemetryPane\s*{.*id: telemetryPane.*onSettingsRequested: root\.toggleSettings\(\)/m,
                 @source)
    assert_match(/BambuSettingsView\s*{.*width: dashboard\.overlayWidth.*height: dashboard\.overlayHeight/m,
                 @source)
    refute_match(/parent\.width - Style\.bar\.iconCanvas/m, @source)
  end

  def test_keyboard_panel_has_a_themed_content_backdrop_for_quickshell_composition
    assert_match(/KeyboardPanel\s*{.*padding:\s*0/m, @source)
    assert_match(/PanelKeyCatcher\s*{.*Rectangle\s*{\s*id: panelBackdrop\s*anchors\.fill: parent\s*readonly property color baseColor: Color\.popups\.background\s*color: Qt\.rgba\(\s*baseColor\.r \* 0\.94 \+ root\.foreground\.r \* 0\.06,.*1\.0\)/m,
                 @source)
  end

  def test_manifest_exposes_only_non_secret_widget_settings
    manifest = JSON.parse(File.read(File.join(@root, "manifest.json")))
    settings = manifest.fetch("barWidget").fetch("schema").map { |entry| entry.fetch("key") }

    assert_equal %w[printerName host mqttPort ftpsPort serial username maxSegments accentColor showBarSummary
                    mqttTlsFingerprint ftpsTlsFingerprint], settings
    refute(settings.any? { |key| key.match?(/access|code|password|secret/i) })
    settings.each { |key| assert_includes @source, "setting(\"#{key}\"," }
  end

  def test_qml_setting_fallbacks_match_manifest_defaults
    manifest = JSON.parse(File.read(File.join(@root, "manifest.json")))
    defaults = manifest.fetch("barWidget").fetch("defaults")

    defaults.each do |key, value|
      literal = value.is_a?(String) ? value.inspect : value.to_s
      assert_includes @source, "setting(\"#{key}\", #{literal})"
    end
  end

  def test_blank_legacy_printer_name_uses_the_generic_default
    assert_match(/readonly property string displayName:.*return name \|\| "3D Printer"/m,
                 @source)
  end


  def test_configurable_accent_has_a_safe_green_fallback
    assert_includes @source, 'setting("accentColor", "#39FF88")'
    assert_match(/function validAccentColor\(value\).*\^#\[0-9A-Fa-f\]\{6\}\$/m,
                 @source)
    assert_match(/readonly property color neon: root\.validAccentColor\(root\.accentColor\).*root\.accentColor.*"#39FF88"/m,
                 @source)
  end

  def test_bar_summary_setting_hides_only_the_horizontal_recap
    manifest = JSON.parse(File.read(File.join(@root, "manifest.json")))
    defaults = manifest.fetch("barWidget").fetch("defaults")
    schema = manifest.fetch("barWidget").fetch("schema")

    assert_equal true, defaults["showBarSummary"]
    summary_schema = schema.find { |entry| entry["key"] == "showBarSummary" }
    assert_equal "boolean", summary_schema&.fetch("type")
    assert_includes @source, 'readonly property bool showBarSummary: setting("showBarSummary", true) !== false'
    assert_match(/function settingsDraft\(\).*showBarSummary: root\.showBarSummary/m, @source)
    assert_match(/function persistSettings\(draft\).*entry\.showBarSummary = draft\.showBarSummary/m,
                 @source)
    assert_match(/Text\s*\{.*visible: !root\.vertical && root\.showBarSummary.*text: root\.compactLabel\(\)/m,
                 @source)
    assert_match(/PrinterIcon\s*\{\s*anchors\.verticalCenter: parent\.verticalCenter/m,
                 @source)
  end
end
