# frozen_string_literal: true

require "time"

module BambuCompanion
  class PrinterState
    MAX_STRING_BYTES = 4096
    Update = Struct.new(:snapshot, :load_model, keyword_init: true)

    FIELD_MAP = {
      "nozzle_temper" => [:nozzle_temp, :float],
      "nozzle_target_temper" => [:nozzle_target_temp, :float],
      "bed_temper" => [:bed_temp, :float],
      "bed_target_temper" => [:bed_target_temp, :float],
      "mc_percent" => [:percent, :percent],
      "mc_remaining_time" => [:remaining_minutes, :integer],
      "spd_lvl" => [:speed_level, :integer],
      "spd_mag" => [:speed_magnitude, :integer],
      "wifi_signal" => [:wifi_signal, :string],
      "cooling_fan_speed" => [:cooling_fan_speed, :float],
      "heatbreak_fan_speed" => [:heatbreak_fan_speed, :float],
      "gcode_state" => [:gcode_state, :string],
      "subtask_name" => [:subtask_name, :string],
      "gcode_file" => [:gcode_file, :string],
      "file" => [:file, :string],
      "url" => [:url, :string],
      "plate_idx" => [:plate_idx, :integer],
      "layer_num" => [:layer, :integer],
      "total_layer_num" => [:total_layers, :integer],
      "task_id" => [:task_id, :string],
      "subtask_id" => [:subtask_id, :string]
    }.freeze
    STABLE_ID_FIELDS = %w[task_id subtask_id].freeze
    WEAK_IDENTITY_FIELDS = %w[file url gcode_file subtask_name plate_idx].freeze

    def initialize(clock: -> { Time.now.utc })
      @clock = clock
      @values = { connected: false, stale: true, last_update: nil }
      @running_job_identified = false
    end

    def connected!
      @values[:connected] = true
      @values[:stale] = false
    end

    def disconnected!
      @values[:connected] = false
      @values[:stale] = true
    end

    def update(report)
      print_state = report.is_a?(Hash) && report["print"].is_a?(Hash) ? report["print"] : {}
      was_running = running?
      identity_changed = identity_changed?(print_state)
      FIELD_MAP.each do |source, (target, kind)|
        next unless print_state.key?(source)

        converted = convert(print_state[source], kind)
        @values[target] = converted unless converted.nil?
      end
      @values[:last_update] = @clock.call.utc.iso8601
      @values[:stale] = false if @values[:connected]

      identified = job_identified?
      should_load = false
      if running?
        should_load = !was_running || identity_changed || (!@running_job_identified && identified)
        @running_job_identified ||= identified
      else
        @running_job_identified = false
      end

      Update.new(snapshot: snapshot, load_model: should_load)
    end

    def snapshot
      @values.transform_values do |value|
        value.is_a?(String) ? value.dup.freeze : value
      end.freeze
    end

    private

    def running? = @values[:gcode_state].to_s.upcase == "RUNNING"

    def identity_changed?(print_state)
      fields = stable_identity?(print_state) ? STABLE_ID_FIELDS : WEAK_IDENTITY_FIELDS
      fields.any? do |source|
        next false unless print_state.key?(source)

        target, kind = FIELD_MAP.fetch(source)
        converted = convert(print_state[source], kind)
        !converted.nil? && @values.key?(target) && converted != @values[target]
      end
    end

    def stable_identity?(print_state)
      STABLE_ID_FIELDS.any? do |source|
        target, kind = FIELD_MAP.fetch(source)
        current = @values[target]
        incoming = convert(print_state[source], kind) if print_state.key?(source)
        [current, incoming].any? { |value| !value.nil? && !value.empty? }
      end
    end

    def job_identified?
      ids = [@values[:task_id], @values[:subtask_id]].compact.reject(&:empty?)
      return true unless ids.empty?

      hints = %i[file url gcode_file subtask_name plate_idx].map { |key| @values[key] }.compact
      !hints.empty?
    end

    def convert(value, kind)
      case kind
      when :float
        number = Float(value)
        number if number.finite?
      when :integer then Integer(value)
      when :percent then [[Integer(value), 0].max, 100].min
      when :string
        text = String(value).strip
        text if text.bytesize <= MAX_STRING_BYTES
      end
    rescue ArgumentError, TypeError
      nil
    end
  end
end
