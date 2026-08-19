# frozen_string_literal: true

require "monitor"
require "tempfile"
require "fileutils"

module BambuCompanion
  module ZProgress
    module_function

    def calculate(geometry, printer)
      return [nil, "unknown"] unless geometry

      values = printer.to_h
      layers = geometry.layer_z
      layer = integer_or_nil(value_for(values, :layer_num, :layer))
      layer_metadata_exact = !geometry.respond_to?(:layer_z_exact) || geometry.layer_z_exact != false
      unless !layer_metadata_exact || layer.nil? || layers.nil? || layers.empty?
        index = [[layer - 1, 0].max, layers.length - 1].min
        z = finite_number_or_nil(layers[index])
        return [z, "layer"] if z
      end

      percent = integer_or_nil(value_for(values, :percent))
      bounds = geometry.bounds
      min_z = finite_number_or_nil(bounds&.[](:min_z))
      max_z = finite_number_or_nil(bounds&.[](:max_z))
      if percent && min_z && max_z
        ratio = [[percent, 0].max, 100].min / 100.0
        difference = max_z - min_z
        estimated = if difference.finite?
                      min_z + (difference * ratio)
                    else
                      (min_z * (1.0 - ratio)) + (max_z * ratio)
                    end
        finite_estimate = finite_number_or_nil(estimated)
        return [finite_estimate, "estimated"] if finite_estimate
      end

      [nil, "unknown"]
    rescue NoMethodError, TypeError
      [nil, "unknown"]
    end

    def value_for(values, *keys)
      keys.each do |key|
        return values[key] if values.key?(key)

        string_key = key.to_s
        return values[string_key] if values.key?(string_key)
      end
      nil
    end

    def integer_or_nil(value)
      Integer(value)
    rescue ArgumentError, TypeError, RangeError
      nil
    end

    def finite_number_or_nil(value)
      number = Float(value)
      number if number.finite?
    rescue ArgumentError, TypeError
      nil
    end
  end

  class ModelWorker
    class StoppedError < StandardError
      def initialize
        super("Model worker has been stopped")
      end
    end

    Job = Struct.new(:generation, :hints, :local_path, keyword_init: true)
    ProgressGeometry = Struct.new(:bounds, :layer_z, :layer_z_exact,
                                  keyword_init: true)
    STOP = Object.new.freeze
    PREVIEW_CHUNK_CHARS = 49_152
    STOP_JOIN_SECONDS = 0.25
    PLUGIN_DATA_NAME = "io.github.ypmrg.bambu-companion"

    def self.default_geometry_directory
      root = ENV["BAMBU_NATIVE_DATA_ROOT"]
      if root.nil? || root.empty?
        share = ENV["XDG_DATA_HOME"]
        share = File.join(Dir.home, ".local/share") if share.nil? || share.empty?
        root = File.join(share, PLUGIN_DATA_NAME)
      end
      File.join(root, "geometry")
    end

    def initialize(ftps_client:, loader:, emitter:, on_status:,
                   geometry_directory: nil)
      @ftps_client = ftps_client
      @loader = loader
      @emitter = emitter
      @on_status = on_status
      @geometry_directory = geometry_directory || self.class.default_geometry_directory
      @queue = SizedQueue.new(1)
      @mutex = Mutex.new
      # Direct same-thread callback reentry is supported. A callback must not
      # synchronously join another thread that submits while this monitor is held.
      @publication_mutex = Monitor.new
      @process_mutex = Mutex.new
      @generation = 0
      @geometry = nil
      @state = state(status: "idle", generation: 0)
      @thread = nil
      @stopped = false
    end

    def start
      @mutex.synchronize do
        return self if @stopped || @thread&.alive?

        @thread = Thread.new { run }
      end
      self
    end

    def submit(hints:, local_path: nil)
      @mutex.synchronize { raise StoppedError if @stopped }
      copied_hints = copy_hints(hints.to_h).freeze
      copied_path = local_path.nil? ? nil : String(local_path).dup.freeze
      @publication_mutex.synchronize do
        @mutex.synchronize do
          raise StoppedError if @stopped

          @generation += 1
          @state = state(
            status: "loading", generation: @generation,
            load_phase: copied_path ? "processing" : "locating"
          )
          job = Job.new(
            generation: @generation, hints: copied_hints, local_path: copied_path
          ).freeze
          replace_queued(job)
          job
        end
      end
    end

    def current?(job)
      @mutex.synchronize { job.generation == @generation && !@stopped }
    end

    def process(job)
      @process_mutex.synchronize { process_current(job) }
    end

    def snapshot(printer)
      state_snapshot, geometry = @mutex.synchronize { [@state, @geometry] }
      z, mode = ZProgress.calculate(geometry, printer)
      state_snapshot.merge(z_current: z, z_mode: mode).freeze
    end

    def stop
      thread = @mutex.synchronize do
        return self if @stopped

        @generation += 1
        @stopped = true
        replace_queued(STOP)
        @thread
      end
      return self unless thread
      return self if thread == Thread.current

      unless thread.join(STOP_JOIN_SECONDS)
        thread.kill
        thread.join(STOP_JOIN_SECONDS)
      end
      @mutex.synchronize { @thread = nil if @thread == thread && !thread.alive? }
      self
    end

    private

    def replace_queued(value)
      loop do
        @queue.push(value, true)
        return value
      rescue ThreadError
        begin
          @queue.pop(true)
        rescue ThreadError
          nil
        end
      end
    end

    def run
      loop do
        job = newest_queued_job
        break unless job

        process(job)
      end
    ensure
      current_thread = Thread.current
      @mutex.synchronize { @thread = nil if @thread == current_thread }
    end

    def newest_queued_job
      job = @queue.pop
      return if job.equal?(STOP)

      job
    end

    def process_current(job)
      return false unless current?(job)

      notify_status(job)
      return false unless current?(job)

      bundle = load_geometry(job)
      return false unless current?(job)
      return false unless publish_geometry(job, bundle)

      committed = @mutex.synchronize do
        next false unless job.generation == @generation && !@stopped

        @geometry = progress_geometry(bundle.gcode)
        @state = state(
          status: "ready", generation: job.generation,
          segment_count: bundle.segment_count
        )
        true
      end
      return false unless committed

      notify_status(job)
      true
    rescue StoppedError
      raise
    rescue StandardError => error
      publish_error(job, error)
      false
    end

    def load_geometry(job)
      if job.local_path
        update_load_state(job, phase: "processing")
        return parse_path(job.local_path, job)
      end

      raise "FTPS client is unavailable" unless @ftps_client

      Tempfile.create(["bambu-companion-", ".download"], binmode: true) do |temp|
        path = temp.path
        temp.close
        remote = @ftps_client.download(
          hints: job.hints,
          destination: path,
          cancelled: -> { !current?(job) },
          progress: lambda do |loaded, total|
            update_load_state(
              job, phase: "downloading", loaded_bytes: loaded,
              total_bytes: total
            )
          end
        )
        return false unless current?(job)

        update_load_state(job, phase: "processing")
        parse_path(path, job, source_name: remote)
      end
    end

    def update_load_state(job, phase:, loaded_bytes: 0, total_bytes: nil)
      loaded = [Integer(loaded_bytes), 0].max
      total = Integer(total_bytes) if total_bytes
      total = nil unless total&.positive?
      progress = total ? [[loaded * 100 / total, 0].max, 100].min : nil
      bucket = total ? progress : loaded / (1 << 20)
      published = @mutex.synchronize do
        next false unless job.generation == @generation && !@stopped

        previous = @state
        previous_bucket = if previous[:total_bytes].to_i.positive?
                            previous[:load_progress]
                          else
                            previous[:loaded_bytes].to_i / (1 << 20)
                          end
        next false if previous[:load_phase] == phase &&
                      previous[:total_bytes].to_i == total.to_i &&
                      previous_bucket == bucket

        @state = state(
          status: "loading", generation: job.generation,
          load_phase: phase, load_progress: progress,
          loaded_bytes: loaded, total_bytes: total.to_i
        )
        true
      end
      notify_status(job) if published
      published
    rescue ArgumentError, TypeError
      false
    end

    def parse_path(path, job, source_name: nil)
      hints = source_name ? job.hints.merge("source_name" => source_name) : job.hints
      @loader.load(path, hints: hints, cancelled: -> { !current?(job) })
    end

    def publish_geometry(job, bundle)
      gcode = bundle.gcode
      preview = bundle.preview
      encoded_preview = preview && [preview.data].pack("m0")
      packed_path = gcode && write_packed_segments(job, gcode.segments)
      return false if gcode && !packed_path
      return false unless emit_current(
        job,
        "geometry_begin",
        generation: job.generation,
        segmentCount: bundle.segment_count,
        gcode: gcode && {
          segmentCount: gcode.segments.length,
          bounds: camel_bounds(gcode.bounds),
          path: packed_path
        },
        preview: preview && {
          byteCount: preview.data.bytesize,
          encodedLength: encoded_preview.bytesize,
          width: preview.width,
          height: preview.height,
          mimeType: preview.media_type
        }
      )

      chunk_counts = {}
      chunk_counts["gcode"] = 0 if gcode

      if encoded_preview
        count = chunk_count(encoded_preview.bytesize, PREVIEW_CHUNK_CHARS)
        chunk_counts["preview"] = count
        count.times do |index|
          data = encoded_preview.byteslice(
            index * PREVIEW_CHUNK_CHARS, PREVIEW_CHUNK_CHARS
          )
          return false unless emit_current(
            job,
            "geometry_preview_chunk",
            generation: job.generation,
            source: "preview",
            index: index,
            data: data
          )
        end
      end

      emit_current(
        job,
        "geometry_end",
        generation: job.generation,
        sources: bundle.sources.map(&:to_s),
        chunks: chunk_counts
      )
    end

    def emit_current(job, event, payload)
      @publication_mutex.synchronize do
        next false unless current?(job)

        @emitter.emit(event, payload)
        current?(job)
      end
    end

    def write_packed_segments(job, segments)
      FileUtils.mkdir_p(@geometry_directory, mode: 0o700)
      File.chmod(0o700, @geometry_directory)
      path = File.join(@geometry_directory, "#{Integer(job.generation)}.f32")
      temporary = "#{path}.#{Process.pid}.#{Thread.current.object_id}.tmp"
      begin
        File.open(temporary, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
          segments.each_slice(4096) do |rows|
            return unless current?(job)

            values = rows.flat_map do |segment|
              raise "invalid G-code segment" unless segment.respond_to?(:length) &&
                                                   segment.length == 6

              segment.map do |value|
                number = Float(value)
                raise "non-finite G-code segment" unless number.finite?

                number
              end
            end
            file.write(values.pack("e*"))
          end
        end
        return unless current?(job)

        File.rename(temporary, path)
        Dir.children(@geometry_directory).each do |name|
          next unless name.end_with?(".f32")
          next if name == File.basename(path)

          File.delete(File.join(@geometry_directory, name))
        rescue Errno::ENOENT
          next
        end
        path
      ensure
        FileUtils.rm_f(temporary)
      end
    end

    def chunk_count(length, size) = (length + size - 1) / size

    def progress_geometry(gcode)
      return unless gcode

      ProgressGeometry.new(
        bounds: gcode.bounds,
        layer_z: gcode.layer_z,
        layer_z_exact: gcode.layer_z_exact
      ).freeze
    end

    def publish_error(job, error)
      published = @mutex.synchronize do
        next false unless job.generation == @generation && !@stopped

        code = error.respond_to?(:code) ? String(error.code) : "internal"
        details = {
          code: code.dup.freeze,
          message: String(error.message).dup.freeze
        }.freeze
        @state = state(status: "error", generation: job.generation, error: details)
        true
      end
      notify_status(job) if published
    end

    def notify_status(job)
      @publication_mutex.synchronize do
        next false unless current?(job)

        @on_status.call(snapshot({}))
        current?(job)
      end
    rescue StoppedError
      raise
    rescue StandardError
      false
    end

    def state(status:, generation:, segment_count: 0, error: nil,
              load_phase: "", load_progress: nil,
              loaded_bytes: 0, total_bytes: 0)
      {
        status: status,
        generation: generation,
        segment_count: segment_count,
        error: error,
        load_phase: load_phase,
        load_progress: load_progress,
        loaded_bytes: loaded_bytes,
        total_bytes: total_bytes
      }.freeze
    end

    def copy_hints(value)
      value.each_with_object({}) do |(key, item), copy|
        copy[key] = case item
                    when String then item.dup.freeze
                    when Array
                      item.map do |child|
                        child.is_a?(String) ? child.dup.freeze : child
                      end.freeze
                    when Hash then copy_hints(item).freeze
                    else item
                    end
      end
    end

    def camel_bounds(bounds)
      {
        minX: bounds[:min_x], maxX: bounds[:max_x],
        minY: bounds[:min_y], maxY: bounds[:max_y],
        minZ: bounds[:min_z], maxZ: bounds[:max_z]
      }
    end
  end
end
