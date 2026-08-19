# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"

class QmlGeometryTransactionTest < Minitest::Test
  FUNCTIONS = %w[
    objectOrEmpty isNonNegativeInteger validPreview validSegmentPath
    resetPendingGeometry beginGeometry appendPreviewChunk finishGeometry
  ].freeze

  def setup
    @source = File.read(File.expand_path("../BambuWidget.qml", __dir__))
  end

  def test_gcode_and_png_preview_replace_the_active_bundle_only_after_end
    result = run_transaction(<<~JAVASCRIPT)
      beginGeometry({ segmentCount: 1,
        gcode: { segmentCount: 1, bounds: { minZ: 0.2, maxZ: 0.2 },
          path: "/tmp/bambu/geometry/4.f32" },
        preview: { byteCount: 3, width: 320, height: 240,
          mimeType: "image/png", encodedLength: 4 } }, 4)
      appendPreviewChunk({ source: "preview", index: 0, data: "UE5H" }, 4)
      var beforeEnd = geometryBundle.previous === true
      finishGeometry({ sources: ["gcode", "preview"],
        chunks: { gcode: 0, preview: 1 } }, 4)
      console.log(JSON.stringify({ beforeEnd: beforeEnd,
        selected: selectedGeometrySource,
        gcodePath: geometryBundle.gcode.path,
        previewUrl: geometryBundle.preview.url,
        pendingKeys: Object.keys(pendingGeometry).length }))
    JAVASCRIPT

    assert_equal true, result.fetch("beforeEnd")
    assert_equal "gcode", result.fetch("selected")
    assert_equal "/tmp/bambu/geometry/4.f32", result.fetch("gcodePath")
    assert_equal "data:image/png;base64,UE5H", result.fetch("previewUrl")
    assert_equal 0, result.fetch("pendingKeys")
  end

  def test_each_source_can_be_published_independently
    result = run_transaction(<<~JAVASCRIPT)
      beginGeometry({ segmentCount: 0, gcode: null,
        preview: { byteCount: 3, width: 1, height: 1,
          mimeType: "image/png", encodedLength: 4 } }, 4)
      appendPreviewChunk({ source: "preview", index: 0, data: "UE5H" }, 4)
      finishGeometry({ sources: ["preview"], chunks: { preview: 1 } }, 4)
      var previewOnly = selectedGeometrySource === "preview"
        && geometryBundle.gcode === undefined
      beginGeometry({ segmentCount: 1,
        gcode: { segmentCount: 1, bounds: {},
          path: "/tmp/bambu/geometry/5.f32" }, preview: null }, 5)
      finishGeometry({ sources: ["gcode"], chunks: { gcode: 0 } }, 5)
      console.log(JSON.stringify({ previewOnly: previewOnly,
        gcodeOnly: selectedGeometrySource === "gcode"
          && geometryBundle.preview === undefined }))
    JAVASCRIPT

    assert result.fetch("previewOnly")
    assert result.fetch("gcodeOnly")
  end

  def test_binary_gcode_path_preserves_segment_metadata
    result = run_transaction(<<~JAVASCRIPT)
      beginGeometry({ segmentCount: 500000,
        gcode: { segmentCount: 500000, bounds: { minZ: 0.2, maxZ: 42 },
          path: "/tmp/bambu/geometry/4.f32" }, preview: null }, 4)
      finishGeometry({ sources: ["gcode"], chunks: { gcode: 0 } }, 4)
      console.log(JSON.stringify({
        selected: selectedGeometrySource,
        path: geometryBundle.gcode.path,
        count: geometryBundle.gcode.segmentCount,
        pendingKeys: Object.keys(pendingGeometry).length
      }))
    JAVASCRIPT

    assert_equal "gcode", result.fetch("selected")
    assert_equal "/tmp/bambu/geometry/4.f32", result.fetch("path")
    assert_equal 500_000, result.fetch("count")
    assert_equal 0, result.fetch("pendingKeys")
  end

  def test_binary_gcode_path_must_be_absolute_bounded_and_f32
    result = run_transaction(<<~JAVASCRIPT)
      var paths = ["relative/4.f32", "/tmp/../secret.f32", "/tmp/4.bin",
        "/tmp/" + "a".repeat(4097) + ".f32"]
      var rejected = []
      for (var index = 0; index < paths.length; index++) {
        beginGeometry({ segmentCount: 1,
          gcode: { segmentCount: 1, bounds: {}, path: paths[index] },
          preview: null }, 4)
        rejected.push(Object.keys(pendingGeometry).length === 0)
      }
      console.log(JSON.stringify(rejected))
    JAVASCRIPT

    assert_equal [true, true, true, true], result
  end

  def test_invalid_preview_or_incomplete_gcode_preserves_the_active_bundle
    result = run_transaction(<<~JAVASCRIPT)
      beginGeometry({ segmentCount: 0, gcode: null,
        preview: { byteCount: 4, width: 320, height: 240,
          mimeType: "image/png", encodedLength: 4 } }, 4)
      var invalidPreviewRejected = Object.keys(pendingGeometry).length === 0
      beginGeometry({ segmentCount: 2,
        gcode: { segmentCount: 2, bounds: {} }, preview: null }, 4)
      console.log(JSON.stringify({ invalidPreviewRejected: invalidPreviewRejected,
        previousPreserved: geometryBundle.previous === true,
        pendingKeys: Object.keys(pendingGeometry).length }))
    JAVASCRIPT

    assert result.fetch("invalidPreviewRejected")
    assert result.fetch("previousPreserved")
    assert_equal 0, result.fetch("pendingKeys")
  end

  def test_preview_chunks_are_ordered_and_bounded
    result = run_transaction(<<~JAVASCRIPT)
      beginGeometry({ segmentCount: 0, gcode: null,
        preview: { byteCount: 6, width: 1, height: 1,
          mimeType: "image/png", encodedLength: 8 } }, 4)
      appendPreviewChunk({ source: "preview", index: 1, data: "QUJD" }, 4)
      var outOfOrderRejected = Object.keys(pendingGeometry).length === 0
      beginGeometry({ segmentCount: 0, gcode: null,
        preview: { byteCount: 6, width: 1, height: 1,
          mimeType: "image/png", encodedLength: 8 } }, 4)
      appendPreviewChunk({ source: "preview", index: 0,
        data: "A".repeat(root.maxPreviewChunkChars + 1) }, 4)
      console.log(JSON.stringify({ outOfOrderRejected: outOfOrderRejected,
        oversizedRejected: Object.keys(pendingGeometry).length === 0,
        previousPreserved: geometryBundle.previous === true }))
    JAVASCRIPT

    assert result.fetch("outOfOrderRejected")
    assert result.fetch("oversizedRejected")
    assert result.fetch("previousPreserved")
  end

  private

  def run_transaction(body)
    functions = FUNCTIONS.map { |name| extract_function(name) }.join("\n")
    script = <<~JAVASCRIPT
      var root = {
        segmentLimit: function() { return 1000000 },
        maxPreviewBytes: 524288,
        maxPreviewPixels: 4194304,
        maxPreviewChunkChars: 49152
      }
      var pendingGeometry = {}
      var geometryBundle = { previous: true }
      var selectedGeometrySource = "gcode"
      #{functions}
      root.validSegmentPath = validSegmentPath
      #{body}
    JAVASCRIPT
    output, error, status = Open3.capture3("node", "-e", script)
    assert status.success?, "JavaScript harness failed: #{error}"
    JSON.parse(output)
  end

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
end
