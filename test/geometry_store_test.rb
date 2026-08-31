# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "tmpdir"
require "bambu_companion/geometry_store"

class GeometryStoreTest < Minitest::Test
  def test_writes_private_little_endian_geometry_atomically
    Dir.mktmpdir do |directory|
      path = store(directory).write(generation: 7, segments: [[1, 2, 3, 4, 5, 6]])

      assert_equal File.join(directory, "route-7.f32"), path
      assert_equal [1, 2, 3, 4, 5, 6], File.binread(path).unpack("e*")
      assert_equal 0o600, File.stat(path).mode & 0o777
      assert_equal 0o700, File.stat(directory).mode & 0o777
      assert_equal ["route-7.f32"], Dir.children(directory)
    end
  end

  # One byte per segment, same order as the packed floats. The renderer keys
  # its colours off this, so a length mismatch must drop the file rather than
  # colour the geometry by an off-by-one index.
  def test_writes_a_role_sidecar_beside_the_geometry
    Dir.mktmpdir do |directory|
      path = store(directory).write(
        generation: 3, segments: [[1, 2, 3, 4, 5, 6], [7, 8, 9, 10, 11, 12]],
        roles: [0, 3]
      )
      sidecar = "#{path}.roles"

      assert_path_exists sidecar
      assert_equal [0, 3], File.binread(sidecar).unpack("C*")
      assert_equal 0o600, File.stat(sidecar).mode & 0o777
      assert_equal ["route-3.f32", "route-3.f32.roles"], Dir.children(directory).sort
    end
  end

  def test_omits_the_sidecar_when_roles_do_not_match_the_segments
    Dir.mktmpdir do |directory|
      [nil, [0], [0, 1, 2]].each do |roles|
        path = store(directory).write(
          generation: 4, segments: [[1, 2, 3, 4, 5, 6], [7, 8, 9, 10, 11, 12]],
          roles: roles
        )

        refute_path_exists "#{path}.roles", "roles=#{roles.inspect} must not be written"
      end
    end
  end

  # A sidecar left behind by an earlier generation would outlive its geometry
  # and be read against the wrong segment count.
  def test_sweeps_stale_sidecars_but_keeps_the_current_one
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "route-1.f32"), "old")
      File.write(File.join(directory, "route-1.f32.roles"), "old")
      store(directory).write(generation: 2, segments: [[1, 2, 3, 4, 5, 6]], roles: [2])

      assert_equal ["route-2.f32", "route-2.f32.roles"], Dir.children(directory).sort
    end
  end

  def test_a_geometry_written_without_roles_clears_a_previous_sidecar
    Dir.mktmpdir do |directory|
      segments = [[1, 2, 3, 4, 5, 6]]
      store(directory).write(generation: 5, segments: segments, roles: [1])
      path = store(directory).write(generation: 5, segments: segments)

      refute_path_exists "#{path}.roles"
    end
  end

  def test_replaces_only_files_owned_by_the_store
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "route-1.f32"), "old")
      File.write(File.join(directory, "unrelated.f32"), "keep")

      store(directory).write(generation: 2, segments: [[0, 0, 0, 1, 1, 1]])

      refute_path_exists File.join(directory, "route-1.f32")
      assert_path_exists File.join(directory, "route-2.f32")
      assert_equal "keep", File.read(File.join(directory, "unrelated.f32"))
    end
  end

  def test_cancellation_leaves_no_partial_file
    Dir.mktmpdir do |directory|
      result = store(directory).write(
        generation: 1, segments: [[0, 0, 0, 1, 1, 1]], cancelled: -> { true }
      )

      assert_nil result
      assert_empty Dir.children(directory)
    end
  end

  def test_invalid_geometry_preserves_the_previous_file
    Dir.mktmpdir do |directory|
      previous = store(directory).write(generation: 1, segments: [[0, 0, 0, 1, 1, 1]])

      assert_raises(ArgumentError) do
        store(directory).write(generation: 2, segments: [[Float::INFINITY] * 6])
      end

      assert_path_exists previous
      refute_path_exists File.join(directory, "route-2.f32")
      assert_equal ["route-1.f32"], Dir.children(directory)
    end
  end

  def test_rejects_a_symbolic_link_as_the_geometry_directory
    Dir.mktmpdir do |root|
      target = File.join(root, "target")
      link = File.join(root, "geometry")
      FileUtils.mkdir_p(target)
      File.symlink(target, link)

      error = assert_raises(RuntimeError) do
        store(link).write(generation: 1, segments: [])
      end

      assert_match(/symbolic link/, error.message)
      assert_empty Dir.children(target)
    end
  end

  private

  def store(directory)
    BambuCompanion::GeometryStore.new(directory: directory)
  end
end
