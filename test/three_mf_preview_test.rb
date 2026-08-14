# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "zip"
require "bambu_companion/three_mf_preview"

class ThreeMfPreviewTest < Minitest::Test
  PNG_1X1 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
             .unpack1("m0").freeze

  class CountingHints
    attr_reader :calls

    def initialize(values)
      @values = values
      @calls = 0
    end

    def to_h
      @calls += 1
      @values
    end
  end

  def test_reads_the_requested_plate_preview
    with_archive(
      "Metadata/plate_1.png" => PNG_1X1,
      "Metadata/plate_2.png" => PNG_1X1
    ) do |path|
      preview = extractor.extract(path, hints: { "plate_idx" => 1 })

      assert_equal PNG_1X1, preview.data
      assert_equal 1, preview.width
      assert_equal 1, preview.height
      assert_equal "image/png", preview.media_type
      assert preview.frozen?
      assert preview.data.frozen?
    end
  end

  def test_prefers_full_plate_then_falls_back_to_bambu_thumbnail
    with_archive("Metadata/plate_1.png" => PNG_1X1) do |path|
      assert_equal PNG_1X1, extractor.extract(path).data
    end

    with_archive("Auxiliaries/.thumbnails/thumbnail_middle.png" => PNG_1X1) do |path|
      assert_equal PNG_1X1, extractor.extract(path).data
    end
  end

  def test_uses_the_only_plate_preview_when_mqtt_has_no_usable_plate_index
    with_archive(
      "Metadata/plate_2.png" => PNG_1X1,
      "Auxiliaries/.thumbnails/thumbnail_middle.png" => "not-a-png"
    ) do |path|
      assert_equal PNG_1X1, extractor.extract(path).data
      assert_equal PNG_1X1,
                   extractor.extract(path, hints: { "plate_idx" => 0 }).data
    end
  end

  def test_normalizes_hints_once_per_extraction
    hints = CountingHints.new("source_name" => "print.3mf", "plate_idx" => 0)

    with_archive("Metadata/plate_1.png" => PNG_1X1) do |path|
      assert_equal PNG_1X1, extractor.extract(path, hints: hints).data
    end

    assert_equal 1, hints.calls
  end

  def test_returns_nil_for_plain_gcode_or_an_archive_without_a_preview
    Dir.mktmpdir do |dir|
      gcode = File.join(dir, "job.gcode")
      File.binwrite(gcode, "G1 X1 Y1\n")
      assert_nil extractor.extract(gcode, hints: { "source_name" => "job.gcode" })
    end

    with_archive("Metadata/plate_1.gcode" => "G1 X1 Y1\n") do |path|
      assert_nil extractor.extract(path)
    end
  end

  def test_rejects_invalid_ambiguous_or_oversized_png_data
    with_archive("Metadata/plate_1.png" => "not-a-png") do |path|
      assert_nil extractor.extract(path)
    end

    with_archive(
      "Metadata/plate_1.png" => PNG_1X1,
      "metadata/PLATE_1.PNG" => PNG_1X1
    ) do |path|
      assert_nil extractor.extract(path)
    end

    with_archive("Metadata/plate_1.png" => PNG_1X1) do |path|
      assert_nil described_class(max_bytes: PNG_1X1.bytesize - 1).extract(path)
    end
  end

  def test_cancellation_is_reported_with_a_stable_code
    with_archive("Metadata/plate_1.png" => PNG_1X1) do |path|
      error = assert_raises(BambuCompanion::PreviewError) do
        extractor.extract(path, cancelled: -> { true })
      end

      assert_equal "cancelled", error.code
    end
  end

  private

  def extractor = described_class

  def described_class(**options)
    BambuCompanion::ThreeMfPreview.new(**options)
  end

  def with_archive(entries)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "print.gcode.3mf")
      Zip::File.open(path, create: true) do |zip|
        entries.each { |name, data| zip.get_output_stream(name) { |io| io.write(data) } }
      end
      yield path
    end
  end
end
