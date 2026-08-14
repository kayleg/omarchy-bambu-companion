# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "tmpdir"
require "zip"
require "bambu_companion/gcode_parser"
require "bambu_companion/gcode_source"
require "bambu_companion/three_mf_preview"
require "bambu_companion/print_preview_loader"

class PrintPreviewLoaderTest < Minitest::Test
  PNG_1X1 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
             .unpack1("m0").freeze

  class MemorySource
    def initialize(content: nil, error: nil)
      @content = content
      @error = error
    end

    def open(*)
      raise @error if @error

      yield StringIO.new(@content)
    end
  end

  class PreviewSource
    def initialize(result: nil, error: nil)
      @result = result
      @error = error
    end

    def extract(*)
      raise @error if @error

      @result
    end
  end

  def test_returns_independent_gcode_and_preview_sources
    result = loader(preview: preview).load("job.gcode.3mf")

    assert_equal %i[gcode preview], result.sources
    assert_equal 1, result.gcode.segments.length
    assert_equal [0.2], result.gcode.layer_z
    assert_equal PNG_1X1, result.preview.data
    assert_equal 1, result.segment_count
    assert result.frozen?
  end

  def test_real_archive_returns_its_gcode_and_plate_preview
    with_archive do |path|
      result = BambuCompanion::PrintPreviewLoader.new(
        source: BambuCompanion::GcodeSource.new,
        gcode_parser: BambuCompanion::GcodeParser.new(max_segments: 20),
        preview_source: BambuCompanion::ThreeMfPreview.new
      ).load(path)

      assert_equal %i[gcode preview], result.sources
      assert_equal PNG_1X1, result.preview.data
      assert_equal 1, result.gcode.segments.length
    end
  end

  def test_preview_stays_available_when_gcode_cannot_be_visualized
    result = loader(
      source: MemorySource.new(content: "G90\nG1 X1 Y1 E1\n"), preview: preview
    ).load("job.gcode.3mf")

    assert_nil result.gcode
    assert_equal %i[preview], result.sources
    assert_equal PNG_1X1, result.preview.data
    assert_equal 0, result.segment_count
  end

  def test_gcode_stays_available_when_preview_is_absent_or_invalid
    result = loader(preview: nil).load("job.gcode.3mf")
    invalid = loader(
      preview_error: BambuCompanion::PreviewError.new("invalid", "invalid preview")
    ).load("job.gcode.3mf")

    assert_equal %i[gcode], result.sources
    assert_equal %i[gcode], invalid.sources
    assert_equal 1, result.gcode.segments.length
  end

  def test_original_gcode_error_is_preserved_when_no_preview_exists
    error = assert_raises(BambuCompanion::GcodeError) do
      loader(
        source: MemorySource.new(content: "G90\nG1 X1 Y1 E1\n"), preview: nil
      ).load("job.gcode.3mf")
    end

    assert_equal "no_outer_walls", error.code
  end

  def test_cancellation_from_either_source_is_never_swallowed
    preview_error = BambuCompanion::PreviewError.new("cancelled", "cancelled")
    error = assert_raises(BambuCompanion::PreviewError) do
      loader(preview_error: preview_error).load("job.gcode.3mf")
    end
    assert_equal "cancelled", error.code

    error = assert_raises(BambuCompanion::GcodeError) do
      loader(preview: preview).load("job.gcode.3mf", cancelled: -> { true })
    end
    assert_equal "cancelled", error.code
  end

  private

  def preview
    BambuCompanion::PreviewImage.new(
      data: PNG_1X1, width: 1, height: 1, media_type: "image/png"
    ).freeze
  end

  def loader(source: MemorySource.new(content: gcode), preview: nil, preview_error: nil)
    BambuCompanion::PrintPreviewLoader.new(
      source: source,
      gcode_parser: BambuCompanion::GcodeParser.new(max_segments: 20),
      preview_source: PreviewSource.new(result: preview, error: preview_error)
    )
  end

  def gcode
    <<~GCODE
      ; Z_HEIGHT: 0.2
      ; FEATURE: Outer wall
      G1 X0 Y0 Z0.2
      G1 X1 Y0 E1
      ; Z_HEIGHT: 0.4
      G1 Z0.4
      G1 X2 Y0 E1
    GCODE
  end

  def with_archive
    Dir.mktmpdir do |dir|
      path = File.join(dir, "print.gcode.3mf")
      Zip::File.open(path, create: true) do |zip|
        zip.get_output_stream("Metadata/plate_1.gcode") { |io| io.write(gcode) }
        zip.get_output_stream("Metadata/plate_1.png") { |io| io.write(PNG_1X1) }
      end
      yield path
    end
  end
end
