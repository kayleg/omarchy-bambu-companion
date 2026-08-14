# frozen_string_literal: true

module BambuCompanion
  class ArchiveFileIO
    def initialize(io)
      @io = io
    end

    def read(*) = @io.read(*)
    def seek(*) = @io.seek(*)
    def tell = @io.tell
    def eof = @io.eof?
    def eof? = @io.eof?
    def size = @io.stat.size
    def binmode = @io.binmode
    def close = @io.close

    def open_entry_stream(entry)
      @pending_duplicate = nil
      stream = nil
      begin
        stream = entry.get_input_stream
      ensure
        @pending_duplicate&.close if stream.nil?
        @pending_duplicate = nil
      end
      stream
    end

    def dup
      @pending_duplicate = self.class.new(@io.dup)
    end
  end
end
