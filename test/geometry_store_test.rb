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
