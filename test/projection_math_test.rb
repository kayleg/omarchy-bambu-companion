# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "json"
require "tmpdir"

class ProjectionMathTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_display_z_scales_only_height_and_clamps_progress
    values = run_fixture.fetch("displayZ")
    assert_in_delta 0.4, values[0], 1e-5
    assert_in_delta 2.4, values[1], 1e-5
    assert_in_delta 4.4, values[2], 1e-5
    assert_in_delta 0.2, values[3], 1e-5
    assert_in_delta 4.4, values[4], 1e-5
  end

  def test_projection_frame_centers_and_fills_the_viewport
    frame = run_fixture.fetch("frame")
    assert_in_delta 300, (frame.fetch("left") + frame.fetch("right")) / 2.0, 1e-3
    assert_in_delta 180, (frame.fetch("top") + frame.fetch("bottom")) / 2.0, 1e-3
    assert_operator frame.fetch("left"), :>=, 24 - 1e-3
    assert_operator frame.fetch("right"), :<=, 576 + 1e-3
    assert_operator frame.fetch("top"), :>=, 24 - 1e-3
    assert_operator frame.fetch("bottom"), :<=, 336 + 1e-3
    occupancy = [
      (frame.fetch("right") - frame.fetch("left")) / 552.0,
      (frame.fetch("bottom") - frame.fetch("top")) / 312.0
    ].max
    assert_in_delta 1.0, occupancy, 1e-3
  end

  def test_project_point_applies_zoom_around_the_fitted_center
    point = run_fixture.fetch("zoomedCenter")
    assert_in_delta 300, point.fetch("x"), 1e-2
    assert_in_delta 180, point.fetch("y"), 1e-2
  end

  def test_deep_exploded_zoom_centers_the_current_printing_layer
    point = run_fixture.fetch("focusedLayer")

    assert_in_delta 300, point.fetch("x"), 1e-2
    assert_in_delta 180, point.fetch("y"), 1e-2
  end

  def test_exploded_x1_fits_current_layer_to_half_view_at_every_factor
    focused = run_fixture.fetch("factorInvariantFocus")

    focused.each do |sample|
      assert_in_delta 300, sample.fetch("centerX"), 1e-3
      assert_in_delta 180, sample.fetch("centerY"), 1e-3
      assert_in_delta 0.5, sample.fetch("occupancy"), 1e-3
      assert_in_delta focused.first.fetch("scale"), sample.fetch("scale"), 1e-5
    end
  end

  def test_world_z_axis_stays_vertical_without_camera_roll
    run_fixture.fetch("uprightZ").each do |horizontal_delta|
      assert_in_delta 0, horizontal_delta, 1e-3
    end
  end

  def test_little_endian_binary_segments_are_validated_and_decoded
    binary = run_fixture.fetch("binary")
    assert binary.fetch("ok")
    assert binary.fetch("shortRejected")
    assert binary.fetch("limitRejected")
    assert binary.fetch("nonfiniteRejected")
    assert_equal [1, -2.5, 0, 3, 4, 5], binary.fetch("values")
  end

  private

  def run_fixture
    @fixture ||= compile_and_run
  end

  def compile_and_run
    Dir.mktmpdir("bambu-projection") do |dir|
      binary = File.join(dir, "test_projection")
      _out, error, status = Open3.capture3(
        "g++", "-std=c++17", "-O0", "-I", File.join(ROOT, "native"),
        File.join(ROOT, "test/native/projection_test.cpp"), "-o", binary
      )
      assert status.success?, "g++ failed: #{error}"
      output, error, status = Open3.capture3(binary)
      assert status.success?, "projection fixture failed: #{error} #{output}"
      JSON.parse(output)
    end
  end
end
