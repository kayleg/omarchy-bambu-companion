# frozen_string_literal: true

require "fileutils"
require "tempfile"

module BambuCompanion
  class CameraStore
    PLUGIN_DATA_NAME = "io.github.ypmrg.bambu-companion"
    SNAPSHOT_NAME = "snapshot.jpg"
    MAX_JPEG_BYTES = 1_048_576
    MAX_PIXELS = 4_194_304
    MAX_SIDE = 4096
    JPEG_SOI = "\xFF\xD8".b
    JPEG_EOI = "\xFF\xD9".b
    SOF_MARKERS = [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF].freeze

    def self.default_directory
      root = ENV["BAMBU_NATIVE_DATA_ROOT"]
      if root.nil? || root.empty?
        share = ENV["XDG_DATA_HOME"]
        share = File.join(Dir.home, ".local/share") if share.nil? || share.empty?
        root = File.join(share, PLUGIN_DATA_NAME)
      end
      File.expand_path(File.join(root, "camera"))
    end

    def self.valid_jpeg?(data)
      bytes = String(data).b
      return false unless bytes.bytesize.between?(JPEG_SOI.bytesize + JPEG_EOI.bytesize, MAX_JPEG_BYTES)
      return false unless bytes.start_with?(JPEG_SOI) && bytes.end_with?(JPEG_EOI)

      width, height = jpeg_dimensions(bytes)
      return false if width.nil? || height.nil?
      return false if width < 1 || height < 1 || width > MAX_SIDE || height > MAX_SIDE

      width * height <= MAX_PIXELS
    end

    def self.jpeg_dimensions(data)
      bytes = String(data).b
      index = 2
      while index + 3 < bytes.bytesize
        return if bytes.getbyte(index) != 0xFF

        marker = bytes.getbyte(index + 1)
        index += 2
        next if marker == 0xFF
        next if marker == 0x00 || marker == 0xD8 || marker == 0xD9
        next if (0xD0..0xD7).cover?(marker)
        break if marker == 0xDA

        return if index + 1 >= bytes.bytesize

        length = bytes.byteslice(index, 2).unpack1("n")
        return if length.nil? || length < 2 || index + length > bytes.bytesize

        if SOF_MARKERS.include?(marker)
          return if length < 7

          height, width = bytes.byteslice(index + 3, 4).unpack("n2")
          return [width, height]
        end

        index += length
      end
      nil
    end

    def initialize(directory: nil)
      @directory = File.expand_path(directory || self.class.default_directory)
      raise ArgumentError, "camera directory cannot be the filesystem root" if @directory == "/"
    end

    def write(jpeg)
      data = String(jpeg).b
      return unless self.class.valid_jpeg?(data)

      prepare_directory
      destination = File.join(@directory, SNAPSHOT_NAME)
      Tempfile.create([".snapshot-", ".tmp"], @directory, mode: 0o600, binmode: true) do |file|
        file.write(data)
        file.close
        File.rename(file.path, destination)
        File.chmod(0o600, destination)
        destination
      end
    end

    def clear
      path = File.join(@directory, SNAPSHOT_NAME)
      File.delete(path)
    rescue Errno::ENOENT
      nil
    end

    private

    def prepare_directory
      FileUtils.mkdir_p(@directory, mode: 0o700)
      stat = File.lstat(@directory)
      raise "camera directory must not be a symbolic link" if stat.symlink?
      raise "camera path is not a directory" unless stat.directory?
      raise "camera directory belongs to another user" unless stat.uid == Process.uid

      File.chmod(0o700, @directory)
      Dir.children(@directory).each do |name|
        next unless name.start_with?(".snapshot-") && name.end_with?(".tmp")

        File.delete(File.join(@directory, name))
      rescue Errno::ENOENT
        nil
      end
    end
  end
end
