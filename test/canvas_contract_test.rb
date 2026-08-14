# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "json"

class CanvasContractTest < Minitest::Test
  def setup
    @source = File.read(File.expand_path("../BambuModelViewport.qml", __dir__))
  end

  def test_source_icons_are_white_masks_recolored_by_the_plugin_palette
    %w[route.svg image.svg].each do |name|
      icon = File.read(File.expand_path("../assets/#{name}", __dir__))

      assert_includes icon, 'stroke="#fff"'
      refute_includes icon, 'stroke="#000"'
    end
    assert_match(/component SourceIconButton: BambuButton.*MultiEffect.*colorization:\s*1.*colorizationColor:\s*foreground/m,
                 @source)
  end

  def test_loading_message_has_three_panel_scoped_staggered_bouncing_dots
    assert_match(/id:\s*loadingIndicator.*visible:\s*viewport\.modelStatus === "loading"/m,
                 @source)
    assert_match(/Repeater\s*{\s*model:\s*3.*property int phaseDelay:\s*index \* 120/m,
                 @source)
    assert_match(/SequentialAnimation\s*{.*running:\s*viewport\.panelActive\s*&&\s*loadingIndicator\.visible.*loops:\s*Animation\.Infinite.*PauseAnimation\s*{\s*duration:\s*loadingDot\.phaseDelay\s*}.*NumberAnimation\s*{.*property:\s*"y".*to:\s*-Style\.space\(3\).*}.*NumberAnimation\s*{.*property:\s*"y".*to:\s*0/m,
                 @source)
  end

  def test_canvas_animation_is_panel_scoped_and_twenty_fps
    assert_includes @source, "Canvas {"
    assert_includes @source, "renderStrategy: Canvas.Immediate"
    assert_includes @source, "interval: 50"
    assert_match(/running:\s*viewport\.panelActive\s*&&\s*viewport\.activeSegments\.length\s*>\s*0.*modelCanvas\.autoRotate/m,
                 @source)
    assert_includes @source, "function advanceAutoRotation(timestamp)"
    assert_match(/if \(dragging\) return false/, @source)
    assert_match(/yaw = normalizeAngle\(yaw \+ elapsed \/ 14000 \* Math\.PI \* 2\)/,
                 @source)
  end

  def test_auto_rotation_uses_the_configured_default_but_remains_session_toggleable
    assert_includes @source, "property bool autoRotateDefault: true"
    assert_includes @source, "property bool autoRotate: viewport.autoRotateDefault"
    assert_match(/onAutoRotateDefaultChanged:\s*\{.*modelCanvas\.autoRotate = viewport\.autoRotateDefault.*modelCanvas\.lastFrameTimestamp = 0.*modelCanvas\.requestVisiblePaint\(false\)/m,
                 @source)
    assert_match(/text: modelCanvas\.autoRotate \? "AUTO-ROTATE ON" : "AUTO-ROTATE OFF".*onClicked:\s*\{.*modelCanvas\.autoRotate = !modelCanvas\.autoRotate/m,
                 @source)
  end

  def test_each_frame_has_a_fixed_segment_budget_without_geometry_copies
    assert_match(/readonly property int motionSegmentBudget:\s*10000/, @source)
    assert_match(/readonly property int stillSegmentBudget:\s*40000/, @source)
    assert_match(/function renderBudget\(\).*dragging \|\| autoRotate \? motionSegmentBudget : stillSegmentBudget/m,
                 @source)
    assert_match(/function renderCount\(\).*Math\.min\(packedCount, renderBudget\(\)\)/m,
                 @source)
    assert_includes @source, "function segmentIndexForSample(sample, segmentCount, sampleCount)"
    assert_includes @source, "function rebuildPackedSegments()"
    assert_match(/for \(var sample = 0; sample < countToDraw; sample\+\+\).*var index = segmentIndexForSample\(sample, segmentCount, countToDraw\)/m,
                 @source)
    refute_match(/var\s+dark\s*=\s*\[\]\s*,\s*bright\s*=\s*\[\]/, @source)
  end

  def test_paint_requests_coalesce_to_one_visible_frame
    assert_includes @source, "function schedulePaint()"
    assert_includes @source, "function flushQueuedPaint()"
    assert_match(/if \(paintQueued\) return/, @source)
    assert_match(/Qt\.callLater\(flushQueuedPaint\)/, @source)
    schedule = extract_function("schedulePaint")
    flush = extract_function("flushQueuedPaint")
    script = <<~JAVASCRIPT
      var viewport = { panelActive: true }
      var paintQueued = false
      var painted = 0
      var later = []
      var Qt = { callLater: function(fn) { later.push(fn) } }
      function requestPaint() { painted += 1 }
      #{schedule}
      #{flush}
      schedulePaint()
      schedulePaint()
      schedulePaint()
      var queuedBeforeFlush = later.length
      later[0]()
      viewport.panelActive = false
      schedulePaint()
      later[1]()
      console.log(JSON.stringify({
        queuedBeforeFlush: queuedBeforeFlush,
        painted: painted,
        later: later.length
      }))
    JAVASCRIPT
    result = run_javascript(script)

    assert_equal 1, result.fetch("queuedBeforeFlush")
    assert_equal 1, result.fetch("painted")
    assert_equal 2, result.fetch("later")
  end

  def test_packed_segments_drop_invalid_rows_once
    check = extract_function("segmentIsFinite")
    pack = extract_function("rebuildPackedSegments")
    result = run_javascript(<<~JAVASCRIPT)
      var packedSegments = [9]
      var packedCount = 99
      var viewport = { activeSegments: [
        [0, 1, 2, 3, 4, 5],
        [0, 1, 2, 3, 4, NaN],
        null,
        [6, 7, 8, 9, 10, 11]
      ] }
      #{check}
      #{pack}
      rebuildPackedSegments()
      console.log(JSON.stringify({ packed: packedSegments, count: packedCount }))
    JAVASCRIPT

    assert_equal [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11], result.fetch("packed")
    assert_equal 2, result.fetch("count")
  end

  def test_bounded_sampling_is_uniform_and_includes_both_endpoints
    function = extract_function("segmentIndexForSample")
    script = <<~JAVASCRIPT
      #{function}
      console.log(JSON.stringify([
        segmentIndexForSample(0, 100001, 3),
        segmentIndexForSample(1, 100001, 3),
        segmentIndexForSample(2, 100001, 3),
        segmentIndexForSample(0, 1, 1)
      ]))
    JAVASCRIPT

    assert_equal [0, 50_000, 100_000, 0], run_javascript(script)
  end

  def test_z_cut_interpolates_crossings_and_draws_clean_single_pass_color
    assert_includes @source, "function splitAtCut(context, segment, cutoff, brightWanted)"
    assert_match(/var ratio = \(cutoff - firstZ\) \/ denominator/, @source)
    assert_match(/ratio = Math\.max\(0, Math\.min\(1, ratio\)\)/, @source)
    assert_match(/var crossingX = firstX \+ \(secondX - firstX\) \* ratio/, @source)
    assert_match(/var crossingY = firstY \+ \(secondY - firstY\) \* ratio/, @source)
    assert_match(/function drawFrame\(context\).*drawSegments\(context, false, darkColor, 0\.55\).*drawSegments\(context, true, completedColor, 0\.70\)/m,
                 @source)
    assert_match(/var renderColor = viewport\.errorActive \? viewport\.errorColor : viewport\.accent.*var completedColor = Qt\.rgba\(renderColor\.r, renderColor\.g,\s*renderColor\.b, 0\.74\)/m,
                 @source)
    assert_match(/var darkColor = Qt\.rgba\(viewport\.foreground\.r, viewport\.foreground\.g,\s*viewport\.foreground\.b, 0\.10\)/m,
                 @source)
    refute_match(/var darkColor = viewport\.errorActive/, @source)
    refute_includes @source, "haloColor"
  end

  def test_projection_frame_centers_and_fills_the_viewport_at_each_angle
    display = extract_function("displayZ")
    function = extract_function("projectionFrame")
    script = <<~JAVASCRIPT
      var projectionMinX = 107.453, projectionMaxX = 144.607
      var projectionMinY = 80.309, projectionMaxY = 99.606
      var projectionMinZ = 0.2, projectionMaxZ = 30.0
      var explosionFactor = 20, explosionProgress = 1
      #{display}
      #{function}
      var frames = [0, Math.PI / 3, Math.PI].map(function(angle) {
        return projectionFrame(600, 360, angle, -0.28, 24)
      })
      console.log(JSON.stringify(frames))
    JAVASCRIPT

    run_javascript(script).each do |frame|
      assert_in_delta 300, (frame.fetch("left") + frame.fetch("right")) / 2.0, 1e-9
      assert_in_delta 180, (frame.fetch("top") + frame.fetch("bottom")) / 2.0, 1e-9
      assert_operator frame.fetch("left"), :>=, 24 - 1e-9
      assert_operator frame.fetch("right"), :<=, 576 + 1e-9
      assert_operator frame.fetch("top"), :>=, 24 - 1e-9
      assert_operator frame.fetch("bottom"), :<=, 336 + 1e-9
      occupancy = [
        (frame.fetch("right") - frame.fetch("left")) / 552.0,
        (frame.fetch("bottom") - frame.fetch("top")) / 312.0
      ].max
      assert_in_delta 1.0, occupancy, 1e-9
    end
  end

  def test_two_axis_drag_covers_full_yaw_and_bounded_pitch_while_hold_pauses
    normalize = extract_function("normalizeAngle")
    clamp = extract_function("clampPitch")
    drag = extract_function("orientationAfterDrag")
    script = <<~JAVASCRIPT
      #{normalize}
      #{clamp}
      #{drag}
      console.log(JSON.stringify([
        orientationAfterDrag(0, 0, 300, 0, 600, 360),
        orientationAfterDrag(0, 0, -150, 180, 600, 360),
        orientationAfterDrag(1, 0, 600, -1000, 600, 360)
      ]))
    JAVASCRIPT
    values = run_javascript(script)

    assert_in_delta Math::PI, values[0].fetch("yaw"), 1e-9
    assert_in_delta 0, values[0].fetch("pitch"), 1e-9
    assert_in_delta Math::PI * 1.5, values[1].fetch("yaw"), 1e-9
    assert_operator values[1].fetch("pitch"), :>, 1.4
    assert_in_delta 1.0, values[2].fetch("yaw"), 1e-9
    assert_operator values[2].fetch("pitch"), :<, -1.4
    assert_match(/MouseArea\s*\{.*anchors\.fill: parent.*onPressed: function\(mouse\).*dragging = true.*onPositionChanged: function\(mouse\).*orientationAfterDrag.*onReleased:.*dragging = false/m,
                 @source)
  end

  def test_reload_sits_with_rotation_controls_and_canvas_uses_the_footer_space
    assert_match(/id:\s*canvasFrame.*anchors\.bottom:\s*parent\.bottom/m, @source)
    assert_match(/Row\s*{\s*id:\s*modelControls.*text: modelCanvas\.autoRotate \? "AUTO-ROTATE ON" : "AUTO-ROTATE OFF".*text: "RELOAD PREVIEW"/m,
                 @source)
    assert_includes @source, 'text: "RELOAD PREVIEW"'
    refute_includes @source, "id: viewportFooter"
  end

  def test_gcode_and_preview_use_vertical_lucide_buttons_below_coordinates
    assert_includes @source, "property bool previewAvailable: false"
    assert_includes @source, "property bool gcodeAvailable: false"
    assert_includes @source, 'property string selectedSource: "gcode"'
    assert_includes @source, "signal sourceRequested(string source)"
    assert_match(/component SourceIconButton: BambuButton\s*\{.*required property string sourceName.*required property bool available.*enabled: available.*active: viewport\.selectedSource === sourceName.*onClicked: viewport\.sourceRequested\(sourceName\)/m,
                 @source)
    assert_match(/Column\s*\{\s*id:\s*sourceButtons.*anchors\.top:\s*coordinateBadge\.bottom.*SourceIconButton\s*\{.*sourceName:\s*"gcode".*available:\s*viewport\.gcodeAvailable.*iconSource:\s*Qt\.resolvedUrl\("assets\/route\.svg"\).*SourceIconButton\s*\{.*sourceName:\s*"preview".*available:\s*viewport\.previewAvailable.*iconSource:\s*Qt\.resolvedUrl\("assets\/image\.svg"\)/m,
                 @source)
    refute_includes @source, 'text: "MODEL"'
    refute_includes @source, 'text: "G-CODE"'
  end

  def test_switching_source_does_not_reset_the_canvas_camera
    buttons = @source[/Column\s*\{\s*id:\s*sourceButtons.*?\n\s*\}/m]
    refute_nil buttons
    refute_match(/modelCanvas\.(?:yaw|pitch|zoom)\s*=/, buttons)
  end

  def test_preview_is_centered_without_using_the_canvas_renderer
    assert_match(/Image\s*\{\s*anchors\.fill: parent.*source:\s*viewport\.previewSource.*fillMode:\s*Image\.PreserveAspectFit.*visible:\s*viewport\.selectedSource === "preview"/m,
                 @source)
    assert_match(/Canvas\s*\{\s*id:\s*modelCanvas.*visible:\s*viewport\.selectedSource === "gcode"/m,
                 @source)
  end

  def test_simulated_nozzle_loops_over_only_the_nearest_gcode_layer
    segment_check = extract_function("segmentIsFinite")
    build = extract_function("buildNozzlePath")
    position = extract_function("nozzlePosition")
    result = run_javascript(<<~JAVASCRIPT)
      #{segment_check}
      #{build}
      #{position}
      var segments = [
        [0,0,0.2,10,0,0.2], [10,0,0.2,10,10,0.2],
        [0,0,0.4,20,0,0.4], [20,0,0.4,20,20,0.4]
      ]
      var path = buildNozzlePath(segments, 0.39, 4096)
      console.log(JSON.stringify({ count: path.items.length,
        total: path.totalLength,
        start: nozzlePosition(path, segments, 0),
        middle: nozzlePosition(path, segments, 0.5),
        looped: nozzlePosition(path, segments, 1) }))
    JAVASCRIPT

    assert_equal 2, result.fetch("count")
    assert_in_delta 40, result.fetch("total"), 1e-9
    assert_equal [0, 0, 0.4], result.fetch("start")
    assert_equal [20, 0, 0.4], result.fetch("middle")
    assert_equal result.fetch("start"), result.fetch("looped")
    assert_match(/function drawNozzle\(context\).*context\.arc/m, @source)
    assert_match(/running:.*viewport\.selectedSource === "gcode".*viewport\.printing.*modelCanvas\.nozzlePath\.items\.length > 0/m,
                 @source)
  end

  def test_wheel_zoom_is_bounded_visible_and_documented_in_the_viewport
    assert_includes @source, "property real zoom: 1"
    assert_includes @source, "property real wheelStepAccumulator: 0"
    assert_match(/function wheelStepDelta\(angleDeltaY, pixelDeltaY\)/, @source)
    assert_match(/function wholeWheelSteps\(accumulatedSteps\)/, @source)
    assert_match(/function zoomAfterSteps\(currentZoom, steps\)/, @source)
    assert_match(/return Math\.max\(0\.5, Math\.min\(4(?:\.0)?, nextZoom\)\)/,
                 @source)
    assert_match(/onWheel: function\(wheel\).*wheelStepAccumulator \+=.*wholeWheelSteps.*if \(wholeSteps !== 0\).*zoomAfterSteps.*wheelStepAccumulator -= wholeSteps.*schedulePaint\(\).*wheel\.accepted = true/m,
                 @source)
    assert_match(/frameScale = frame\.scale \* zoom/, @source)
    assert_includes @source, 'text: "ZOOM ×" + modelCanvas.formatZoom(modelCanvas.zoom)'
    assert_includes @source, "WHEEL TO ZOOM"
    assert_match(/onAccentChanged:\s*modelCanvas\.requestVisiblePaint\(false\)/,
                 @source)
    assert_match(/Row\s*{\s*id:\s*modelFooter.*width: Math\.max\(0, parent\.width - Style\.space\(20\)\).*clip:\s*true/m,
                 @source)
  end

  def test_wheel_zoom_multiplier_moves_both_directions_and_clamps
    delta = extract_function("wheelStepDelta")
    whole = extract_function("wholeWheelSteps")
    zoom = extract_function("zoomAfterSteps")
    format = extract_function("formatZoom")
    values = run_javascript(<<~JAVASCRIPT)
      #{delta}
      #{whole}
      #{zoom}
      #{format}
      console.log(JSON.stringify({
        deltas: [wheelStepDelta(120, 0), wheelStepDelta(-1, 0),
          wheelStepDelta(0, 15)],
        whole: [wholeWheelSteps(0.99), wholeWheelSteps(-0.99),
          wholeWheelSteps(1.01), wholeWheelSteps(-1.01)],
        zooms: [zoomAfterSteps(1, 1), zoomAfterSteps(1, -1),
          zoomAfterSteps(3.99, 10), zoomAfterSteps(0.51, -10)],
        labels: [formatZoom(1), formatZoom(1.12), formatZoom(0.999999999)]
      }))
    JAVASCRIPT

    assert_equal [1, -1.0 / 120, 0.5], values.fetch("deltas")
    assert_equal [0, 0, 1, -1], values.fetch("whole")
    assert_operator values.fetch("zooms")[0], :>, 1
    assert_operator values.fetch("zooms")[1], :<, 1
    assert_equal 4, values.fetch("zooms")[2]
    assert_equal 0.5, values.fetch("zooms")[3]
    assert_equal ["1", "1.12", "1"], values.fetch("labels")
  end

  def test_exploded_view_scales_only_display_z_with_a_bounded_animation
    assert_includes @source, "property real explosionFactor: 100"
    assert_match(/readonly property real explosionFactor: Math\.max\(0, Math\.min\(500,.*viewport\.explosionFactor.*100\)\)/m,
                 @source)
    assert_includes @source, "property bool exploded: false"
    assert_includes @source, "property real explosionProgress: exploded ? 1 : 0"
    assert_match(/Behavior on explosionProgress\s*{\s*NumberAnimation\s*{.*duration:\s*350.*easing\.type:\s*Easing\.InOutCubic/m,
                 @source)
    assert_match(/onExplosionProgressChanged:\s*requestVisiblePaint\(false\)/,
                 @source)
    assert_match(/onExplosionFactorChanged:\s*modelCanvas\.requestVisiblePaint\(false\)/,
                 @source)

    function = extract_function("displayZ")
    values = run_javascript(<<~JAVASCRIPT)
      var projectionMinZ = 0.2
      var explosionFactor = 20
      #{function}
      var explosionProgress = 0
      var collapsed = displayZ(0.4)
      explosionProgress = 0.5
      var halfway = displayZ(0.4)
      explosionProgress = 1
      var expanded = displayZ(0.4)
      var base = displayZ(0.2)
      explosionProgress = 2
      var clamped = displayZ(0.4)
      console.log(JSON.stringify([collapsed, halfway, expanded, base, clamped]))
    JAVASCRIPT

    assert_in_delta 0.4, values[0], 1e-9
    assert_in_delta 2.4, values[1], 1e-9
    assert_in_delta 4.4, values[2], 1e-9
    assert_in_delta 0.2, values[3], 1e-9
    assert_in_delta 4.4, values[4], 1e-9
    assert_match(/function projectionFrame.*var minDisplayZ = displayZ\(projectionMinZ\).*var maxDisplayZ = displayZ\(projectionMaxZ\)/m,
                 @source)
    assert_match(/function projectPoint.*var translatedZ = displayZ\(z\) - frameModelCenterZ/m,
                 @source)
  end

  def test_explode_button_is_above_the_z_footer_and_only_controls_gcode
    assert_match(/BambuButton\s*{\s*visible:\s*viewport\.selectedSource === "gcode".*anchors\.right:\s*parent\.right.*anchors\.bottom:\s*modelFooter\.top.*text:\s*modelCanvas\.exploded \? "EXPLODE ON" : "EXPLODE OFF".*enabled:\s*viewport\.gcodeAvailable.*onClicked:\s*modelCanvas\.exploded = !modelCanvas\.exploded/m,
                 @source)
  end

  def test_print_preparation_and_error_states_are_explained_and_colored
    assert_includes @source, '"FINDING PRINT DATA"'
    assert_includes @source, '"PRINT DATA NOT READY YET"'
    assert_includes @source,
                    '"Automatic retries are limited · use Reload preview to try again"'
    assert_match(/property color errorColor:/, @source)
    assert_match(/property bool errorActive:/, @source)
    assert_match(/var renderColor = viewport\.errorActive \? viewport\.errorColor : viewport\.accent/, @source)
    assert_match(/function drawNozzle\(context\).*var color = viewport\.errorActive \? viewport\.errorColor : viewport\.accent/m,
                 @source)
    assert_match(/text: "● PRINTED"\s*color: viewport\.errorActive \? viewport\.errorColor : viewport\.accent/m,
                 @source)
    assert_match(/text: "Z ".*color: viewport\.errorActive \? viewport\.errorColor : viewport\.accent/m,
                 @source)
    assert_match(/color: viewport\.errorColor.*visible: viewport\.modelError !== ""/m,
                 @source)
    assert_includes @source, "onErrorActiveChanged: modelCanvas.requestVisiblePaint(false)"
  end

  def test_z_cut_runtime_keeps_submicron_crossings_and_cut_equality
    function = extract_function("splitAtCut")
    script = <<~JAVASCRIPT
      var points = []
      function appendWholeSegment(context, segment) { points.push(segment.slice(0)) }
      function appendProjectedPoint(context, x, y, z, move) {
        points.push([x, y, z, move])
      }
      #{function}
      var tiny = [0, 0, 0, 1, 1, 0.0000005]
      var bright = splitAtCut(null, tiny, 0.00000025, true)
      var tinyPoints = points.slice(0)
      points = []
      var equal = [0, 0, 2, 1, 1, 3]
      var equalBright = splitAtCut(null, equal, 2, true)
      var equalPoints = points.slice(0)
      console.log(JSON.stringify({ bright: bright, tiny: tinyPoints,
        equalBright: equalBright, equal: equalPoints }))
    JAVASCRIPT
    result = run_javascript(script)

    assert_equal true, result.fetch("bright")
    assert_equal [[0, 0, 0, true], [0.5, 0.5, 0.00000025, false]],
                 result.fetch("tiny")
    assert_equal true, result.fetch("equalBright")
    assert_equal [[0, 0, 2, true], [0, 0, 2, false]], result.fetch("equal")
  end

  def test_projection_and_paint_reject_invalid_runtime_data
    assert_includes @source, "function segmentIsFinite(segment)"
    assert_match(/if \(!segmentIsFinite\(segment\)\) continue/, @source)
    assert_includes @source, "function rebuildProjectionBounds()"
    assert_match(/if \(!isFinite\(width\) \|\| !isFinite\(height\) \|\| width <= 0 \|\| height <= 0\) return/,
                 @source)
    assert_match(/var spanU = Math\.max\(maxU - minU, 1e-9\)/, @source)
    assert_match(/var spanV = Math\.max\(maxV - minV, 1e-9\)/, @source)
  end

  def test_segment_validation_runtime_rejects_non_finite_and_malformed_data
    function = extract_function("segmentIsFinite")
    script = <<~JAVASCRIPT
      #{function}
      console.log(JSON.stringify([
        segmentIsFinite([0, 1, 2, 3, 4, 5]),
        segmentIsFinite([0, 1, 2, 3, 4, NaN]),
        segmentIsFinite([0, 1, 2, 3, 4, "5"]),
        segmentIsFinite([0, 1, 2]),
        segmentIsFinite(null)
      ]))
    JAVASCRIPT

    assert_equal [true, false, false, false, false], run_javascript(script)
  end

  def test_repaints_for_data_cut_resize_and_reopen_but_stops_when_closed
    assert_includes @source, "function requestVisiblePaint(rebuildBounds)"
    function = extract_function("requestVisiblePaint")
    script = <<~JAVASCRIPT
      var viewport = { panelActive: false }
      var rebuilt = 0, painted = 0
      function rebuildProjectionBounds() { rebuilt += 1 }
      function schedulePaint() { painted += 1 }
      #{function}
      var closedResult = requestVisiblePaint(true)
      viewport.panelActive = true
      var openResult = requestVisiblePaint(true)
      console.log(JSON.stringify({ closedResult: closedResult,
        openResult: openResult, rebuilt: rebuilt, painted: painted }))
    JAVASCRIPT
    result = run_javascript(script)

    assert_equal false, result.fetch("closedResult")
    assert_equal true, result.fetch("openResult")
    assert_equal 1, result.fetch("rebuilt")
    assert_equal 1, result.fetch("painted")
    assert_match(/onActiveSegmentsChanged:\s*\{.*modelCanvas\.rebuildPackedSegments\(\).*modelCanvas\.rebuildNozzlePath\(\).*modelCanvas\.requestVisiblePaint\(true\)/m,
                 @source)
    assert_includes @source, "onActiveBoundsChanged: modelCanvas.requestVisiblePaint(true)"
    assert_match(/onZCurrentChanged:\s*\{.*modelCanvas\.rebuildNozzlePath\(\).*modelCanvas\.requestVisiblePaint\(false\)/m,
                 @source)
    assert_match(/onPanelActiveChanged:.*if \(viewport\.panelActive\) modelCanvas\.requestVisiblePaint\(true\)/m,
                 @source)
    assert_includes @source, "onWidthChanged: requestVisiblePaint(false)"
    assert_includes @source, "onHeightChanged: requestVisiblePaint(false)"
    assert_match(/onPaint:\s*{\s*if \(!viewport\.panelActive\) return/, @source)
  end


  private

  def extract_function(name)
    start = @source.index("function #{name}(")
    refute_nil start, "missing function #{name}"
    opening = @source.index("{", start)
    depth = 0
    @source.each_char.with_index.drop(opening).each do |character, index|
      depth += 1 if character == "{"
      depth -= 1 if character == "}"
      return @source[start..index] if depth.zero?
    end
    flunk "unterminated function #{name}"
  end

  def run_javascript(script)
    output, error, status = Open3.capture3("node", "-e", script)
    assert status.success?, "JavaScript harness failed: #{error}"
    JSON.parse(output)
  end
end
