# frozen_string_literal: true

module BambuCompanion
  module Archive
    MAX_BYTES = 1 << 30
    MAX_ENTRIES = 4096
    MAX_ENTRY_NAME_BYTES = 1024

    module_function

    def safe_entry_name?(name)
      value = String(name).tr("\\", "/")
      return false if value.empty? || value.bytesize > MAX_ENTRY_NAME_BYTES
      return false if value.start_with?("/") || value.match?(/\A[A-Za-z]:/)

      value.split("/").none? { |part| part.empty? || part == "." || part == ".." }
    rescue TypeError
      false
    end
  end

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
