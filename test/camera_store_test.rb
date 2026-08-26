# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "tmpdir"
require "bambu_companion/camera_store"

class CameraStoreTest < Minitest::Test
  JPEG = BambuCompanion::TestFixtures.minimal_jpeg.freeze

  def test_writes_snapshot_atomically_with_private_permissions
    Dir.mktmpdir do |directory|
      path = store(directory).write(JPEG)

      assert_equal File.join(directory, "snapshot.jpg"), path
      assert_equal JPEG, File.binread(path)
      assert_equal 0o600, File.stat(path).mode & 0o777
      assert_equal 0o700, File.stat(directory).mode & 0o777
    end
  end

  def test_replaces_the_previous_snapshot
    Dir.mktmpdir do |directory|
      store(directory).write(JPEG)
      replacement = minimal_jpeg(payload: "replaced")
      path = store(directory).write(replacement)

      assert_equal replacement, File.binread(path)
      assert_equal ["snapshot.jpg"], Dir.children(directory)
    end
  end

  def test_rejects_jpeg_bombs_with_huge_declared_dimensions
    Dir.mktmpdir do |directory|
      camera = store(directory)
      previous = camera.write(JPEG)
      bomb = minimal_jpeg(width: 65_535, height: 65_535)

      assert_nil camera.write(bomb)
      assert_equal JPEG, File.binread(previous)
    end
  end

  def test_rejects_non_jpeg_and_oversized_payloads
    Dir.mktmpdir do |directory|
      camera = store(directory)
      previous = camera.write(JPEG)

      assert_nil camera.write("not-jpeg")
      assert_nil camera.write("\xFF\xD8\xFF".b)
      assert_nil camera.write("\xFF\xD8" + ("x" * 1_048_575) + "\xFF\xD9")
      assert_equal JPEG, File.binread(previous)
    end
  end

  def test_rejects_a_symbolic_link_as_the_camera_directory
    Dir.mktmpdir do |root|
      target = File.join(root, "target")
      link = File.join(root, "camera")
      FileUtils.mkdir_p(target)
      File.symlink(target, link)

      error = assert_raises(RuntimeError) { store(link).write(JPEG) }

      assert_match(/symbolic link/, error.message)
      assert_empty Dir.children(target)
    end
  end

  def test_clear_removes_the_snapshot
    Dir.mktmpdir do |directory|
      camera = store(directory)
      camera.write(JPEG)
      camera.clear

      refute_path_exists File.join(directory, "snapshot.jpg")
    end
  end

  def test_default_directory_uses_plugin_data_root
    assert_equal File.expand_path("camera", "/tmp/bambu-data"),
                 with_env("BAMBU_NATIVE_DATA_ROOT" => "/tmp/bambu-data") {
                   BambuCompanion::CameraStore.default_directory
                 }
  end

  private

  def store(directory)
    BambuCompanion::CameraStore.new(directory: directory)
  end

  def with_env(values)
    previous = values.keys.to_h { |key| [key, ENV[key]] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each do |key, value|
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
  end
end
