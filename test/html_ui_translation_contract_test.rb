# frozen_string_literal: true

require_relative "test_helper"

class HtmlUiTranslationContractTest < Minitest::Test
  def setup
    @root = File.expand_path("..", __dir__)
    @widget = File.read(File.join(@root, "BambuWidget.qml"))
  end

  def test_dashboard_is_composed_from_native_lightweight_qml_components
    telemetry_path = File.join(@root, "BambuTelemetryPane.qml")
    viewport_path = File.join(@root, "BambuModelViewport.qml")

    assert File.file?(telemetry_path), "expected a dedicated telemetry sidebar"
    assert File.file?(viewport_path), "expected a dedicated native model viewport"
    assert_includes @widget, "BambuTelemetryPane {"
    assert_includes @widget, "BambuModelViewport {"
    refute_match(/WebEngine|Three\.js|three\.min\.js/i, @widget)
  end

  def test_dashboard_matches_the_reference_landscape_structure
    assert_match(/contentWidth:\s*fittedContentWidth\(Style\.space\(860\)\)/, @widget)
    assert_match(/contentHeight:\s*fittedContentHeight\(Style\.space\(520\), Style\.space\(620\)\)/,
                 @widget)
    assert_match(/id:\s*dashboardLayout.*columns:\s*dashboard\.wideLayout \? 2 : 1/m,
                 @widget)
    assert_match(/height:\s*wideLayout \? panel\.contentHeight\s*:\s*telemetryPane\.height \+ dashboardLayout\.spacing \+ modelPane\.height/m,
                 @widget)
    assert_match(/id:\s*telemetryPane.*width:\s*dashboard\.wideLayout\s*\? Style\.space\(300\)\s*:\s*dashboard\.width/m,
                 @widget)
    assert_match(/id:\s*modelPane.*width:\s*dashboard\.wideLayout\s*\? Math\.max\(0, dashboard\.width - telemetryPane\.width - dashboardLayout\.spacing\)\s*:\s*dashboard\.width/m,
                 @widget)
  end

  def test_telemetry_uses_aligned_metric_rows_and_theme_colors
    source = component_source("BambuTelemetryPane.qml")

    assert_includes source, "component MetricRow: Item"
    assert_match(/id:\s*metricLabel.*width:\s*parent\.width \* 0\.42/m, source)
    assert_match(/id:\s*metricValue.*horizontalAlignment:\s*Text\.AlignRight/m, source)
    assert_match(/id:\s*telemetryContent.*spacing:\s*Style\.space\(3\)/m, source)
    %w[TEMPERATURES PRINT\ METRICS CONNECTION MODEL\ DATA].each do |label|
      assert_match(/objectName:\s*"#{label}"/, source)
    end
    refute_match(/#[0-9a-f]{6}/i, source)
  end

  def test_viewport_has_lightweight_canvas_overlays_and_local_rotation_control
    source = component_source("BambuModelViewport.qml")

    assert_includes source, "Canvas {"
    assert_includes source, "renderStrategy: Canvas.Threaded"
    assert_includes source, "readonly property int motionSegmentBudget: 10000"
    assert_includes source, "readonly property int stillSegmentBudget: 40000"
    assert_match(/function renderBudget\(\).*dragging \|\| autoRotate\s*\? motionSegmentBudget : stillSegmentBudget/m,
                 source)
    assert_includes source, "interval: 50"
    assert_includes source, "function drawBuildPlateGrid(context)"
    assert_includes source, "property bool autoRotateDefault: true"
    assert_includes source, "property bool autoRotate: viewport.autoRotateDefault"
    assert_match(/running:\s*viewport\.panelActive.*modelCanvas\.autoRotate/m, source)
    assert_match(/text:\s*modelCanvas\.autoRotate \? "AUTO-ROTATE ON" : "AUTO-ROTATE OFF"/,
                 source)
    assert_includes source, "DRAG TO ROTATE · WHEEL TO ZOOM · HOLD TO PAUSE"
    assert_includes source, "PRINTED"
    assert_includes source, "REMAINING"
  end

  def test_viewport_orbits_in_both_mouse_axes_and_preserves_full_static_detail
    source = component_source("BambuModelViewport.qml")

    assert_includes source, "property real yaw: 0"
    assert_includes source, "property real pitch:"
    assert_includes source, "property real lastDragY: 0"
    assert_match(/function orientationAfterDrag\(startYaw, startPitch, deltaX, deltaY,\s*viewportWidth, viewportHeight\)/m,
                 source)
    assert_match(/yaw:\s*normalizeAngle\(startYaw \+ deltaX \/ viewportWidth \* Math\.PI \* 2\)/,
                 source)
    assert_match(/pitch:\s*clampPitch\(startPitch \+ deltaY \/ viewportHeight \* Math\.PI\)/,
                 source)
    assert_match(/function projectionFrame\(viewportWidth, viewportHeight, yawAngle, pitchAngle, padding\)/,
                 source)
    assert_match(/onPositionChanged: function\(mouse\).*mouse\.x - modelCanvas\.lastDragX.*mouse\.y - modelCanvas\.lastDragY/m,
                 source)
    assert_match(/function drawFrame\(context\).*if \(viewport\.zCurrent >= projectionMaxZ\).*drawSegments\(context, true/m,
                 source)
  end

  def test_real_settings_are_a_scrolling_omarchy_drawer
    source = component_source("BambuSettingsView.qml")

    assert_includes source, 'text: "SETTINGS"'
    assert_match(/id:\s*settingsClose.*visible:\s*form\.allowBack.*text:\s*"CLOSE".*bordered:\s*false/m, source)
    assert_match(/Flickable\s*{.*id:\s*settingsScroll.*contentHeight:\s*settingsContent\.implicitHeight/m,
                 source)
    assert_match(/id:\s*settingsScroll.*clip:\s*true/m, source)
    assert_includes source, "function resetScroll()"
    load_body = source[/function load\(draft\) \{.*?\n  \}/m]
    refute_nil load_body
    assert_includes load_body, "resetScroll()"
    assert_includes source, '"SAVE & CONNECT"'
    assert_includes source, 'text: "FORGET CODE"'
    refute_includes source, "advancedOpen"
    refute_match(/demoMode|Offline demo|demoToggle/i, source)
    refute_match(/SPEED PROFILE|TEMPERATURE PRESET/, source)
    assert_includes source, 'text: "ACCENT COLOR"'
  end


  def test_bordered_controls_keep_their_visual_border_inside_their_layout_cell
    button = component_source("BambuButton.qml")
    field = component_source("BambuTextField.qml")

    assert_match(/Button\s*\{.*anchors\.fill: parent.*anchors\.margins: root\.borderInset/m,
                 button)
    assert_match(/clip:\s*true/, button)
    %w[leftInset rightInset topInset bottomInset].each do |property|
      assert_match(/#{property}:\s*borderInset/, field)
    end
  end

  def test_action_buttons_use_plain_labels_without_decorative_glyphs
    telemetry = component_source("BambuTelemetryPane.qml")
    viewport = component_source("BambuModelViewport.qml")

    assert_includes telemetry, 'text: "SETTINGS"'
    assert_includes viewport, 'text: "RELOAD PREVIEW"'
    refute_match(/[⚙↻]/, telemetry + viewport)
  end

  private

  def component_source(name)
    path = File.join(@root, name)
    assert File.file?(path), "expected #{name}"
    File.read(path)
  end
end
