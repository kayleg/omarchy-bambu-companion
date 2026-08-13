# frozen_string_literal: true

require "bigdecimal"

module BambuCompanion
  class GcodeError < StandardError
    attr_reader :code

    def initialize(code, message)
      @code = String(code)
      super(message)
    end
  end

  Geometry = Struct.new(:segments, :bounds, :layer_z, :layer_z_exact,
                        keyword_init: true)

  class GcodeParser
    DEFAULT_MAX_SEGMENTS = 40_000
    DEFAULT_MAX_LAYER_VALUES = 20_000
    OUTER_MARKERS = [
      /\AFEATURE:\s*Outer wall\z/i,
      /\ATYPE:\s*External perimeter\z/i,
      /\ATYPE:\s*WALL-OUTER\z/i
    ].freeze
    FEATURE_MARKER = /\A(?:FEATURE|TYPE):/i
    PARAMETER = /([XYZE])\s*(-?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)/
    ZERO = BigDecimal("0")
    EPSILON = BigDecimal("1e-7")

    def initialize(max_segments: DEFAULT_MAX_SEGMENTS)
      @max_segments = Integer(max_segments)
      raise ArgumentError, "max_segments must be positive" unless @max_segments.positive?
    end

    def parse(io, cancelled: -> { false })
      reset
      io.each_line.with_index do |raw_line, index|
        if (index % 4096).zero? && cancelled.call
          raise GcodeError.new("cancelled", "G-code parsing cancelled")
        end

        parse_line(raw_line)
      end
      if @source_count.zero?
        raise GcodeError.new("no_outer_walls", "No supported outer-wall markers were found")
      end

      Geometry.new(
        segments: @segments.map { |segment| segment.map(&:to_f).freeze }.freeze,
        bounds: @bounds.transform_values(&:to_f).freeze,
        layer_z: layer_values.freeze,
        layer_z_exact: @layer_z_exact
      )
    end

    private

    def reset
      @absolute_position = true
      @absolute_extrusion = true
      @outer = false
      @position = { "X" => ZERO, "Y" => ZERO, "Z" => ZERO, "E" => ZERO }
      @segments = []
      @source_count = 0
      @sample_stride = 1
      @layers = []
      @layer_sample_stride = 1
      @layer_source_count = 0
      @last_layer = nil
      @layer_z_exact = true
      @bounds = { min_x: nil, max_x: nil, min_y: nil, max_y: nil,
                  min_z: nil, max_z: nil }
    end

    def parse_line(raw_line)
      code, comment = raw_line.to_s.split(";", 2)
      update_feature(comment.to_s.strip) unless comment.nil?
      stripped = code.to_s.strip
      return if stripped.empty?

      command = stripped.split(/\s+/, 2).first.upcase
      parameters = stripped.scan(PARAMETER).to_h.transform_values! { |value| BigDecimal(value) }
      return unless parameters.values.all? { |value| finite_float?(value) }

      case command
      when "G90" then @absolute_position = true
      when "G91" then @absolute_position = false
      when "M82" then @absolute_extrusion = true
      when "M83" then @absolute_extrusion = false
      when "G92" then parameters.each { |axis, value| @position[axis] = value }
      when "G0", "G00", "G1", "G01" then move(%w[G1 G01].include?(command), parameters)
      end
    end

    def update_feature(comment)
      return unless FEATURE_MARKER.match?(comment)

      @outer = OUTER_MARKERS.any? { |marker| marker.match?(comment) }
    end

    def move(linear_extrusion_command, parameters)
      before = @position.dup
      %w[X Y Z].each do |axis|
        next unless parameters.key?(axis)

        @position[axis] = @absolute_position ? parameters[axis] : @position[axis] + parameters[axis]
      end
      extrusion_delta = ZERO
      if parameters.key?("E")
        extrusion_delta = @absolute_extrusion ? parameters["E"] - @position["E"] : parameters["E"]
        @position["E"] = @absolute_extrusion ? parameters["E"] : @position["E"] + parameters["E"]
      end
      unless @position.values.all? { |value| finite_float?(value) } && finite_float?(extrusion_delta)
        @position = before
        return
      end

      moved_xy = (before["X"] - @position["X"]).abs > EPSILON ||
                 (before["Y"] - @position["Y"]).abs > EPSILON
      return unless linear_extrusion_command && @outer && moved_xy && extrusion_delta > EPSILON

      segment = [before["X"], before["Y"], before["Z"],
                 @position["X"], @position["Y"], @position["Z"]]
      record(segment)
    end

    def record(segment)
      @source_count += 1
      update_bounds(segment)
      record_layer(segment[2])
      record_layer(segment[5])
      source_index = @source_count - 1
      return unless (source_index % @sample_stride).zero?

      if @segments.length >= @max_segments
        @segments = @segments.each_with_index.filter_map { |value, index| value if index.even? }
        @sample_stride *= 2
        return unless (source_index % @sample_stride).zero?
      end
      @segments << segment
    end

    def record_layer(value)
      return if value == @last_layer

      @last_layer = value
      source_index = @layer_source_count
      @layer_source_count += 1
      return unless (source_index % @layer_sample_stride).zero?

      if @layers.length >= DEFAULT_MAX_LAYER_VALUES
        @layer_z_exact = false
        @layers = @layers.each_with_index.filter_map { |layer, index| layer if index.even? }
        @layer_sample_stride *= 2
        return unless (source_index % @layer_sample_stride).zero?
      end
      @layers << value
    end

    def layer_values
      values = (@layers + [@bounds[:min_z], @bounds[:max_z]]).compact
                                                              .sort.map(&:to_f).uniq
      return values if values.length <= DEFAULT_MAX_LAYER_VALUES

      last_index = values.length - 1
      Array.new(DEFAULT_MAX_LAYER_VALUES) do |index|
        values[index * last_index / (DEFAULT_MAX_LAYER_VALUES - 1)]
      end
    end

    def update_bounds(segment)
      [[segment[0], segment[1], segment[2]], [segment[3], segment[4], segment[5]]].each do |x, y, z|
        @bounds[:min_x] = x if @bounds[:min_x].nil? || x < @bounds[:min_x]
        @bounds[:max_x] = x if @bounds[:max_x].nil? || x > @bounds[:max_x]
        @bounds[:min_y] = y if @bounds[:min_y].nil? || y < @bounds[:min_y]
        @bounds[:max_y] = y if @bounds[:max_y].nil? || y > @bounds[:max_y]
        @bounds[:min_z] = z if @bounds[:min_z].nil? || z < @bounds[:min_z]
        @bounds[:max_z] = z if @bounds[:max_z].nil? || z > @bounds[:max_z]
      end
    end

    def finite_float?(value) = value.finite? && value.to_f.finite?
  end
end
