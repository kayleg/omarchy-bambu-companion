# frozen_string_literal: true

require_relative "gcode_parser"
require_relative "gcode_source"
require_relative "three_mf_preview"

module BambuCompanion
  class PrintPreviewBundle
    attr_reader :gcode, :preview, :sources, :segment_count

    def initialize(gcode: nil, preview: nil)
      raise ArgumentError, "at least one preview source is required" unless gcode || preview

      @gcode = gcode&.freeze
      @preview = preview&.freeze
      @sources = %i[gcode preview].select { |source| public_send(source) }.freeze
      @segment_count = @gcode&.segments&.length.to_i
      freeze
    end
  end

  class PrintPreviewLoader
    def initialize(source:, gcode_parser:, preview_source:)
      @source = source
      @gcode_parser = gcode_parser
      @preview_source = preview_source
    end

    def load(path, hints: {}, cancelled: -> { false })
      preview = load_preview(path, hints, cancelled)
      gcode = load_gcode(path, hints, cancelled)
      PrintPreviewBundle.new(gcode: gcode, preview: preview)
    rescue GcodeError, SourceError => error
      raise if error.code == "cancelled" || !preview

      PrintPreviewBundle.new(preview: preview)
    end

    private

    def load_preview(path, hints, cancelled)
      @preview_source.extract(path, hints: hints, cancelled: cancelled)
    rescue PreviewError => error
      raise if error.code == "cancelled"

      nil
    end

    def load_gcode(path, hints, cancelled)
      @source.open(path, hints) do |io|
        @gcode_parser.parse(io, cancelled: cancelled)
      end
    end
  end
end
