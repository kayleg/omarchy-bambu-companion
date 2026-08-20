# frozen_string_literal: true

require_relative "test_helper"
require "bambu_companion/demo_session"
require "bambu_companion/gcode_parser"

class DemoAssetTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  GCODE = File.join(ROOT, "demo/omarchy-logo.gcode")

  def test_bundled_logo_is_a_bounded_multilayer_route_with_mid_print_progress
    geometry = parsed_geometry
    bounds = geometry.bounds
    width = bounds.fetch(:max_x) - bounds.fetch(:min_x)
    depth = bounds.fetch(:max_y) - bounds.fetch(:min_y)
    height = bounds.fetch(:max_z) - bounds.fetch(:min_z)
    layer = BambuCompanion::DemoSession::PRINTER.fetch(:layer)
    cutoff = geometry.layer_z.fetch(layer - 1)

    assert_operator geometry.segments.length, :>, 1_000
    assert_equal BambuCompanion::DemoSession::PRINTER.fetch(:totalLayers),
                 geometry.layer_z.length
    assert_operator width, :<=, 180
    assert_operator depth, :<=, 180
    assert_operator height, :>, 0
    assert_in_delta 0.5, (cutoff - bounds.fetch(:min_z)) / height, 0.1
  end

  def test_top_wordmark_is_upright_above_the_plaque
    geometry = parsed_geometry
    base_z = geometry.layer_z.first
    top_z = geometry.layer_z.last
    base_segments = geometry.segments.select do |segment|
      (segment.fetch(2) - base_z).abs < 1e-6
    end
    top_segments = geometry.segments.select do |segment|
      (segment.fetch(2) - top_z).abs < 1e-6
    end
    base_x = base_segments.flat_map { |segment| [segment.fetch(0), segment.fetch(3)] }
    base_y = base_segments.flat_map { |segment| [segment.fetch(1), segment.fetch(4)] }
    top_x = top_segments.flat_map { |segment| [segment.fetch(0), segment.fetch(3)] }
    endpoint_y = top_segments.flat_map do |segment|
      [segment.fetch(1), segment.fetch(4)]
    end
    plaque_center_y = (geometry.bounds.fetch(:min_y) +
                        geometry.bounds.fetch(:max_y)) / 2.0

    refute_empty endpoint_y
    assert_operator base_x.min, :<, top_x.min
    assert_operator base_x.max, :>, top_x.max
    assert_operator base_y.min, :<, endpoint_y.min
    assert_operator base_y.max, :>, endpoint_y.max
    assert_operator endpoint_y.sum.fdiv(endpoint_y.length), :<, plaque_center_y
  end

  def test_openscad_source_uses_the_shipped_omarchy_wordmark
    scad = File.read(File.join(ROOT, "demo/omarchy-logo.scad"))
    logo = File.read(File.join(ROOT, "demo/omarchy-logo.svg"))

    assert_includes scad, 'import("omarchy-logo.svg")'
    assert_includes scad, "linear_extrude"
    assert_includes scad, "scale([logo_scale, -logo_scale])"
    assert_includes scad, "svg_pixels_per_inch = 72"
    assert_includes scad, "logo_width = 160"
    assert_includes logo, "viewBox=\"0 0 1215 285\""
    assert_operator File.size(GCODE), :<, 512 * 1024
  end

  private

  def parsed_geometry
    @parsed_geometry ||= File.open(GCODE, "rb") do |file|
      BambuCompanion::GcodeParser.new(
        max_segments: BambuCompanion::DemoSession::MAX_SEGMENTS
      ).parse(file)
    end
  end
end
