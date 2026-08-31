# frozen_string_literal: true

module BambuCompanion
  class PreviewPublication
    PREVIEW_CHUNK_CHARS = 49_152

    def initialize(bundle:, generation:, geometry_store:)
      @bundle = bundle
      @generation = Integer(generation)
      @geometry_store = geometry_store
    end

    def publish(cancelled: -> { false })
      gcode = @bundle.gcode
      preview = @bundle.preview
      encoded_preview = preview && [preview.data].pack("m0")
      packed_path = gcode && @geometry_store.write(
        generation: @generation, segments: gcode.segments, roles: gcode.roles,
        cancelled: cancelled
      )
      return false if gcode && !packed_path
      return false unless yield("geometry_begin", begin_payload(gcode, preview, packed_path,
                                                                  encoded_preview))

      chunks = {}
      chunks["gcode"] = 0 if gcode
      if encoded_preview
        count = chunk_count(encoded_preview.bytesize)
        chunks["preview"] = count
        count.times do |index|
          return false unless yield(
            "geometry_preview_chunk",
            generation: @generation,
            source: "preview",
            index: index,
            data: encoded_preview.byteslice(index * PREVIEW_CHUNK_CHARS, PREVIEW_CHUNK_CHARS)
          )
        end
      end

      yield(
        "geometry_end",
        generation: @generation,
        sources: @bundle.sources.map(&:to_s),
        chunks: chunks
      )
    end

    private

    def begin_payload(gcode, preview, packed_path, encoded_preview)
      {
        generation: @generation,
        segmentCount: @bundle.segment_count,
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
      }
    end

    def camel_bounds(bounds)
      {
        minX: bounds[:min_x], maxX: bounds[:max_x],
        minY: bounds[:min_y], maxY: bounds[:max_y],
        minZ: bounds[:min_z], maxZ: bounds[:max_z]
      }
    end

    def chunk_count(length)
      (length + PREVIEW_CHUNK_CHARS - 1) / PREVIEW_CHUNK_CHARS
    end
  end
end
