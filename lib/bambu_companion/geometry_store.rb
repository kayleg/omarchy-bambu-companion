# frozen_string_literal: true

require "fileutils"
require "tempfile"

module BambuCompanion
  class GeometryStore
    PLUGIN_DATA_NAME = "io.github.ypmrg.bambu-companion"
    ROLE_SUFFIX = ".roles"
    OWNED_FILE = /\Aroute-\d+\.f32(?:\.roles)?\z/

    def self.default_directory
      root = ENV["BAMBU_NATIVE_DATA_ROOT"]
      if root.nil? || root.empty?
        share = ENV["XDG_DATA_HOME"]
        share = File.join(Dir.home, ".local/share") if share.nil? || share.empty?
        root = File.join(share, PLUGIN_DATA_NAME)
      end
      File.expand_path(File.join(root, "geometry"))
    end

    def initialize(directory: nil)
      @directory = File.expand_path(directory || self.class.default_directory)
      raise ArgumentError, "geometry directory cannot be the filesystem root" if @directory == "/"
    end

    def write(generation:, segments:, roles: nil, cancelled: -> { false })
      prepare_directory
      name = "route-#{Integer(generation)}.f32"
      destination = File.join(@directory, name)

      Tempfile.create([".route-", ".tmp"], @directory, mode: 0o600, binmode: true) do |file|
        completed = write_segments(file, segments, cancelled)
        next unless completed && !cancelled.call

        file.close
        # The sidecar lands first so the renderer never sees geometry whose
        # roles have not arrived yet and paints a frame in the wrong colours.
        write_roles(name, roles, segments)
        File.rename(file.path, destination)
        remove_stale_files(except: name)
        destination
      end
    end

    private

    def prepare_directory
      FileUtils.mkdir_p(@directory, mode: 0o700)
      stat = File.lstat(@directory)
      raise "geometry directory must not be a symbolic link" if stat.symlink?
      raise "geometry path is not a directory" unless stat.directory?
      raise "geometry directory belongs to another user" unless stat.uid == Process.uid

      File.chmod(0o700, @directory)
    end

    def write_segments(file, segments, cancelled)
      result = segments.each_slice(4096) do |rows|
        break false if cancelled.call

        values = rows.flat_map { |segment| packed_segment(segment) }
        file.write(values.pack("e*"))
      end
      result != false
    end

    # One byte per segment, in the same order as the packed floats. Absent or
    # mis-sized, the renderer treats every segment as an outer wall, which is
    # exactly what it drew before roles existed -- so an older compiled
    # renderer degrades to the previous view instead of rejecting the file.
    def write_roles(name, roles, segments)
      role_path = File.join(@directory, "#{name}#{ROLE_SUFFIX}")
      if roles.nil? || roles.length != segments.length
        FileUtils.rm_f(role_path)
        return nil
      end

      Tempfile.create([".roles-", ".tmp"], @directory, mode: 0o600, binmode: true) do |file|
        roles.each_slice(8192) { |slice| file.write(slice.pack("C*")) }
        file.close
        File.rename(file.path, role_path)
      end
      role_path
    end

    def packed_segment(segment)
      unless segment.respond_to?(:length) && segment.length == 6
        raise ArgumentError, "invalid G-code segment"
      end

      segment.map do |value|
        number = Float(value)
        raise ArgumentError, "non-finite G-code segment" unless number.finite?

        number
      end
    end

    def remove_stale_files(except:)
      Dir.children(@directory).each do |name|
        next if name == except || name == "#{except}#{ROLE_SUFFIX}" || !OWNED_FILE.match?(name)

        File.delete(File.join(@directory, name))
      rescue Errno::ENOENT
        next
      end
    end
  end
end
