# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "json"

class CanvasContractTest < Minitest::Test
  def setup
    @source = File.read(File.expand_path("../BambuModelViewport.qml", __dir__))
  end

  def test_canvas_animation_is_panel_scoped_and_twenty_fps
    assert_includes @source, "Canvas {"
    assert_includes @source, "renderStrategy: Canvas.Threaded"
    assert_includes @source, "interval: 50"
    assert_match(/running:\s*viewport\.panelActive\s*&&\s*viewport\.activeSegments\.length\s*>\s*0.*modelCanvas\.autoRotate/m,
                 @source)
    assert_includes @source, "function advanceAutoRotation(timestamp)"
    assert_match(/if \(dragging \|\| !autoRotate\) return false/, @source)
    assert_match(/yaw = normalizeAngle\(yaw \+ elapsed \/ 14000 \* Math\.PI \* 2\)/,
                 @source)
  end

  def test_each_frame_has_a_fixed_segment_budget_without_geometry_copies
    assert_match(/readonly property int motionSegmentBudget:\s*10000/, @source)
    assert_match(/readonly property int stillSegmentBudget:\s*40000/, @source)
    assert_match(/function renderBudget\(\).*dragging \|\| autoRotate \? motionSegmentBudget : stillSegmentBudget/m,
                 @source)
    assert_match(/function renderCount\(\).*Math\.min\(viewport\.activeSegments\.length, renderBudget\(\)\)/m,
                 @source)
    assert_includes @source, "function segmentIndexForSample(sample, segmentCount, sampleCount)"
    assert_match(/for \(var sample = 0; sample < countToDraw; sample\+\+\).*var index = segmentIndexForSample\(\s*sample, viewport\.activeSegments\.length, countToDraw\)/m,
                 @source)
    refute_match(/var\s+dark\s*=\s*\[\]\s*,\s*bright\s*=\s*\[\]/, @source)
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
    assert_match(/var renderColor = viewport\.errorActive \? viewport\.errorColor : viewport\.neon.*var completedColor = Qt\.rgba\(renderColor\.r, renderColor\.g,\s*renderColor\.b, 0\.74\)/m,
                 @source)
    assert_match(/var darkColor = Qt\.rgba\(viewport\.foreground\.r, viewport\.foreground\.g,\s*viewport\.foreground\.b, 0\.10\)/m,
                 @source)
    refute_match(/var darkColor = viewport\.errorActive/, @source)
    refute_includes @source, "haloColor"
  end

  def test_projection_frame_centers_and_fills_the_viewport_at_each_angle
    function = extract_function("projectionFrame")
    script = <<~JAVASCRIPT
      var projectionMinX = 107.453, projectionMaxX = 144.607
      var projectionMinY = 80.309, projectionMaxY = 99.606
      var projectionMinZ = 0.2, projectionMaxZ = 30.0
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
    assert_match(/Row\s*{\s*id:\s*modelControls.*id:\s*rotationButton.*id:\s*reloadButton/m,
                 @source)
    assert_includes @source, 'text: "RELOAD MODEL"'
    refute_includes @source, "id: viewportFooter"
  end

  def test_wheel_zoom_is_bounded_visible_and_documented_in_the_viewport
    assert_includes @source, "property real zoom: 1"
    assert_includes @source, "property real wheelStepAccumulator: 0"
    assert_match(/function wheelStepDelta\(angleDeltaY, pixelDeltaY\)/, @source)
    assert_match(/function wholeWheelSteps\(accumulatedSteps\)/, @source)
    assert_match(/function zoomAfterSteps\(currentZoom, steps\)/, @source)
    assert_match(/return Math\.max\(0\.5, Math\.min\(4(?:\.0)?, nextZoom\)\)/,
                 @source)
    assert_match(/onWheel: function\(wheel\).*wheelStepAccumulator \+=.*wholeWheelSteps.*if \(wholeSteps !== 0\).*zoomAfterSteps.*wheelStepAccumulator -= wholeSteps.*requestPaint\(\).*wheel\.accepted = true/m,
                 @source)
    assert_match(/frameScale = frame\.scale \* zoom/, @source)
    assert_includes @source, 'text: "ZOOM ×" + modelCanvas.formatZoom(modelCanvas.zoom)'
    assert_includes @source, "WHEEL TO ZOOM"
    assert_match(/onNeonChanged:\s*modelCanvas\.requestVisiblePaint\(false\)/,
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

  def test_print_preparation_and_error_states_are_explained_and_colored
    assert_includes @source, '"FINDING PRINT MODEL"'
    assert_includes @source, '"MODEL NOT READY YET"'
    assert_includes @source,
                    '"Automatic retries are limited · use Reload model to try again"'
    assert_match(/property color errorColor:/, @source)
    assert_match(/property bool errorActive:/, @source)
    assert_match(/var renderColor = viewport\.errorActive \? viewport\.errorColor : viewport\.neon/, @source)
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
      function requestPaint() { painted += 1 }
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
    assert_includes @source, "onActiveSegmentsChanged: modelCanvas.requestVisiblePaint(true)"
    assert_includes @source, "onActiveBoundsChanged: modelCanvas.requestVisiblePaint(true)"
    assert_includes @source, "onZCurrentChanged: modelCanvas.requestVisiblePaint(false)"
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
