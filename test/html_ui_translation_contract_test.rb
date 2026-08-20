# frozen_string_literal: true

require_relative "test_helper"

class HtmlUiTranslationContractTest < Minitest::Test
  def setup
    @root = File.expand_path("..", __dir__)
    @widget = ["BambuWidget.qml", "BambuDashboard.qml"].map do |name|
      File.read(File.join(@root, name))
    end.join("\n")
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
    assert_match(/contentHeight:\s*fittedContentHeight\(dashboard\.preferredViewportHeight\)/,
                 @widget)
    assert_match(/id:\s*dashboardLayout.*columns:\s*dashboard\.wideLayout \? 2 : 1/m,
                 @widget)
    assert_match(/id:\s*telemetryPane.*width:\s*dashboard\.wideLayout\s*\? Style\.space\(300\)\s*:\s*dashboard\.width/m,
                 @widget)
    assert_match(/BambuModelViewport\s*\{.*width:\s*dashboard\.wideLayout\s*\? Math\.max\(0, dashboard\.width - telemetryPane\.width\s*- dashboardLayout\.spacing\)\s*:\s*dashboard\.width/m,
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
    assert_equal ["#39FF88"], source.scan(/#[0-9a-f]{6}/i).uniq
  end

  def test_viewport_has_lightweight_canvas_overlays_and_local_rotation_control
    source = component_source("BambuModelViewport.qml")

    refute_match(/Canvas\s*\{/, source)
    refute_includes source, "motionSegmentBudget"
    refute_includes source, "stillSegmentBudget"
    refute_includes source, "packedSegments"
    refute_includes source, "function requestVisiblePaint"
    refute_includes source, "onPaint:"
    assert_match(/Loader\s*\{.*id:\s*routeLoader.*source:.*nativeRouteUrl/m, source)
    assert_includes source, 'property string rendererStatus'
    assert_includes source, 'id: routeCamera'
    assert_includes source, "interval: 16"
    assert_match(/running:\s*viewport\.panelActive.*routeCamera\.autoRotate/m, source)
    assert_match(/text:\s*routeCamera\.autoRotate \? "AUTO-ROTATE ON" : "AUTO-ROTATE OFF"/,
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
    assert_match(/onPositionChanged: function\(mouse\).*mouse\.x - routeCamera\.lastDragX.*mouse\.y - routeCamera\.lastDragY/m,
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
