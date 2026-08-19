# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "bambu_companion/gcode_parser"
require "bambu_companion/geometry_store"
require "bambu_companion/print_preview_loader"
require "bambu_companion/preview_publication"

class PreviewPublicationTest < Minitest::Test
  def test_publishes_a_complete_dual_source_transaction
    Dir.mktmpdir do |directory|
      events = []
      result = publication(directory).publish do |event, payload|
        events << [event, payload]
        true
      end

      assert result
      assert_equal %w[geometry_begin geometry_preview_chunk geometry_end], events.map(&:first)
      beginning = events.first.last
      assert_equal 12, beginning.fetch(:generation)
      assert_equal 1, beginning.fetch(:segmentCount)
      assert_equal 24, File.size(beginning.fetch(:gcode).fetch(:path))
      assert_equal "UE5H", events.fetch(1).last.fetch(:data)
      assert_equal %w[gcode preview], events.last.last.fetch(:sources)
      assert_equal({ "gcode" => 0, "preview" => 1 }, events.last.last.fetch(:chunks))
    end
  end

  def test_stops_the_transaction_when_an_event_is_rejected
    Dir.mktmpdir do |directory|
      events = []
      result = publication(directory).publish do |event, _payload|
        events << event
        false
      end

      refute result
      assert_equal ["geometry_begin"], events
    end
  end

  private

  def publication(directory)
    geometry = BambuCompanion::Geometry.new(
      segments: [[0, 0, 0.2, 1, 0, 0.2]].freeze,
      bounds: { min_x: 0, max_x: 1, min_y: 0, max_y: 0, min_z: 0.2, max_z: 0.2 }.freeze,
      layer_z: [0.2].freeze,
      layer_z_exact: true
    )
    preview = BambuCompanion::PreviewImage.new(
      data: "PNG".b.freeze, width: 1, height: 1, media_type: "image/png"
    )
    bundle = BambuCompanion::PrintPreviewBundle.new(gcode: geometry, preview: preview)
    BambuCompanion::PreviewPublication.new(
      bundle: bundle,
      generation: 12,
      geometry_store: BambuCompanion::GeometryStore.new(directory: directory)
    )
  end
end
